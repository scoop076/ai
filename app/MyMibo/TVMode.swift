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

/// What this device shows while Mibo is on the TV: black, with a small dim dot.
struct TVPhoneScreen: View {
    @State private var showHint = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(Color(red: 217/255, green: 119/255, blue: 21/255))
                .frame(width: 10, height: 10)
                .opacity(0.45)
            if showHint {
                Text("Mibo is on your TV.\nSay \u{201C}Hey Mibo\u{201D} or tap to talk.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(white: 0.55))
                    .offset(y: 70)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            TVMode.shared.tapFace()
            showHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { showHint = false }
        }
    }
}
