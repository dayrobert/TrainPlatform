//
//  MBTAEventSource.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import Foundation
import SwiftUI

// MARK: - Data Models

nonisolated struct MBTAPrediction: Identifiable, Sendable {
    let id: String
    let arrivalTime: Date?
    let departureTime: Date?
    let status: String?
    let directionId: Int?
    let scheduleRelationship: String?
    let tripId: String?
}

nonisolated struct MBTATripInfo: Sendable {
    let id: String
    let headsign: String
    let routeId: String
}

nonisolated struct MBTARouteInfo: Sendable {
    let id: String
    let color: Color
    let textColor: Color
    let shortName: String
    let longName: String
}

// MARK: - JSON Resources

nonisolated struct MBTAPredictionResource: Decodable, Sendable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Decodable, Sendable {
        let arrival_time: String?
        let departure_time: String?
        let status: String?
        let direction_id: Int?
        let schedule_relationship: String?
    }

    struct Relationships: Decodable, Sendable {
        let trip: Related?
        let route: Related?
    }

    struct Related: Decodable, Sendable {
        let data: RelatedData?
    }

    struct RelatedData: Decodable, Sendable {
        let id: String
    }

    func toPrediction() -> MBTAPrediction {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]

        func parse(_ str: String?) -> Date? {
            guard let str else { return nil }
            return formatter.date(from: str) ?? fallback.date(from: str)
        }

        return MBTAPrediction(
            id: id,
            arrivalTime: parse(attributes.arrival_time),
            departureTime: parse(attributes.departure_time),
            status: attributes.status,
            directionId: attributes.direction_id,
            scheduleRelationship: attributes.schedule_relationship,
            tripId: relationships?.trip?.data?.id
        )
    }
}

nonisolated struct MBTARemoveResource: Decodable, Sendable {
    let id: String
}

// MARK: - Initial Data Fetch (REST with includes)

struct MBTAInitialResponse: Decodable {
    let data: [MBTAPredictionResource]
    let included: [IncludedResource]?

    struct IncludedResource: Decodable {
        let id: String
        let type: String
        let attributes: RawAttributes

        struct RawAttributes: Decodable {
            // Trip fields
            let headsign: String?
            // Route fields
            let color: String?
            let text_color: String?
            let short_name: String?
            let long_name: String?
        }

        let relationships: Relationships?

        struct Relationships: Decodable {
            let route: Related?
        }

        struct Related: Decodable {
            let data: RelatedData?
        }

        struct RelatedData: Decodable {
            let id: String
        }
    }
}

func parseMBTAInitialResponse(_ response: MBTAInitialResponse) -> (predictions: [MBTAPrediction], trips: [String: MBTATripInfo], routes: [String: MBTARouteInfo]) {
    let predictions = response.data.map { $0.toPrediction() }

    var trips: [String: MBTATripInfo] = [:]
    var routes: [String: MBTARouteInfo] = [:]

    for item in response.included ?? [] {
        if item.type == "trip" {
            let routeId = item.relationships?.route?.data?.id ?? ""
            trips[item.id] = MBTATripInfo(
                id: item.id,
                headsign: item.attributes.headsign ?? "",
                routeId: routeId
            )
        } else if item.type == "route" {
            routes[item.id] = MBTARouteInfo(
                id: item.id,
                color: Color(hex: item.attributes.color ?? "888888"),
                textColor: Color(hex: item.attributes.text_color ?? "FFFFFF"),
                shortName: item.attributes.short_name ?? "",
                longName: item.attributes.long_name ?? item.id
            )
        }
    }

    return (predictions, trips, routes)
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - SSE Client

/// A lightweight Server-Sent Events (SSE) client for the MBTA V3 API.
/// Handles the event-stream protocol with reset, add, update, and remove events.
final class MBTAEventSource: NSObject, URLSessionDataDelegate {
    enum Event {
        case reset([MBTAPrediction])
        case add(MBTAPrediction)
        case update(MBTAPrediction)
        case remove(String) // id
    }

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = ""
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func connect(stopId: String, routeId: String) {
        disconnect()

        var components = URLComponents(string: "https://api-v3.mbta.com/predictions")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[stop]", value: stopId),
            URLQueryItem(name: "filter[route]", value: routeId),
            URLQueryItem(name: "sort", value: "arrival_time"),
            URLQueryItem(name: "page[limit]", value: "10")
        ])
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func disconnect() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = ""
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        processBuffer()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            logRateLimitHeaders(for: http, endpoint: "/predictions (SSE)")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Connection closed
    }

    // MARK: - SSE Parsing

    private func processBuffer() {
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            parseEvent(block)
        }
    }

    private func parseEvent(_ block: String) {
        var eventType: String?
        var dataLines: [String] = []

        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)))
            }
        }

        guard let eventType, !dataLines.isEmpty else { return }
        let jsonString = dataLines.joined()
        guard let jsonData = jsonString.data(using: .utf8) else { return }

        let decoder = JSONDecoder()

        switch eventType {
        case "reset":
            if let items = try? decoder.decode([MBTAPredictionResource].self, from: jsonData) {
                onEvent(.reset(items.map { $0.toPrediction() }))
            }
        case "add":
            if let item = try? decoder.decode(MBTAPredictionResource.self, from: jsonData) {
                onEvent(.add(item.toPrediction()))
            }
        case "update":
            if let item = try? decoder.decode(MBTAPredictionResource.self, from: jsonData) {
                onEvent(.update(item.toPrediction()))
            }
        case "remove":
            if let item = try? decoder.decode(MBTARemoveResource.self, from: jsonData) {
                onEvent(.remove(item.id))
            }
        default:
            break
        }
    }

    private func logRateLimitHeaders(for response: HTTPURLResponse, endpoint: String) {
        let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "n/a"
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "n/a"
        let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "n/a"
        print("[MBTA][RateLimit] \(endpoint) status=\(response.statusCode) limit=\(limit) remaining=\(remaining) reset=\(reset)")
    }
}
