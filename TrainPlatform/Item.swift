//
//  Item.swift
//  TrainPlatform
//
//  Created by Bob Day on 3/25/26.
//

import Foundation
import SwiftData

@Model
final class SavedStop {
    var service: String
    var routeName: String
    var routeId: String
    var stopName: String
    var stopId: String
    var timestamp: Date

    init(service: String, routeName: String, routeId: String, stopName: String, stopId: String, timestamp: Date = .now) {
        self.service = service
        self.routeName = routeName
        self.routeId = routeId
        self.stopName = stopName
        self.stopId = stopId
        self.timestamp = timestamp
    }
}
