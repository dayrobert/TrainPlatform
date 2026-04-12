//
//  ContentView.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedStop.timestamp, order: .reverse) private var savedStops: [SavedStop]

    @State private var showingAddSheet = false
    @State private var selectedStop: SavedStop?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top half: saved platforms list
                if savedStops.isEmpty {
                    ContentUnavailableView(
                        "No Saved Platforms",
                        systemImage: "tram",
                        description: Text("Tap + to add a platform.")
                    )
                } else {
                    Picker("Platform", selection: $selectedStop) {
                        ForEach(savedStops) { stop in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stop.stopName)
                                    .font(.headline)
                                Text("\(stop.service) • \(stop.routeName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(stop))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding()
                }

                Divider()

                // Bottom half: status messages
                if let stop = selectedStop {
                    PlatformStatusView(stop: stop)
                        .frame(maxHeight: .infinity)
                        .id(stop.persistentModelID)
                        .padding()
                } else {
                    VStack {
                        Spacer()
                        Text("Select a platform to view status")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("My Platforms")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let stop = selectedStop, savedStops.count > 0 {
                        Button(role: .destructive) {
                            if let idx = savedStops.firstIndex(where: { $0.persistentModelID == stop.persistentModelID }) {
                                deleteStops(at: IndexSet(integer: idx))
                            }
                        } label: {
                            Label("Delete Platform", systemImage: "trash")
                        }
                        .disabled(savedStops.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                StopSelectorView()
            }
            .onChange(of: savedStops) { _, newValue in
                // If the selected stop was deleted, clear selection
                if let selected = selectedStop,
                   !newValue.contains(where: { $0.persistentModelID == selected.persistentModelID }) {
                    selectedStop = nil
                }
                // Auto-select first stop if none selected
                if selectedStop == nil, let first = newValue.first {
                    selectedStop = first
                }
            }
            .onAppear {
                if selectedStop == nil, let first = savedStops.first {
                    selectedStop = first
                }
            }
        }
    }

    private func deleteStops(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(savedStops[index])
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedStop.self, inMemory: true)
}
