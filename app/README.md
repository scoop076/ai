# My Mibo app (iPad and iPhone)

A full-screen app that shows https://ai.liljimjim.com and handles the
microphone, speech recognition and speaker natively, so listening and
speaking stay reliable. The face, memory, voices and self-updates still come
from the website, so changes Jim approves by voice show up in the app too.

## Install on a device

1. On the Mac, open `MyMibo.xcodeproj` in Xcode.
2. Click **MyMibo** at the top of the left sidebar, then the
   **Signing & Capabilities** tab. Under **Team**, pick your Apple account
   (Add an Account... if it isn't listed).
3. If Xcode says the bundle identifier is taken, change
   `com.liljimjim.claudeframe` to something unique, like
   `com.liljimjim.claudeframe2`.
4. Plug the iPad (or iPhone) into the Mac, unlock it, and tap **Trust**.
   Turn on **Developer Mode** on the device when asked
   (Settings → Privacy & Security → Developer Mode), then restart it.
5. Pick the device in the bar at the top of Xcode and press **Run** (▶).
6. The first time, on the device: Settings → General → VPN & Device
   Management → your Apple account → **Trust**.
7. Open My Mibo, sign in with the Cloudflare email code once, tap the
   face, and allow the microphone and speech recognition.

With a free Apple account the app stops opening after 7 days; plug in and
press Run again to renew. A paid Apple Developer account ($99 a year) makes
it last a year and allows TestFlight installs without a cable.

## Using it

- Tap the face to talk, as in the browser.
- Pull down on the frame to reload it.
- The screen stays awake while the app is open.

## Mibo's built-in voice

The app speaks with Kokoro, an open voice model (Apache 2.0) that runs on the
device through Google's MediaPipe, so Mibo sounds the same on every iPhone and
iPad and works offline.

- The first time Xcode opens the project it fetches the MediaPipe package
  (File → Packages → Resolve Package Versions if it doesn't start on its own).
- The first time the app opens, it downloads the voice model (the CPU version, kokoro_int8_fp16)
  in the background. Use Wi-Fi. Until it's done, Mibo uses Apple's voices.
  Settings shows the download progress.
- Each character's Kokoro voice is set in `src/personas.js` (`kokoro:`);
  regular Mibo uses `af_heart`.
- If the MediaPipe package is missing, the app still builds and simply keeps
  using Apple's voices.

## TV mode

Screen-mirror the iPhone or iPad to an Apple TV (Control Center → Screen
Mirroring) and Mibo moves to the TV full screen, with its voice on the TV.
The device's own screen goes black with a small dim dot and keeps listening
for "Hey Mibo"; tap it to talk. Keep the app open and the device on its
charger. Stop mirroring and Mibo comes back to the device's screen.

