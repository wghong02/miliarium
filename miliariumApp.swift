//
//  miliariumApp.swift
//  miliarium
//
//  Created by Gilbert Hong on 5/2/26.
//

import SwiftUI
import FirebaseCore

@main
struct miliariumApp: App {
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
