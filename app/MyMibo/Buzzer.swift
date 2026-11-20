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

    /// Two strong pulses, hard to miss: "your turn".
    func yourTurn() { play(pulses: [0, 0.22], length: 0.14, intensity: 1.0, sharpness: 0.45, why: "your turn") }

    /// One firm tap: "got it".
    func gotIt() { play(pulses: [0], length: 0.08, intensity: 0.85, sharpness: 0.5, why: "got it") }

    // Each pulse is a short continuous buzz (stronger than a single tap) with a crisp tap at its start.
    private func play(pulses: [TimeInterval], length: TimeInterval, intensity: Float, sharpness: Float, why: String) {
        guard let engine else { return }
        let strength = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
        var events: [CHHapticEvent] = []
        for t in pulses {
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: strength, relativeTime: t))
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: strength, relativeTime: t, duration: length))
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
