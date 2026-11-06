//
//  VideoChopChopApp.swift
//  VideoChopChop
//
//  Created by Jeffrey Barbose on 11/5/26.
//

import SwiftUI

@main
struct VideoChopChopApp: App {
    /// Shared by the main window and the Statistics window.
    @State private var model = VideoModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        // A normal, non-modal window (in the Window menu); it stays open beside the main window.
        Window("Statistics", id: StatisticsWindow.windowID) {
            StatisticsWindow(model: model)
        }
        .defaultSize(width: 980, height: 480)
    }
}
