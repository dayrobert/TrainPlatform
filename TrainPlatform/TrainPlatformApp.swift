//
//  TrainPlatformApp.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import SwiftUI
import SwiftData
import Combine

// Shared ModelContainer accessible from both SwiftUI and CarPlay scenes
enum SharedModelContainer {
    static let container: ModelContainer = {
        let schema = Schema([
            SavedStop.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if true {
            let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
            return config
        }
    }
}

@main
struct TrainPlatformApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(SharedModelContainer.container)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Prefetch schedules for all commuter rail stops once per day
                SchedulesPreloader.shared.prefetchIfNeeded(modelContainer: SharedModelContainer.container)
            }
        }
    }
}
