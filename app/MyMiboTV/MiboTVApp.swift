import SwiftUI
import UIKit

@main
struct MiboTVApp: App {
    @StateObject private var convo = Conversation()

    var body: some Scene {
        WindowGroup {
            ContentView(convo: convo, speaker: convo.speaker, movie: convo.movie)
        }
    }
}

struct ContentView: View {
    @ObservedObject var convo: Conversation
    @ObservedObject var speaker: Speaker
    @ObservedObject var movie: MoviePlayer
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            FaceView(convo: convo, speaker: speaker)

            VStack(spacing: 18) {
                if !convo.note.isEmpty {
                    Text(convo.note)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Mibo.eye.opacity(0.75))
                        .padding(.top, 40)
                }
                Spacer()
                captions
                    .padding(.horizontal, 160)
                    .padding(.bottom, 70)
            }

            // Mibo's doze: fades to dark, with the face still softly visible (Jim: 0.9 was too dark).
            Color.black
                .opacity(convo.dozing ? 0.75 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: convo.dozing ? 4 : 0.6), value: convo.dozing)

            // The whole screen is one button: click to talk, or to stop Mibo talking.
            // Press and hold for settings.
            Button(action: { convo.remoteTap() }) { Color.clear }
                .buttonStyle(.mibo)
                .contextMenu {
                    Button("Settings") { showSettings = true }
                    Button("Reload voices and personality") { Task { await convo.loadPrefs() } }
                }
        }
        .onPlayPauseCommand { convo.remoteStop() }
        .sheet(isPresented: $showSettings) { SettingsView(convo: convo) }
        // Plex movies play full-screen; Menu on the remote stops the movie.
        .fullScreenCover(isPresented: $movie.showing, onDismiss: { movie.close() }) {
            ZStack(alignment: .bottomLeading) {
                MoviePlayerView(player: movie.player).ignoresSafeArea()
                // The movie's name for a few seconds when it starts.
                if movie.showTitleCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(movie.title)
                            .font(.system(size: 64, weight: .bold))
                        if !movie.year.isEmpty {
                            Text(movie.year)
                                .font(.system(size: 34, weight: .medium))
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 12)
                    .padding(.leading, 90)
                    .padding(.bottom, 80)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 1), value: movie.showTitleCard)
        }
        .onAppear {
            // Keep the Apple screensaver away while My Mibo is open; Mibo dozes on its own instead.
            UIApplication.shared.isIdleTimerDisabled = true
            if convo.needsSetup { showSettings = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true; convo.touch(); convo.onScreen(true) }
            if phase == .background { convo.onScreen(false) }
        }
        .onChange(of: convo.needsSetup) { _, now in if now { showSettings = true } }
    }

    /// What you said, and the sentence Mibo is saying with its words lighting up as they're spoken.
    private var captions: some View {
        VStack(spacing: 14) {
            if !convo.youText.isEmpty && convo.state != .idle {
                Text(convo.youText)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Mibo.eye.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            if convo.showWakeHint && speaker.line.isEmpty {
                Text("Say \u{201C}Hey Mibo\u{201D}")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Mibo.eye.opacity(0.6))
                    .transition(.opacity)
            }
            if !speaker.line.isEmpty {
                karaoke(speaker.line, said: speaker.wordsSaid)
                    .font(.system(size: 46, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.4), value: convo.showWakeHint)
    }

    private func karaoke(_ line: String, said: Int) -> Text {
        let words = Speaker.words(line)
        var out = Text("")
        for (i, w) in words.enumerated() {
            out = out + Text((i == 0 ? "" : " ") + w).foregroundColor(Mibo.eye.opacity(i < said ? 1 : 0.38))
        }
        return out
    }
}

/// A full-screen button with no visible focus effect.
struct MiboButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}
extension ButtonStyle where Self == MiboButtonStyle {
    static var mibo: MiboButtonStyle { MiboButtonStyle() }
}

struct SettingsView: View {
    @ObservedObject var convo: Conversation
    @Environment(\.dismiss) private var dismiss
    @State private var s = TVSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $s.clientID)
                    SecureField("Client Secret", text: $s.clientSecret)
                } header: {
                    Text("Cloudflare Access service token")
                } footer: {
                    Text("From Cloudflare Zero Trust \u{2192} Access \u{2192} Service Auth. You can type with your iPhone when the keyboard appears.")
                }
                Section {
                    TextField("Address", text: $s.voiceHost)
                } header: {
                    Text("Mibo Voice speaker")
                } footer: {
                    Text("Usually mibo-voice.local")
                }
                Section {
                    TextField("Name", text: $s.screenName)
                } header: {
                    Text("This screen")
                } footer: {
                    Text("Mibo uses this to know which room you're in.")
                }
                Section {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Text("Save and close")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("The Back button on the remote saves too.")
                }
            }
            .navigationTitle("My Mibo")
        }
        .onAppear { s = convo.currentSettings; loaded = true }
        .onDisappear { save() }
    }

    @State private var loaded = false

    /// Saves only what changed, so closing Settings doesn't reconnect for nothing.
    private func save() {
        guard loaded else { return }
        s.clientID = s.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        s.clientSecret = s.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        s.voiceHost = s.voiceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.voiceHost.isEmpty { s.voiceHost = "mibo-voice.local" }
        let old = convo.currentSettings
        if s.clientID != old.clientID || s.clientSecret != old.clientSecret || s.voiceHost != old.voiceHost || s.screenName != old.screenName {
            convo.apply(s)
        }
    }
}
