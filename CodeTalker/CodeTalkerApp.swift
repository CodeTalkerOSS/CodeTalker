//
//  CodeTalkerApp.swift
//  CodeTalker
//
//  Created by Peter C. Allport on 5/27/26.
//

import SwiftUI

@main
struct CodeTalkerApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(CodeTalkerAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
#if os(macOS)
        Settings {
            SettingsView()
        }
#else
        WindowGroup {
            ContentView()
        }
#endif
    }
}
