//
//  PlatformStatusView.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import SwiftUI

struct AlertHeaderWrapper: Identifiable {
    let id = UUID()
    let text: String
}

struct PlatformStatusView: View {
    let stop: SavedStop

    @State private var predictions: [MBTAPrediction] = []
    @State private var tripInfos: [String: MBTATripInfo] = [:]
    @State private var routeInfos: [String: MBTARouteInfo] = [:]
    @State private var alertHeaders: [String] = []
    @State private var isLoading = false
    @State private var eventSource: MBTAEventSource?
    @State private var alertRefreshTimer: Timer?
    @State private var displayRefreshTimer: Timer?
    @State private var now = Date()
    @State private var selectedAlertHeader: AlertHeaderWrapper? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Station header
            Text(stop.stopName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Alert banner if present
            ForEach(alertHeaders, id: \.self) { header in
                Button {
                    selectedAlertHeader = AlertHeaderWrapper(text: header)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(header)
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            if isLoading && predictions.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.white)
                    Spacer()
                }
                Spacer()
            } else if predictions.isEmpty {
                Spacer()
                Text("No upcoming departures")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(predictions) { prediction in
                            DepartureRow(
                                prediction: prediction,
                                tripInfo: tripInfos[prediction.tripId ?? ""],
                                routeInfo: routeForPrediction(prediction),
                                now: now
                            )
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            fetchInitialData()
            fetchAlerts()
            startAlertTimer()
            startDisplayTimer()
        }
        .onDisappear {
            stopAll()
        }
        .alert(item: $selectedAlertHeader) { alert in
            Alert(title: Text("Alert"), message: Text(alert.text), dismissButton: .default(Text("OK")))
        }
    }

    private func routeForPrediction(_ prediction: MBTAPrediction) -> MBTARouteInfo? {
        if let tripId = prediction.tripId, let trip = tripInfos[tripId] {
            return routeInfos[trip.routeId]
        }
        // Fallback: return the first route (usually only one for a filtered query)
        return routeInfos.values.first
    }

    // MARK: - Initial REST Fetch (with includes)

    private func fetchInitialData() {
        isLoading = true
        var components = URLComponents(string: "https://api-v3.mbta.com/predictions")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: mbtaAPIKey),
            URLQueryItem(name: "filter[stop]", value: stop.stopId),
            URLQueryItem(name: "filter[route]", value: stop.routeId),
            URLQueryItem(name: "include", value: "trip,route"),
            URLQueryItem(name: "sort", value: "arrival_time"),
            URLQueryItem(name: "page[limit]", value: "10")
        ]
        guard let url = components.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data,
                      let decoded = try? JSONDecoder().decode(MBTAInitialResponse.self, from: data) else {
                    self.isLoading = false
                    self.startStreaming()
                    return
                }
                let result = parseMBTAInitialResponse(decoded)
                self.predictions = result.predictions.sorted { sortPrediction($0, before: $1) }
                self.tripInfos = result.trips
                self.routeInfos = result.routes
                self.isLoading = false
                self.startStreaming()
            }
        }.resume()
    }

    // MARK: - SSE Streaming

    private func startStreaming() {
        let source = MBTAEventSource { event in
            switch event {
            case .reset(let items):
                predictions = items.sorted { sortPrediction($0, before: $1) }
            case .add(let item):
                if !predictions.contains(where: { $0.id == item.id }) {
                    predictions.append(item)
                    predictions.sort { sortPrediction($0, before: $1) }
                }
            case .update(let item):
                if let idx = predictions.firstIndex(where: { $0.id == item.id }) {
                    predictions[idx] = item
                    predictions.sort { sortPrediction($0, before: $1) }
                }
            case .remove(let id):
                predictions.removeAll { $0.id == id }
            }
        }
        source.connect(stopId: stop.stopId, routeId: stop.routeId)
        eventSource = source
    }

    private func sortPrediction(_ a: MBTAPrediction, before b: MBTAPrediction) -> Bool {
        let aDate = a.arrivalTime ?? a.departureTime ?? .distantFuture
        let bDate = b.arrivalTime ?? b.departureTime ?? .distantFuture
        return aDate < bDate
    }

    private func stopAll() {
        eventSource?.disconnect()
        eventSource = nil
        alertRefreshTimer?.invalidate()
        alertRefreshTimer = nil
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
    }

    private func startDisplayTimer() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            now = Date()
        }
    }

    // MARK: - Alerts

    private func startAlertTimer() {
        alertRefreshTimer?.invalidate()
        alertRefreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            fetchAlerts()
        }
    }

    private struct AlertsResponse: Decodable {
        struct AlertData: Decodable {
            let attributes: Attributes
            struct Attributes: Decodable {
                let header: String?
                let severity: Int?
            }
        }
        let data: [AlertData]
    }

    private func fetchAlerts() {
        var components = URLComponents(string: "https://api-v3.mbta.com/alerts")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: mbtaAPIKey),
            URLQueryItem(name: "filter[stop]", value: stop.stopId),
            URLQueryItem(name: "filter[route]", value: stop.routeId),
            URLQueryItem(name: "sort", value: "-severity")
        ]
        guard let url = components.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data,
                      let decoded = try? JSONDecoder().decode(AlertsResponse.self, from: data) else { return }
                alertHeaders = decoded.data.compactMap { $0.attributes.header }
            }
        }.resume()
    }
}

// MARK: - Departure Row

struct DepartureRow: View {
    let prediction: MBTAPrediction
    let tripInfo: MBTATripInfo?
    let routeInfo: MBTARouteInfo?
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            // Route badge
            RouteBadge(routeInfo: routeInfo)

            // Headsign / destination
            VStack(alignment: .leading, spacing: 2) {
                Text(tripInfo?.headsign ?? "—")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            // Countdown or status
            Text(countdownText)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(countdownColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var countdownText: String {
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
            return "<1m"
        } else {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        }
    }

    private var countdownColor: Color {
        if prediction.scheduleRelationship == "CANCELLED" || prediction.scheduleRelationship == "CANCELED" {
            return .red
        }
        guard let arrivalDate = prediction.arrivalTime ?? prediction.departureTime else {
            return .gray
        }
        let seconds = arrivalDate.timeIntervalSince(now)
        if seconds <= 60 {
            return .green
        }
        return .white
    }
}

// MARK: - Route Badge

struct RouteBadge: View {
    let routeInfo: MBTARouteInfo?

    var body: some View {
        let label = routeInfo?.shortName.isEmpty == false ? routeInfo!.shortName : String(routeInfo?.longName.prefix(2) ?? "?")
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(routeInfo?.textColor ?? .white)
            .frame(width: 30, height: 30)
            .background(routeInfo?.color ?? .gray)
            .clipShape(Circle())
    }
}
