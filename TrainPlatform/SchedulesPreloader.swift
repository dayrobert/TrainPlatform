import Foundation
import SwiftData

final class SchedulesPreloader {
    static let shared = SchedulesPreloader()
    private init() {}

    private let calendar = Calendar(identifier: .gregorian)
    private var lastRunDate: Date?

    func prefetchIfNeeded(modelContainer: ModelContainer) {
        let today = Date()
        // Only run once per day
        if let last = lastRunDate, calendar.isDate(last, inSameDayAs: today) {
            return
        }
        lastRunDate = today

        Task { @MainActor in
            await prefetchAllStops(modelContainer: modelContainer)
        }
    }

    @MainActor
    private func prefetchAllStops(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SavedStop>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        let stops = (try? context.fetch(descriptor)) ?? []

        // Filter commuter rail stops (case-insensitive)
        let commuterStops = stops.filter { $0.service.localizedCaseInsensitiveContains("commuter") }
        guard !commuterStops.isEmpty else { return }

        for stop in commuterStops {
            await prefetchIfNeededFor(stop: stop)
        }
    }

    private func prefetchIfNeededFor(stop: SavedStop) async {
        let cacheKey = "scheduleLastFetch_\(stop.stopId)_\(stop.routeId)"
        let today = Date()
        if let last = UserDefaults.standard.object(forKey: cacheKey) as? Date,
           calendar.isDate(last, inSameDayAs: today) {
            // Already fetched today; skip
            return
        }

        do {
            // Fetch schedules for today; we don't keep the rows here, only stamp the cache on success
            let rows = try await MBTAScheduleService.fetchSchedulesForToday(apiKey: mbtaAPIKey, stopId: stop.stopId, routeId: stop.routeId)
            // Stamp cache for today regardless of row count to avoid repeated attempts in poor connectivity
            UserDefaults.standard.set(Date(), forKey: cacheKey)
            #if DEBUG
            print("[Preloader] Cached schedules for stop=\(stop.stopId) route=\(stop.routeId) rows=\(rows.count)")
            #endif
        } catch {
            #if DEBUG
            print("[Preloader] Failed to prefetch for stop=\(stop.stopId) route=\(stop.routeId):", error)
            #endif
        }
    }
}
