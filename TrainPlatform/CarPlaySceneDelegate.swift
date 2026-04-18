#if false
//
//  CarPlaySceneDelegate.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import CarPlay
import SwiftData
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refreshTimer: Timer?
    private var currentStop: SavedStop?
    private var departureTemplate: CPListTemplate?

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let rootTemplate = buildPlatformListTemplate()
        interfaceController.setRootTemplate(rootTemplate, animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        stopRefreshTimer()
        self.interfaceController = nil
        self.currentStop = nil
        self.departureTemplate = nil
    }

    // MARK: - Root Platform List

    private func buildPlatformListTemplate() -> CPListTemplate {
        let context = ModelContext(SharedModelContainer.container)
        let descriptor = FetchDescriptor<SavedStop>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let stops = (try? context.fetch(descriptor)) ?? []

        let items: [CPListItem] = stops.map { stop in
            let item = CPListItem(
                text: stop.stopName,
                detailText: "\(stop.service) • \(stop.routeName)",
                image: systemImage(for: stop.service)
            )
            item.userInfo = [
                "stopId": stop.stopId,
                "routeId": stop.routeId,
                "stopName": stop.stopName,
                "routeName": stop.routeName,
                "service": stop.service
            ]
            item.handler = { [weak self] _, completion in
                self?.showDepartures(for: stop)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "My Platforms", sections: [section])
        template.emptyViewTitleVariants = ["No Saved Platforms"]
        template.emptyViewSubtitleVariants = ["Add platforms from the iPhone app"]
        return template
    }

    private func systemImage(for service: String) -> UIImage? {
        let name: String
        switch service {
        case "Commuter Rail":
            name = "tram.fill"
        case "Subway":
            name = "train.side.front.car"
        case "Bus":
            name = "bus.fill"
        case "Ferry":
            name = "ferry.fill"
        default:
            name = "tram.fill"
        }
        return UIImage(systemName: name)?.withRenderingMode(.alwaysTemplate)
    }

    // MARK: - Departure Detail

    private func showDepartures(for stop: SavedStop) {
        currentStop = stop
        let template = CPListTemplate(title: stop.stopName, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        self.departureTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        fetchAndUpdateDepartures()
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.fetchAndUpdateDepartures()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Fetch Departures

    private func fetchAndUpdateDepartures() {
        guard let stop = currentStop else { return }

        var components = URLComponents(string: "https://api-v3.mbta.com/predictions")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[stop]", value: stop.stopId),
            URLQueryItem(name: "filter[route]", value: stop.routeId),
            URLQueryItem(name: "include", value: "trip,route"),
            URLQueryItem(name: "sort", value: "arrival_time"),
            URLQueryItem(name: "page[limit]", value: "10")
        ])
        guard let url = components.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, let data, error == nil else { return }
                guard let decoded = try? JSONDecoder().decode(MBTAInitialResponse.self, from: data) else { return }

                let result = parseMBTAInitialResponse(decoded)
                let predictions = result.predictions.sorted {
                    ($0.arrivalTime ?? $0.departureTime ?? .distantFuture) <
                    ($1.arrivalTime ?? $1.departureTime ?? .distantFuture)
                }

                let now = Date()
                var items: [CPListItem] = []

                for prediction in predictions {
                    let tripInfo = result.trips[prediction.tripId ?? ""]
                    let headsign = tripInfo?.headsign ?? "—"
                    let countdown = self.countdownText(for: prediction, now: now)

                    let item = CPListItem(
                        text: headsign,
                        detailText: countdown
                    )
                    items.append(item)
                }

                // Also fetch alerts
                self.fetchAlerts(for: stop) { alertItems in
                    var sections: [CPListSection] = []
                    if !alertItems.isEmpty {
                        sections.append(CPListSection(items: alertItems, header: "Alerts", sectionIndexTitle: nil))
                    }
                    sections.append(CPListSection(items: items, header: "Departures", sectionIndexTitle: nil))
                    self.departureTemplate?.updateSections(sections)
                }
            }
        }.resume()
    }

    private func fetchAlerts(for stop: SavedStop, completion: @escaping ([CPListItem]) -> Void) {
        var components = URLComponents(string: "https://api-v3.mbta.com/alerts")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[stop]", value: stop.stopId),
            URLQueryItem(name: "filter[route]", value: stop.routeId),
            URLQueryItem(name: "sort", value: "-severity")
        ])
        guard let url = components.url else { completion([]); return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data, error == nil else { completion([]); return }

                struct AlertsResponse: Decodable {
                    struct AlertData: Decodable {
                        let attributes: Attributes
                        struct Attributes: Decodable {
                            let header: String?
                            let effect: String?
                        }
                    }
                    let data: [AlertData]
                }

                guard let decoded = try? JSONDecoder().decode(AlertsResponse.self, from: data) else {
                    completion([])
                    return
                }

                let items: [CPListItem] = decoded.data.compactMap { alert in
                    guard let header = alert.attributes.header, !header.isEmpty else { return nil }
                    let effect = alert.attributes.effect?
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized ?? "Alert"
                    return CPListItem(
                        text: effect,
                        detailText: header,
                        image: UIImage(systemName: "exclamationmark.triangle.fill")
                    )
                }
                completion(items)
            }
        }.resume()
    }

    // MARK: - Helpers

    private func countdownText(for prediction: MBTAPrediction, now: Date) -> String {
        if prediction.scheduleRelationship == "CANCELLED" || prediction.scheduleRelationship == "CANCELED" {
            return "Canceled"
        }
        if let status = prediction.status, !status.isEmpty {
            return status
        }
        guard let arrivalDate = prediction.arrivalTime ?? prediction.departureTime else {
            return "—"
        }
        let seconds = arrivalDate.timeIntervalSince(now)
        if seconds <= 30 {
            return "Now"
        } else if seconds < 60 {
            return "Less than 1 min"
        } else {
            let minutes = Int(seconds / 60)
            return "\(minutes) min"
        }
    }
}
#endif
