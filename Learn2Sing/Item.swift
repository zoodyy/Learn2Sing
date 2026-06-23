//
//  Item.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
