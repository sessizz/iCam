//
//  ICamApp.swift
//  iCam (iPhone)
//

import SwiftUI

@main
struct ICamApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .background: model.didEnterBackground()
            default: break
            }
        }
    }
}
