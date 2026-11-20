// Car Mode: talk to Mibo while driving, with the phone in your pocket.
//
// - Uses the car's hands-free Bluetooth connection, so Mibo hears you through the car's
//   microphone and talks through the car's speakers.
// - Turns on the proximity sensor (like a phone call): in a pocket the screen goes dark and
//   ignores touches, while Mibo keeps running. Don't lock the phone; just put it away.
// - The phone shows big status and captions (the same screen as TV mode) and an End button.
// - Starts from the "Talk to Mibo in the car" shortcut, which a Shortcuts automation can run
//   whenever the phone connects to the car's Bluetooth. Ends with the button, or by itself
//   when the car's Bluetooth disconnects.

import AppIntents
import AVFoundation
import SwiftUI
import UIKit

final class CarMode: ObservableObject {
    static let shared = CarMode()
    @Published private(set) var on = false
    private var routeWatch: NSObjectProtocol?

    func start() {
        if !on {
            on = true
            UIDevice.current.isProximityMonitoringEnabled = true
            NativeAudio.shared.setCarMode(true)
            watchForCarLeaving()
            print("My Mibo: Car Mode on")
        }
        // Start listening right away (the page also does this when the app opens).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            TVMode.shared.runScript("window.miboListenNow && window.miboListenNow()")
        }
    }

    func stop() {
        guard on else { return }
        on = false
        UIDevice.current.isProximityMonitoringEnabled = false
        NativeAudio.shared.setCarMode(false)
        if let w = routeWatch { NotificationCenter.default.removeObserver(w) }
        routeWatch = nil
        print("My Mibo: Car Mode off")
    }

    /// End Car Mode when the car's Bluetooth goes away (you parked and walked off).
    private func watchForCarLeaving() {
        guard routeWatch == nil else { return }
        routeWatch = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
                  let old = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription else { return }
            let carPorts: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .carAudio]
            if old.outputs.contains(where: { carPorts.contains($0.portType) }) { self?.stop() }
        }
    }
}

/// "Talk to Mibo in the car": shows up in the Shortcuts app and works with Siri.
struct StartCarModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Mibo in the car"
    static var description = IntentDescription("Opens My Mibo in Car Mode: the car's microphone and speakers, with the screen off in your pocket.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CarMode.shared.start()
        return .result()
    }
}

struct MiboShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCarModeIntent(),
            phrases: [
                "Start car mode in \(.applicationName)",
                "Talk to \(.applicationName) in the car",
            ],
            shortTitle: "Car Mode",
            systemImageName: "car.fill"
        )
    }
}

/// The phone's screen in Car Mode: the TV-mode status screen, plus an End button.
struct CarScreen: View {
    var body: some View {
        ZStack(alignment: .top) {
            TVPhoneScreen(restingNote: "Car Mode · put the phone away")
            Button {
                CarMode.shared.stop()
            } label: {
                Label("End Car Mode", systemImage: "car.fill")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color(white: 0.15)))
                    .foregroundColor(Color(white: 0.8))
            }
            .padding(.top, 12)
        }
    }
}
