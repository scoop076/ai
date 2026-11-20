import SwiftUI

@main
struct MiboTVApp: App {
    @StateObject private var convo = Conversation()

    var body: some Scene {
        WindowGroup {
            ContentView(convo: convo, speaker: convo.speaker)
        }
    }
}

struct ContentView: View {
    @ObservedObject var convo: Conversation
    @ObservedObject var speaker: Speaker
    @State private var showSettings = false

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
        .onAppear { if convo.needsSetup { showSettings = true } }
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
            if !speaker.line.isEmpty {
                karaoke(speaker.line, said: speaker.wordsSaid)
                    .font(.system(size: 46, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
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
                    Button("Save") {
                        s.clientID = s.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                        s.clientSecret = s.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        s.voiceHost = s.voiceHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        if s.voiceHost.isEmpty { s.voiceHost = "mibo-voice.local" }
                        convo.apply(s)
                        dismiss()
                    }
                }
            }
            .navigationTitle("My Mibo")
        }
        .onAppear { s = convo.currentSettings }
    }
}
