// My Mibo for iPad and iPhone.
//
// A full-screen shell around https://ai.liljimjim.com. The page keeps the
// face, memory, voices and self-updates; this app owns the microphone, speech
// recognition and the speaker, so listening and speaking stay reliable.

import SwiftUI
import UIKit

@main
struct MyMiboApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // hands an Apple TV to TV mode
    @Environment(\.scenePhase) private var phase
    @StateObject private var tv = TVMode.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                FrameWebView()
                    .ignoresSafeArea()
                    .background(Color(red: 217/255, green: 119/255, blue: 21/255))   // Mibo's orange, so nothing dark shows while the page loads
                if tv.active { TVPhoneScreen() }   // Mibo is on the TV: this screen goes dark and acts as the mic
            }
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onChange(of: phase) { _, now in
            // Keep the screen awake while the frame is showing.
            UIApplication.shared.isIdleTimerDisabled = (now == .active)
            if now == .active { NativeAudio.shared.activate(force: true) } else { NativeAudio.shared.stopAll() }
        }
    }
}
