# Mibo on the Apple TV, with the Voice PE as its ears

```
"Hey Mibo" ─▶ Mibo Voice (Voice PE) ──Wi-Fi──▶ My Mibo on the Apple TV ──▶ ai.liljimjim.com
               hears the wake word,             face, captions, voice       Whisper (speech to text)
               streams your voice                                           Claude, memory, Aura voice
```

The Voice PE listens for "Hey Mibo" on its own. When it hears it, it sends your
voice straight to the My Mibo app on the Apple TV (no Home Assistant in between).
The Apple TV sends it to the server to be turned into words, asks Claude, and
speaks the answer through the TV. The Voice PE's light ring follows along
(listening, thinking, talking), and after Mibo answers it listens again for a
follow-up. Saying "Hey Mibo" or "stop" while Mibo is talking interrupts.

## Files

| File | What it is |
|---|---|
| `train_hey_mibo.ipynb` | Google Colab notebook that trains the "Hey Mibo" wake word (made by `make_notebook.py`) |
| `hey_mibo/` | The trained wake word, once it's made (`hey_mibo.json` + `hey_mibo.tflite`) |
| `mibo-voice.yaml` | The Voice PE firmware (the official firmware with a few changes, each marked `MIBO:`) |
| `mibo-voice-device.yaml` | The small file you paste into the ESPHome Device Builder; it pulls `mibo-voice.yaml` from GitHub and adds your Wi-Fi |
| `ha-open-mibo.yaml` | The Home Assistant automation that opens My Mibo when you say "Hey Mibo" and it isn't open |
| `../app/MyMiboTV.xcodeproj` | The Apple TV app |

## Setup, in order

### 1. Train "Hey Mibo"
Open the notebook in Colab:
https://colab.research.google.com/github/scoop076/ai/blob/main/voice-pe/train_hey_mibo.ipynb

Follow the steps at the top (T4 GPU, Run all, then Run all again). It takes
1½–2 hours and downloads `hey_mibo.zip`. Send that zip to Claude to add to
the repo as `voice-pe/hey_mibo/`.

### 2. A service token so the Apple TV can reach the server
The Apple TV can't sign in through a browser, so it uses a Cloudflare Access service token.
1. Cloudflare dashboard → **Zero Trust** → **Access controls** (or **Access**) → **Service credentials** → **Service Tokens** → **Create Service Token**.
   Name it `Mibo Apple TV`, duration **Non-expiring**. Copy the **Client ID** and **Client Secret** (the secret is shown only once).
2. **Access** → **Applications** → the ai.liljimjim.com application → **Policies** → **Add a policy**:
   Action **Service Auth**, Include **Service Token** = `Mibo Apple TV`. Save.

### 3. Flash the Voice PE
In Home Assistant, open the **ESPHome Device Builder** add-on (install it from the Add-on Store if it isn't there).
1. **+ New Device** → Continue → name it `mibo-voice` → ESP32-S3 → Skip.
2. **Edit** the new `mibo-voice.yaml` and replace everything with the contents of `mibo-voice-device.yaml`.
3. The first install has to find the Voice PE at its old name. Under `wifi:`, add one line with the Voice PE's
   current address (Home Assistant → Settings → Devices → ESPHome shows it, like `home-assistant-voice-0a1b2c`):
   ```yaml
     use_address: home-assistant-voice-0a1b2c.local
   ```
4. **Save** → **Install** → **Wirelessly**. The first build takes a while.
5. When it's done, remove the `use_address` line and save (from now on it's `mibo-voice.local`).
6. In Home Assistant → Settings → Devices → ESPHome: delete the old "Home Assistant Voice" device, and
   **ignore** the newly discovered "Mibo Voice". If Home Assistant connects to it, it takes over the
   microphone and the Apple TV can't use it.

To go back to the original firmware anytime: esphome.github.io/home-assistant-voice-pe.

### 4. Build the Apple TV app
1. On the Studio Mac, open `app/MyMiboTV.xcodeproj` in Xcode.
2. Pair the Studio Apple TV: on the Apple TV, Settings → Remotes and Devices → Remote App and Devices;
   in Xcode, Window → Devices and Simulators, pick the Apple TV and enter the code.
3. Pick your team under Signing & Capabilities (the same Personal Team as the iPad app), choose the Apple TV, and Run.
4. Allow **local network** access when the Apple TV asks.
5. Settings opens by itself the first time: paste the Client ID and Client Secret (when the keyboard appears,
   your iPhone offers to type for you). Leave the speaker address as `mibo-voice.local`.

Press and hold the remote's click button for Settings. Click once to talk (it opens the Voice PE's
microphone) or to stop Mibo talking. Play/Pause also stops Mibo.

### 5. "Hey Mibo" opens My Mibo (Home Assistant)
When My Mibo isn't open, the speaker can't send your voice anywhere, so it asks Home Assistant to open
the app instead: it calls a webhook (`http://homeassistant.local/api/webhook/mibo-open-studio`), and an
automation wakes the Apple TV and opens My Mibo. When the app connects, the speaker chimes and listens,
so you say "Hey Mibo", wait for the second chime, then ask. The ring spins while the app opens; it
flashes red if Home Assistant didn't answer.
1. Add the **Studio** Apple TV to Home Assistant: Settings → Devices & services → Add Integration →
   **Apple TV**, pick the Studio one, and type the codes the TV shows. (Only the Apple TV integration;
   keep ignoring "Mibo Voice".)
2. Add the automation in `ha-open-mibo.yaml` (instructions at its top) and fix the two entity names.
3. Test it from the Mac's Terminal with My Mibo closed:
   `curl -X POST http://homeassistant.local/api/webhook/mibo-open-studio`
4. If the speaker can't find `homeassistant.local`, put Home Assistant's IP address in
   `mibo-voice-device.yaml`:
   ```yaml
   substitutions:
     mibo_ha_url: http://192.168.86.XX   # your Home Assistant address
   ```
The automation opens the app by its bundle ID (`com.liljimjim.mibotv`). If that ever fails, the app
also answers the link `mibo://`: use `media_content_type: url`, `media_content_id: "mibo://open"`.

My Mibo lets go of the speaker when you leave it (Home button or another app), so the next "Hey Mibo"
opens it again. Free signing expires after 7 days; an expired app can't be opened this way either.

### Talking over Mibo
In a conversation the speaker's mic stays open while Mibo talks. Talk firmly over Mibo and it stops mid-word;
what you say becomes your next turn ("stop", "quiet", "shut up", "that's enough" put Mibo in quiet mode; anything
else gets answered; if it wasn't meant for Mibo, Mibo stays stopped). You have to be clearly louder than Mibo's
own voice at the speaker (2.2 times, and at least 6,000), so room noise doesn't count. Mibo learns how loud its
voice is at the speaker as it talks. Outside a conversation only "Hey Mibo" does anything.
The Xcode console prints "over Mibo: level …, Mibo's voice …, needed …" once a second while Mibo talks, and
"you talked over Mibo" when it stops, for tuning.

## Good to know
- **Voice:** the built-in Kokoro voice engine (Google MediaPipe) only runs on iPhone and iPad, so the Apple TV
  speaks with the free Cloudflare Aura voices (each personality has one). If the daily free allowance runs out,
  it falls back to the Apple TV's own voice.
- **Cost:** speech to text is Whisper on Cloudflare Workers AI, about a twentieth of a cent per minute of talking.
- **Free signing** expires after 7 days, like the iPad app; rebuild from Xcode to renew.
- **Wake word licence:** the noise recordings used in training are for non-commercial use, so this "Hey Mibo"
  model is for home use only.
- **Tuning:** if Mibo cuts you off or waits too long after you stop, the Xcode console prints lines like
  `heard nothing (loudest 180, background 40)`. Send those to Claude to adjust the listening levels.
