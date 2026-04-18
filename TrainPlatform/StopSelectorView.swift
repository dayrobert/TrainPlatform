//
//  StopSelectorView.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import SwiftUI
import SwiftData


enum MBTAService: String, CaseIterable, Identifiable {
    case commuterRail = "Commuter Rail"
    case subway = "Subway"
    case bus = "Bus"
    case ferry = "Ferry"

    var id: String { rawValue }
}

struct RouteOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct StopOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct StopSelectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedService: MBTAService = .commuterRail
    @State private var routeOptions: [RouteOption] = []
    @State private var selectedRoute: RouteOption? = nil
    @State private var isLoadingRoutes = false
    @State private var routeLoadError: String? = nil

    @State private var stopOptions: [StopOption] = []
    @State private var selectedStop: StopOption? = nil
    @State private var isLoadingStops = false
    @State private var stopLoadError: String? = nil

    // Simple in-memory caches
    @State private var routeCache: [MBTAService: [RouteOption]] = [:]
    @State private var stopCache: [String: [StopOption]] = [:] // key: routeId

    @State private var selectedDirection: Int? = nil // 0 or 1 for subway
    @State private var availableDirections: [Int] = []
    @State private var directionNames: [Int: String] = [:] // direction_id -> label

    private var canSave: Bool {
        selectedRoute != nil && selectedStop != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Massachusetts Bay Transportation")) {
                    Picker("Service", selection: $selectedService) {
                        ForEach(MBTAService.allCases) { service in
                            Text(service.rawValue).tag(service)
                        }
                    }
                    .pickerStyle(.menu)

                    if isLoadingRoutes {
                        ProgressView("Loading routes…")
                    } else if let routeLoadError {
                        Text(routeLoadError)
                            .foregroundStyle(.red)
                    } else {
                        Picker("Route", selection: Binding(
                            get: { selectedRoute },
                            set: { selectedRoute = $0 }
                        )) {
                            ForEach(routeOptions) { option in
                                Text(option.name).tag(Optional(option))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(routeOptions.isEmpty)
                    }

                    // Direction picker (Subway only)
                    if selectedService == .subway, let _ = selectedRoute, !availableDirections.isEmpty {
                        Picker("Direction", selection: Binding(
                            get: { selectedDirection ?? availableDirections.first },
                            set: { selectedDirection = $0 }
                        )) {
                            ForEach(availableDirections, id: \.self) { dir in
                                Text(directionNames[dir] ?? (dir == 0 ? "Inbound" : "Outbound")).tag(Optional(dir))
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Stops picker
                    if selectedRoute != nil {
                        if isLoadingStops {
                            ProgressView("Loading stops…")
                        } else if let stopLoadError {
                            Text(stopLoadError)
                                .foregroundStyle(.red)
                        } else {
                            Picker("Stop", selection: Binding(
                                get: { selectedStop },
                                set: { selectedStop = $0 }
                            )) {
                                ForEach(stopOptions) { stop in
                                    Text(stop.name).tag(Optional(stop))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(stopOptions.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Add Platform")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                loadOptions(for: selectedService)
            }
            .onChange(of: selectedService) { _, newValue in
                loadOptions(for: newValue)
            }
            .onChange(of: selectedRoute) { _, newValue in
                loadStops(for: newValue)
                if selectedService == .subway, let rid = newValue?.id {
                    fetchRouteDirectionNames(routeId: rid) { names in
                        directionNames = names
                    }
                } else {
                    directionNames = [:]
                }
            }
            .onChange(of: selectedDirection) { _, _ in
                loadStops(for: selectedRoute)
            }
        }
    }

    private func save() {
        guard let route = selectedRoute, let stop = selectedStop else { return }
        let savedStop = SavedStop(
            service: selectedService.rawValue,
            routeName: route.name,
            routeId: route.id,
            stopName: stop.name,
            stopId: stop.id
        )
        modelContext.insert(savedStop)
        dismiss()
    }

    // MARK: - Route Loading

    private func loadOptions(for service: MBTAService) {
        routeLoadError = nil
        selectedRoute = nil
        stopOptions = []
        selectedStop = nil
        stopLoadError = nil
        selectedDirection = nil
        availableDirections = []
        directionNames = [:]

        if let cached = routeCache[service], !cached.isEmpty {
            routeOptions = cached
            selectedRoute = cached.first
            return
        }

        switch service {
        case .subway:
            fetchSubwayRoutes()
        case .commuterRail:
            fetchRoutes(routeTypes: [2])
        case .bus:
            fetchRoutes(routeTypes: [3])
        case .ferry:
            fetchRoutes(routeTypes: [4])
        }
    }

    private struct MBTARoutesResponse: Decodable {
        struct RouteData: Decodable {
            let id: String
            let attributes: Attributes
            struct Attributes: Decodable { let long_name: String?; let short_name: String? }
        }
        let data: [RouteData]
    }

    private func fetchRoutes(routeTypes: [Int]) {
        isLoadingRoutes = true
        routeOptions = []
        var components = URLComponents(string: "https://api-v3.mbta.com/routes")!
        let typesValue = routeTypes.map(String.init).joined(separator: ",")
        var queryItems: [URLQueryItem] = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[type]", value: typesValue)
        ])
        if routeTypes == [3] {
            queryItems.append(URLQueryItem(name: "filter[active]", value: "true"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            isLoadingRoutes = false
            routeLoadError = "Failed to build request."
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoadingRoutes = false
                if let error = error {
                    routeLoadError = "Network error: \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    routeLoadError = "No data received."
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(MBTARoutesResponse.self, from: data)
                    let options: [RouteOption] = decoded.data.map { route in
                        let name = route.attributes.long_name?.isEmpty == false ? route.attributes.long_name! : (route.attributes.short_name ?? route.id)
                        return RouteOption(id: route.id, name: name)
                    }
                    routeOptions = options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    selectedRoute = routeOptions.first
                    routeCache[selectedService] = routeOptions
                } catch {
                    routeLoadError = "Failed to parse routes."
                }
            }
        }.resume()
    }

    private func fetchSubwayRoutes() {
        isLoadingRoutes = true
        routeOptions = []
        routeLoadError = nil
        var components = URLComponents(string: "https://api-v3.mbta.com/routes")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[type]", value: "0,1")
        ])
        guard let url = components.url else {
            isLoadingRoutes = false
            routeLoadError = "Failed to build request."
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoadingRoutes = false
                if let error = error {
                    routeLoadError = "Network error: \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    routeLoadError = "No data received."
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(MBTARoutesResponse.self, from: data)
                    let allowedIDs: Set<String> = ["Red", "Orange", "Blue", "Green-B", "Green-C", "Green-D", "Green-E"]
                    let options: [RouteOption] = decoded.data
                        .filter { allowedIDs.contains($0.id) }
                        .map { RouteOption(id: $0.id, name: $0.attributes.long_name ?? $0.id) }
                    fetchSilverLineRoutes { silverOptions in
                        var merged = options
                        let existingIDs = Set(merged.map { $0.id })
                        let toAdd = silverOptions.filter { !existingIDs.contains($0.id) }
                        merged.append(contentsOf: toAdd)
                        merged.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        routeOptions = merged
                        selectedRoute = routeOptions.first
                        routeCache[.subway] = routeOptions
                    }
                    return
                } catch {
                    routeLoadError = "Failed to parse routes."
                }
            }
        }.resume()
    }

    private func fetchRouteDirectionNames(routeId: String, completion: @escaping ([Int: String]) -> Void) {
        var components = URLComponents(string: "https://api-v3.mbta.com/routes/\(routeId)")!
        components.queryItems = mbtaAPIQueryItems([])
        guard let url = components.url else { completion([:]); return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data else { completion([:]); return }
                do {
                    struct RouteDetailResponse: Decodable {
                        struct DataObj: Decodable { let id: String; let attributes: Attrs }
                        struct Attrs: Decodable { let direction_destinations: [String]? }
                        let data: DataObj
                    }
                    let decoded = try JSONDecoder().decode(RouteDetailResponse.self, from: data)
                    let names = decoded.data.attributes.direction_destinations ?? []
                    var map: [Int: String] = [:]
                    for (idx, name) in names.enumerated() { map[idx] = name }
                    completion(map)
                } catch { completion([:]) }
            }
        }.resume()
    }

    private func fetchSilverLineRoutes(completion: @escaping ([RouteOption]) -> Void) {
        var components = URLComponents(string: "https://api-v3.mbta.com/routes")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[type]", value: "3"),
            URLQueryItem(name: "filter[active]", value: "true")
        ])
        guard let url = components.url else {
            completion([])
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data else {
                    completion([])
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(MBTARoutesResponse.self, from: data)
                    let silver = decoded.data.compactMap { route -> RouteOption? in
                        if let short = route.attributes.short_name, short.uppercased().hasPrefix("SL") {
                            let name = route.attributes.long_name ?? short
                            return RouteOption(id: route.id, name: name)
                        }
                        return nil
                    }
                    completion(silver)
                } catch {
                    completion([])
                }
            }
        }.resume()
    }

    // MARK: - Stop Loading

    private struct MBTASchedulesWithStopsResponse: Decodable {
        struct ScheduleData: Decodable {
            let id: String
            let attributes: Attributes
            let relationships: Relationships
            struct Attributes: Decodable { let stop_sequence: Int?; let direction_id: Int? }
            struct Relationships: Decodable { let stop: Related }
            struct Related: Decodable { let data: RelatedData? }
            struct RelatedData: Decodable { let id: String }
        }
        struct IncludedData: Decodable {
            let id: String
            let type: String
            let attributes: StopAttributes?
            struct StopAttributes: Decodable { let name: String? }
        }
        let data: [ScheduleData]
        let included: [IncludedData]?
    }

    private func isZoneStopId(_ stopId: String) -> Bool {
        stopId.hasPrefix("CR-zone-") || stopId.hasPrefix("zone-")
    }

    private func loadStops(for route: RouteOption?) {
        stopLoadError = nil
        stopOptions = []
        selectedStop = nil
        guard let route else { return }
        if let cached = stopCache[route.id], !cached.isEmpty, !(selectedService == .subway && selectedDirection != nil) {
            stopOptions = cached
            selectedStop = cached.first
            return
        }
        isLoadingStops = true
        fetchSchedulesWithStops(for: route.id) { stops, orderMap, directions in
            self.isLoadingStops = false
            self.availableDirections = Array(directions).sorted()
            if self.selectedService == .subway, self.selectedDirection == nil {
                self.selectedDirection = self.availableDirections.first
            }
            let finalOrder: [String: Int]
            if let dir = self.selectedDirection, self.selectedService == .subway {
                finalOrder = orderMap.filter { $0.value.direction == dir }.reduce(into: [:]) { acc, elem in
                    acc[elem.key] = elem.value.sequence
                }
            } else {
                finalOrder = orderMap.reduce(into: [:]) { acc, elem in
                    acc[elem.key] = elem.value.sequence
                }
            }
            let activeSet = Set(finalOrder.keys)
            var filtered = stops.filter { activeSet.contains($0.id) }
            filtered.sort { (a, b) -> Bool in
                let sa = finalOrder[a.id] ?? Int.max
                let sb = finalOrder[b.id] ?? Int.max
                if sa == sb { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                return sa < sb
            }
            self.stopOptions = filtered
            self.selectedStop = filtered.first
            if !(self.selectedService == .subway && self.selectedDirection != nil) {
                self.stopCache[route.id] = filtered
            }
        }
    }

    private func fetchSchedulesWithStops(for routeId: String, completion: @escaping ([StopOption], [String: (sequence: Int, direction: Int)], Set<Int>) -> Void) {
        var components = URLComponents(string: "https://api-v3.mbta.com/schedules")!
        components.queryItems = mbtaAPIQueryItems([
            URLQueryItem(name: "filter[route]", value: routeId),
            URLQueryItem(name: "include", value: "stop"),
            URLQueryItem(name: "page[limit]", value: "2000")
        ])
        guard let url = components.url else { completion([], [:], []); return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data else {
                    self.stopLoadError = "Network error."
                    completion([], [:], [])
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(MBTASchedulesWithStopsResponse.self, from: data)
                    var stopLookup: [String: String] = [:]
                    for item in decoded.included ?? [] where item.type == "stop" {
                        if isZoneStopId(item.id) { continue }
                        if let name = item.attributes?.name {
                            stopLookup[item.id] = name
                        }
                    }
                    var order: [String: (sequence: Int, direction: Int)] = [:]
                    var dirs: Set<Int> = []
                    for item in decoded.data {
                        guard let stopId = item.relationships.stop.data?.id else { continue }
                        if isZoneStopId(stopId) { continue }
                        let seq = item.attributes.stop_sequence ?? Int.max
                        let dir = item.attributes.direction_id ?? 0
                        dirs.insert(dir)
                        if let existing = order[stopId] {
                            if seq < existing.sequence {
                                order[stopId] = (seq, dir)
                            }
                        } else {
                            order[stopId] = (seq, dir)
                        }
                    }
                    let stops: [StopOption] = stopLookup.map { StopOption(id: $0.key, name: $0.value) }
                    completion(stops, order, dirs)
                } catch {
                    self.stopLoadError = "Failed to parse schedule data."
                    completion([], [:], [])
                }
            }
        }.resume()
    }
}
