// Claude Frame for iPad and iPhone.
//
// A full-screen shell around https://ai.liljimjim.com. The page keeps the
// face, memory, voices and self-updates; this app owns the microphone, speech
// recognition and the speaker, so listening and speaking stay reliable.

import SwiftUI
import UIKit

@main
struct ClaudeFrameApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            FrameWebView()
                .ignoresSafeArea()
                .background(Color.black)
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
