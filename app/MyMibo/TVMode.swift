// TV mode: when this iPhone or iPad is screen-mirrored to an Apple TV, Mibo
// moves to the TV full screen and this device's own screen goes black (on an
// iPhone's OLED screen, black pixels are off). The device keeps listening for
// "Hey Mibo" and acts as Mibo's microphone; Mibo's voice plays on the TV.
// Tapping the dark screen is the same as tapping Mibo's face.
//
// iOS lets an app show its own content on an AirPlay screen instead of a plain
// mirror: the TV arrives as a separate "external display" scene, and the one
// web view (with the page, its memory and its state) is moved onto it, then
// moved back when mirroring stops.

import SwiftUI
import UIKit
import WebKit

final class TVMode: ObservableObject {
    static let shared = TVMode()

    /// True while Mibo is showing on the TV.
    @Published private(set) var active = false

    /// What Mibo is doing ("idle", "listening", "thinking", "speaking"), shown on the phone in TV mode.
    @Published private(set) var miboState = "idle"
    @Published private(set) var waitingForWake = false

    /// The captions: Jim's words as he speaks, and Mibo's reply.
    @Published private(set) var youText = ""
    @Published private(set) var miboText = ""

    func showCaptions(you: String, mibo: String) {
        if you != youText { youText = you }
        if mibo != miboText { miboText = mibo }
    }
    private var idleTimer: DispatchWorkItem?
    // Buzzes (iPhone only; iPads have no vibration motor), whether or not Mibo is on the TV:
    // a clear double-tap when it's your turn to talk, a light tap when Mibo heard you. See Buzzer.swift.

    /// Called with each change the page reports. Buzzes mark "your turn" and "got it".
    func show(state: String, waitingForWake wake: Bool) {
        idleTimer?.cancel()
        if state == "idle" && !wake {
            // Mibo passes through "idle" for a moment between turns; don't flash it.
            let work = DispatchWorkItem { [weak self] in self?.apply("idle", wake: false) }
            idleTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        apply(state, wake: wake)
    }

    private func apply(_ state: String, wake: Bool) {
        if state != miboState { print("My Mibo: \(miboState) → \(state)") }
        if state == "listening" && miboState != "listening" { Buzzer.shared.yourTurn() }
        if state == "thinking" && miboState == "listening" { Buzzer.shared.gotIt() }
        miboState = state
        waitingForWake = wake
    }

    private weak var web: WKWebView?
    private weak var home: UIView?        // where the web view lives on this device
    private var tvWindow: UIWindow?

    /// Called by the frame's web view once it exists.
    func attach(web: WKWebView, home: UIView) {
        self.web = web
        self.home = home
        if let view = tvWindow?.rootViewController?.view { move(to: view) }   // the TV connected first
    }

    func connect(_ scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        let screen = UIViewController()
        screen.view.backgroundColor = miboOrange
        window.rootViewController = screen
        window.isHidden = false
        tvWindow = window
        move(to: screen.view)
        active = true
    }

    func disconnect() {
        if let home { move(to: home) }
        tvWindow?.isHidden = true
        tvWindow = nil
        active = false
    }

    private func move(to view: UIView) {
        guard let web, web.superview !== view else { return }
        web.removeFromSuperview()
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
    }

    /// Run a bit of the page's code (used by Car Mode to start listening).
    func runScript(_ js: String) {
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Tapping the dark phone screen = tapping Mibo's face on the TV.
    func tapFace() {
        web?.evaluateJavaScript("var s = document.getElementById('stage'); if (s) s.click();", completionHandler: nil)
    }
}

/// Holds the frame on this device's screen. From iOS 27 on, this is also where the app tells
/// iOS it has its own content for an external display (a "scene accessory"); without that,
/// iOS 27 just mirrors the phone. Older iOS versions use AppDelegate below instead.
final class FrameViewController: UIViewController {
    private let home: UIView
    private var tvRegistration: Any?   // a UISceneAccessoryRegistration on iOS 27

    init(home: UIView) {
        self.home = home
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = home }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 27.0, *) {
            let configuration = UISceneConfiguration()
            configuration.delegateClass = TVSceneDelegate.self
            let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
            tvRegistration = registerSceneAccessory(accessory)
        }
    }
}

/// Runs the TV's screen while mirroring.
final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        TVMode.shared.connect(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        TVMode.shared.disconnect()
    }
}

/// Before iOS 27: hands the TV (an external display) to TVSceneDelegate; everything else stays with SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "Mibo on TV", sessionRole: connectingSceneSession.role)
            config.delegateClass = TVSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

/// What this device shows while Mibo is on the TV: mostly black (pixels off on an OLED iPhone),
/// with a clear sign of what Mibo is doing so Jim knows when to talk. Tap anywhere = tap Mibo's face.
struct TVPhoneScreen: View {
    @ObservedObject private var tv = TVMode.shared
    /// Shown under the title while Mibo is resting.
    var restingNote = "Mibo is on your TV"

    private let orange = Color(red: 217/255, green: 119/255, blue: 21/255)
    private let teal = Color(red: 143/255, green: 211/255, blue: 200/255)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 20)
                TimelineView(.animation) { timeline in
                    sign(timeline.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: 150, height: 150)
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 32, weight: .semibold)).foregroundColor(titleColor)
                    Text(subtitle).font(.title3).foregroundColor(Color(white: 0.5))
                }
                .multilineTextAlignment(.center)
                captions
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture { TVMode.shared.tapFace() }
        .animation(.easeInOut(duration: 0.25), value: tv.miboState)
    }

    /// What Jim is saying, then Mibo's reply. Long text shows its newest lines.
    @ViewBuilder
    private var captions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !tv.youText.isEmpty {
                caption(label: "You", text: tv.youText, color: Color(white: 0.85), lines: 3)
            }
            if !tv.miboText.isEmpty {
                caption(label: "Mibo", text: tv.miboText, color: orange, lines: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: tv.youText.isEmpty)
    }

    private func caption(label: String, text: String, color: Color, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption.weight(.semibold)).foregroundColor(Color(white: 0.4))
            Text(text)
                .font(.title3)
                .foregroundColor(color)
                .lineLimit(lines)
                .truncationMode(.head)   // keep the newest words in view
        }
    }

    private var title: String {
        switch tv.miboState {
        case "listening": return "Listening"
        case "thinking": return "Thinking\u{2026}"
        case "speaking": return "Mibo is talking"
        default: return tv.waitingForWake ? "Say \u{201C}Hey Mibo\u{201D}" : "Tap to talk"
        }
    }

    private var subtitle: String {
        switch tv.miboState {
        case "listening": return "Go ahead and talk. Tap to stop."
        case "thinking": return "One moment"
        case "speaking": return "Tap to interrupt"
        default: return restingNote
        }
    }

    private var titleColor: Color {
        switch tv.miboState {
        case "listening": return teal
        case "thinking", "speaking": return orange
        default: return Color(white: 0.45)
        }
    }

    @ViewBuilder
    private func sign(_ t: TimeInterval) -> some View {
        switch tv.miboState {
        case "listening":
            // A bright teal ring that breathes, with ripples moving out: "your turn".
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let p = (t * 0.7 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(teal.opacity(0.6 * (1 - p)), lineWidth: 3).scaleEffect(0.55 + 0.45 * p)
                }
                Circle().fill(teal).frame(width: 70, height: 70).scaleEffect(1 + 0.08 * sin(t * 4))
            }
        case "thinking":
            // Three orange dots taking turns.
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(orange).frame(width: 22, height: 22)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 4 - Double(i) * 0.9)))
                }
            }
        case "speaking":
            // Orange bars moving like a voice.
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(orange)
                        .frame(width: 14, height: 30 + 60 * abs(sin(t * 5 + Double(i) * 1.3)))
                }
            }
        default:
            // Resting: a small dim dot.
            Circle().fill(orange).frame(width: 12, height: 12).opacity(tv.waitingForWake ? 0.5 : 0.3)
        }
    }
}
