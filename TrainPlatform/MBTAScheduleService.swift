import Foundation

struct MBTAScheduleRow: Identifiable, Equatable {
    let id: String
    let tripId: String?
    let headsign: String
    let time: Date
    let platform: String?
}

enum MBTAScheduleService {
    static func fetchSchedulesForToday(apiKey: String, stopId: String, routeId: String) async throws -> [MBTAScheduleRow] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) else {
            return []
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startString = iso8601.string(from: startOfDay)
        let endString = iso8601.string(from: endOfDay)

        var components = URLComponents(string: "https://api-v3.mbta.com/schedules")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "filter[stop]", value: stopId),
            URLQueryItem(name: "filter[route]", value: routeId),
            URLQueryItem(name: "filter[min_time]", value: startString),
            URLQueryItem(name: "filter[max_time]", value: endString),
            URLQueryItem(name: "include", value: "trip,stop"),
            URLQueryItem(name: "sort", value: "arrival_time")
        ]

        guard let url = components.url else { return [] }
        print("[MBTA] Schedules URL:", url.absoluteString)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        struct ScheduleResponse: Decodable {
            struct ScheduleData: Decodable {
                let id: String
                let attributes: Attributes
                let relationships: Relationships?
                struct Attributes: Decodable {
                    let arrival_time: String?
                    let departure_time: String?
                }
                struct Relationships: Decodable {
                    let trip: Rel?
                    let stop: Rel?
                    struct Rel: Decodable { let data: IdObj? }
                    struct IdObj: Decodable { let id: String }
                }
            }
            struct Included: Decodable {
                let id: String
                let type: String
                let attributes: Attributes
                struct Attributes: Decodable {
                    let headsign: String?
                    let platform_code: String?
                }
            }
            let data: [ScheduleData]
            let included: [Included]?
        }

        let decoded = try JSONDecoder().decode(ScheduleResponse.self, from: data)
        print("[MBTA] schedules data count:", decoded.data.count)
        print("[MBTA] included count:", decoded.included?.count ?? 0)

        var tripHeadsigns: [String: String] = [:]
        var stopPlatforms: [String: String] = [:]
        if let included = decoded.included {
            for inc in included {
                switch inc.type {
                case "trip":
                    if let headsign = inc.attributes.headsign { tripHeadsigns[inc.id] = headsign }
                case "stop":
                    if let platform = inc.attributes.platform_code { stopPlatforms[inc.id] = platform }
                default:
                    break
                }
            }
        }

        let dateParserNoFrac = ISO8601DateFormatter()
        dateParserNoFrac.formatOptions = [.withInternetDateTime]

        let dateParserWithFrac = ISO8601DateFormatter()
        dateParserWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func parseISO8601(_ s: String) -> Date? {
            if let d = dateParserNoFrac.date(from: s) { return d }
            if let d = dateParserWithFrac.date(from: s) { return d }
            return nil
        }

        var rows: [MBTAScheduleRow] = []
        rows.reserveCapacity(decoded.data.count)
        for entry in decoded.data {
            let timeString = entry.attributes.arrival_time ?? entry.attributes.departure_time
            guard let timeString, let date = parseISO8601(timeString) else { continue }
            let tripId = entry.relationships?.trip?.data?.id
            let stopId = entry.relationships?.stop?.data?.id ?? ""
            let headsign = tripHeadsigns[tripId ?? ""] ?? "—"
            let platform = stopPlatforms[stopId]
            rows.append(MBTAScheduleRow(id: entry.id, tripId: tripId, headsign: headsign, time: date, platform: platform))
        }
        print("[MBTA] built rows:", rows.count)

        let upcoming = rows.filter { $0.time >= now }
        print("[MBTA] upcoming rows:", upcoming.count)
        return upcoming.sorted { $0.time < $1.time }
    }
}
