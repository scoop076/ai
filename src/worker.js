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

export { Memory } from "./memory.js";

const CLAUDE_MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5"];
const NOTES_MODEL = "claude-haiku-5-5";
const ELEVEN_MODELS = ["eleven_flash_v2_5", "eleven_multilingual_v2"];

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function memoryStub(env) {
  return env.MEMORY.get(env.MEMORY.idFromName("jim"));
}

function when(ts) {
  return new Date(ts).toLocaleString("en-US", {
    timeZone: "America/Chicago", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  });
}

// Turn saved history into alternating user/assistant messages for Claude.
function buildMessages(recent, text, device) {
  const msgs = [];
  for (const t of recent) {
    const content = t.role === "user" ? "[" + when(t.ts) + (t.device ? " · " + t.device : "") + "] " + t.content : t.content;
    const last = msgs[msgs.length - 1];
    if (last && last.role === t.role) last.content += "\n" + content;
    else msgs.push({ role: t.role, content });
  }
  const now = "[" + when(Date.now()) + (device ? " · " + device : "") + "] " + text;
  const last = msgs[msgs.length - 1];
  if (last && last.role === "user") last.content += "\n" + now;
  else msgs.push({ role: "user", content: now });
  while (msgs.length && msgs[0].role !== "user") msgs.shift();
  return msgs;
}

// After each exchange, have Claude fold anything worth keeping into its notes.
async function updateNotes(env, mem, text, reply, device) {
  const notes = await mem.getNotes();
  const prompt =
    "Current notes:\n<notes>\n" + (notes || "(empty)") + "\n</notes>\n\n" +
    "Newest exchange (" + when(Date.now()) + (device ? ", on " + device : "") + "):\n" +
    "Jim: " + text + "\nClaude: " + reply + "\n\n" +
    "Rewrite the notes so they include anything from this exchange worth remembering in future conversations: " +
    "facts about Jim, his family, home, rooms and screens, projects, plans, opinions and preferences, anything he asked you to remember, " +
    "and a short dated log of notable topics. If Jim asked you to forget something, remove it completely. " +
    "Keep the notes under 3,500 characters, in plain text grouped under short headings, merging or trimming older log entries as needed. " +
    "If nothing new is worth keeping, return the notes unchanged. Reply with only the notes.";
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model: NOTES_MODEL,
      max_tokens: 1500,
      system: "You keep the long-term memory notes for Claude, the voice of a digital portrait frame in Jim's home.",
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!r.ok) return;
  const data = await r.json();
  const out = (data.content || []).filter((b) => b.type === "text").map((b) => b.text).join("").trim();
  if (out && out.length < 8000) await mem.setNotes(out);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(request);

    if (!request.headers.get("Cf-Access-Jwt-Assertion")) {
      return json({ error: "Sign in required." }, 401);
    }

    // Which keys does the server hold?
    if (url.pathname === "/api/config") {
      return json({ claude: !!env.ANTHROPIC_API_KEY, eleven: !!env.ELEVENLABS_API_KEY, memory: !!env.MEMORY });
    }

    // Chat with memory: builds the conversation from saved history and notes,
    // streams Claude's reply to the frame, and saves the exchange.
    if (url.pathname === "/api/chat" && request.method === "POST") {
      if (!env.ANTHROPIC_API_KEY) return json({ error: "No Claude key is set on the server." }, 503);
      let body;
      try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
      const text = String(body.text || "").trim().slice(0, 4000);
      const device = String(body.device || "").slice(0, 60);
      if (!text) return json({ error: "Nothing to send." }, 400);
      const mem = memoryStub(env);
      const [recent, notes] = await Promise.all([mem.recent(30), mem.getNotes()]);
      const system =
        (typeof body.system === "string" ? body.system.slice(0, 6000) : "") +
        "\n\nYour long-term memory of Jim and your past conversations (your own notes):\n" +
        (notes || "(Nothing yet. This may be one of your first conversations.)") +
        "\n\nThe conversation below may span several of Jim's screens and earlier sessions. Jim's messages start with the time and screen in brackets; " +
        "never repeat those brackets yourself. Use what you remember naturally, the way a friend would, without reciting your notes.";
      const upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: CLAUDE_MODELS.includes(body.model) ? body.model : CLAUDE_MODELS[0],
          max_tokens: 600,
          system,
          messages: buildMessages(recent, text, device),
          stream: true,
        }),
      });
      if (!upstream.ok || !upstream.body) {
        return new Response(upstream.body, { status: upstream.status, headers: { "content-type": "application/json" } });
      }
      await mem.addTurn("user", text, device);

      const { readable, writable } = new TransformStream();
      const writer = writable.getWriter();
      ctx.waitUntil((async () => {
        const reader = upstream.body.getReader();
        const dec = new TextDecoder();
        let buf = "", full = "", heard = true;
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          if (heard) { try { await writer.write(value); } catch { heard = false; } }
          buf += dec.decode(value, { stream: true });
          let i;
          while ((i = buf.indexOf("\n\n")) >= 0) {
            const line = buf.slice(0, i).split("\n").find((l) => l.startsWith("data:"));
            buf = buf.slice(i + 2);
            if (!line) continue;
            try {
              const d = JSON.parse(line.slice(5));
              if (d.type === "content_block_delta" && d.delta && d.delta.type === "text_delta") full += d.delta.text;
            } catch {}
          }
        }
        try { await writer.close(); } catch {}
        if (full.trim()) {
          await mem.addTurn("assistant", heard ? full : full + " [Jim interrupted before hearing all of this]", device);
          try { await updateNotes(env, mem, text, full, device); } catch {}
        }
      })());
      return new Response(readable, {
        headers: { "content-type": "text/event-stream", "cache-control": "no-store" },
      });
    }

    // Memory: what the frame remembers, start fresh, or erase everything.
    if (url.pathname === "/api/memory" && request.method === "GET") {
      return json(await memoryStub(env).summary());
    }
    if (url.pathname === "/api/memory/new" && request.method === "POST") {
      await memoryStub(env).newConversation();
      return json({ ok: true });
    }
    if (url.pathname === "/api/memory/forget" && request.method === "POST") {
      await memoryStub(env).forgetEverything();
      return json({ ok: true });
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
