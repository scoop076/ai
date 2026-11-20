// Mibo's buzzes on the iPhone: a double-tap when it's your turn to talk, a light tap
// when Mibo heard you. Uses Core Haptics tied to the app's own audio session, because
// iOS blocks the simpler vibration calls while the microphone is on (Mibo's nearly always is).

import AVFoundation
import CoreHaptics

final class Buzzer {
    static let shared = Buzzer()
    private var engine: CHHapticEngine?

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("My Mibo: this device can't vibrate (iPads can't), so no buzzes.")
            return
        }
        do {
            let e = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.resetHandler = { [weak e] in try? e?.start() }
            engine = e
        } catch {
            print("My Mibo: buzzes unavailable: \(error)")
        }
    }

    /// Two firm taps: "your turn".
    func yourTurn() { play(at: [0, 0.13], intensity: 1.0, sharpness: 0.7, why: "your turn") }

    /// One light tap: "got it".
    func gotIt() { play(at: [0], intensity: 0.55, sharpness: 0.4, why: "got it") }

    private func play(at times: [TimeInterval], intensity: Float, sharpness: Float, why: String) {
        guard let engine else { return }
        let events = times.map { t in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: t)
        }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            print("My Mibo: buzz (\(why))")
        } catch {
            print("My Mibo: buzz (\(why)) failed: \(error)")
        }
    }
}
