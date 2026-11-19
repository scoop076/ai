// Claude Wall Portrait: serves the frame and relays requests to Claude and
// ElevenLabs so the API keys stay on Cloudflare (as encrypted secrets) and
// never reach the browser.
//
// Secrets (set in the Cloudflare dashboard: Worker > Settings > Variables and Secrets):
//   ANTHROPIC_API_KEY   - Claude API key
//   ELEVENLABS_API_KEY  - ElevenLabs API key
//
// The site sits behind Cloudflare Access, which adds a signed
// Cf-Access-Jwt-Assertion header to every request it lets through. Requests
// without it (for example if Access were ever switched off) are refused.

const CLAUDE_MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5"];
const ELEVEN_MODELS = ["eleven_flash_v2_5", "eleven_multilingual_v2"];

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(request);

    if (!request.headers.get("Cf-Access-Jwt-Assertion")) {
      return json({ error: "Sign in required." }, 401);
    }

    // Which keys does the server hold?
    if (url.pathname === "/api/config") {
      return json({ claude: !!env.ANTHROPIC_API_KEY, eleven: !!env.ELEVENLABS_API_KEY });
    }

    // Claude: streamed reply
    if (url.pathname === "/api/claude" && request.method === "POST") {
      if (!env.ANTHROPIC_API_KEY) return json({ error: "No Claude key is set on the server." }, 503);
      let body;
      try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
      const payload = {
        model: CLAUDE_MODELS.includes(body.model) ? body.model : CLAUDE_MODELS[0],
        max_tokens: Math.min(Number(body.max_tokens) || 500, 1000),
        system: typeof body.system === "string" ? body.system : undefined,
        messages: Array.isArray(body.messages) ? body.messages.slice(-24) : [],
        stream: true,
      };
      const upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify(payload),
      });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": upstream.headers.get("content-type") || "text/event-stream",
          "cache-control": "no-store",
        },
      });
    }

    // ElevenLabs: speech for one sentence
    if (url.pathname === "/api/tts" && request.method === "POST") {
      if (!env.ELEVENLABS_API_KEY) return json({ error: "No ElevenLabs key is set on the server." }, 503);
      let body;
      try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
      const text = String(body.text || "").slice(0, 1200);
      const voice = String(body.voice_id || "");
      if (!text || !/^[A-Za-z0-9]{10,40}$/.test(voice)) return json({ error: "Missing text or voice." }, 400);
      const upstream = await fetch(
        "https://api.elevenlabs.io/v1/text-to-speech/" + voice + "?output_format=mp3_44100_128",
        {
          method: "POST",
          headers: { "xi-api-key": env.ELEVENLABS_API_KEY, "content-type": "application/json", accept: "audio/mpeg" },
          body: JSON.stringify({
            text,
            model_id: ELEVEN_MODELS.includes(body.model_id) ? body.model_id : ELEVEN_MODELS[0],
            voice_settings: body.voice_settings || undefined,
          }),
        },
      );
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": upstream.headers.get("content-type") || "audio/mpeg",
          "cache-control": "no-store",
        },
      });
    }

    // ElevenLabs: the account's voices
    if (url.pathname === "/api/voices" && request.method === "GET") {
      if (!env.ELEVENLABS_API_KEY) return json({ error: "No ElevenLabs key is set on the server." }, 503);
      const upstream = await fetch("https://api.elevenlabs.io/v1/voices", {
        headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
      });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }

    return json({ error: "Not found." }, 404);
  },
};
