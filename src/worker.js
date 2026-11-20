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
import { PERSONAS, PERSONA_IDS, PERSONA_TOOL, personaSystem, personaList } from "./personas.js";

const CLAUDE_MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5"];
const NOTES_MODEL = "claude-haiku-5-5";
const ELEVEN_MODELS = ["eleven_flash_v2_5", "eleven_multilingual_v2"];
const AURA_MODEL = "@cf/deepgram/aura-2-en";
const AURA_VOICES = ["amalthea", "andromeda", "apollo", "arcas", "aries", "asteria", "athena", "atlas", "aurora", "callista", "cora", "cordelia", "delia", "draco", "electra", "harmonia", "helena", "hera", "hermes", "hyperion", "iris", "janus", "juno", "jupiter", "luna", "mars", "minerva", "neptune", "odysseus", "ophelia", "orion", "orpheus", "pandora", "phoebe", "pluto", "saturn", "thalia", "theia", "vesta", "zeus"];
const ENGINES = ["eleven", "aura", "device"];

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

// Claude's built-in web search, run on Anthropic's side (about 1 cent per search).
const WEB_SEARCH = {
  type: "web_search_20250305",
  name: "web_search",
  max_uses: 4,
  user_location: { type: "approximate", city: "Collinsville", region: "Illinois", country: "US", timezone: "America/Chicago" },
};

// The permanent "About Jim" list: Mibo adds and removes facts itself.
const MEMORY_TOOLS = [
  {
    name: "remember_about_jim",
    description: "Save a lasting fact to your permanent 'About Jim' list, which you always see and never lose. Use it whenever Jim tells you " +
      "something about himself or his life that will still matter later (where he lives, family and pets, his home and rooms, work, health " +
      "routines he shares, tastes, plans, people he mentions), and always when he says 'remember'. One short, self-contained fact per call " +
      "(call it several times for several facts). If a fact replaces an old one, call forget_about_jim for the old one first. " +
      "Don't save what's already on the list, small talk, or your own suggestions.",
    input_schema: {
      type: "object",
      properties: { fact: { type: "string", description: "The fact, written as a complete sentence about Jim, for example 'Jim's wife is a teacher in Illinois.'" } },
      required: ["fact"],
    },
  },
  {
    name: "forget_about_jim",
    description: "Remove facts from the 'About Jim' list when Jim asks you to forget something, or when a fact is out of date. " +
      "Every fact containing all of the given words is removed.",
    input_schema: {
      type: "object",
      properties: { about: { type: "string", description: "A few distinctive words from the fact(s) to remove, for example 'old address Edwardsville'." } },
      required: ["about"],
    },
  },
];

// Tools that let Claude change the frame itself when Jim asks out loud.
const FRAME_TOOLS = [
  {
    name: "request_frame_change",
    description: "Start changing Mibo's own page or code because Jim asked for a change to how the frame looks, sounds or behaves. Say one short sentence before calling it.",
    input_schema: {
      type: "object",
      properties: { description: { type: "string", description: "A clear, complete description of the change for an engineer, including every detail Jim mentioned." } },
      required: ["description"],
    },
  },
  {
    name: "approve_frame_change",
    description: "Publish a change that is ready. Only call this when Jim clearly approves, for example 'approve it', 'publish it' or 'yes, go ahead'.",
    input_schema: { type: "object", properties: { change_id: { type: "integer" } } },
  },
  {
    name: "discard_frame_change",
    description: "Throw away a pending change when Jim says no, cancel or discard.",
    input_schema: { type: "object", properties: { change_id: { type: "integer" } } },
  },
  {
    name: "undo_last_frame_change",
    description: "Undo the most recently published change when Jim asks to undo it or go back.",
    input_schema: { type: "object", properties: {} },
  },
];
const CHANGE_WORDS = {
  queued: "waiting to start", working: "being worked on now", ready: "ready for Jim's approval",
  failed: "failed", merged: "published", discarded: "discarded", undone: "undone",
};
function changeState(c) {
  const mins = Math.max(0, Math.round((Date.now() - c.updated) / 60000));
  if (c.status === "merged") return c.live
    ? "published and confirmed live on screen"
    : "approved " + (mins ? mins + " min ago" : "just now") + " and still deploying; deploys usually take one to two minutes, so it is on its way, not failed";
  if (c.status === "undone") return c.live ? "undone, and the undo is confirmed live" : "undo approved " + (mins ? mins + " min ago" : "just now") + " and still deploying";
  return CHANGE_WORDS[c.status];
}
function describeChanges(list) {
  if (!list.length) return "No changes have been requested yet.";
  return list.map((c) =>
    "#" + c.id + " (" + changeState(c) + ", " + when(c.updated) + "): " + c.description.slice(0, 200) +
    (c.summary ? " | Result: " + c.summary : "") + (c.status === "failed" && c.error ? " | Problem: " + c.error : ""),
  ).join("\n");
}
async function runFrameTool(mem, name, input, device, version) {
  if (name === "request_frame_change") {
    const desc = String((input && input.description) || "").trim();
    if (!desc) return { ok: false, message: "I didn't catch what you'd like changed. Could you say it again?" };
    await mem.queueChange(desc, device);
    return { ok: true, message: "Got it. I'm working on that change now. It usually takes a minute or two, and I'll let you know when it's ready for your approval." };
  }
  const id = input && Number.isInteger(input.change_id) ? input.change_id : undefined;
  if (name === "approve_frame_change") return await mem.approveChange(id, version);
  if (name === "discard_frame_change") return await mem.discardChange(id);
  if (name === "undo_last_frame_change") return await mem.undoLastChange(version);
  return { ok: false, message: "" };
}
function sseText(text) {
  return "event: content_block_delta\ndata: " +
    JSON.stringify({ type: "content_block_delta", index: 99, delta: { type: "text_delta", text } }) + "\n\n";
}

function versionId(env) {
  return (env.CF_VERSION_METADATA && env.CF_VERSION_METADATA.id) || null;
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
    "Jim: " + text + "\nMibo: " + reply + "\n\n" +
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
      system: "You keep the long-term memory notes for Mibo, the voice of a digital frame in Jim's home (built on Claude).",
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
      return json({ claude: !!env.ANTHROPIC_API_KEY, eleven: !!env.ELEVENLABS_API_KEY, memory: !!env.MEMORY, changes: !!env.FRAME_GITHUB_TOKEN, search: true, aura: !!env.AI });
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
      const canChange = !!env.FRAME_GITHUB_TOKEN;
      if (canChange) await mem.checkLive(versionId(env));
      const [recent, notes, changeList, prefs, facts] = await Promise.all([mem.recent(30), mem.getNotes(), canChange ? mem.listChanges(5) : [], mem.getPrefs(), mem.listFacts()]);
      const persona = PERSONAS[prefs.persona] ? prefs.persona : "claude";
      const system =
        (typeof body.system === "string" ? body.system.slice(0, 6000) : "") +
        "\n\nAbout Jim (your permanent list; these are true unless he corrects them):\n" +
        (facts.length ? facts.map((f) => "- " + f.text).join("\n") : "(Nothing yet.)") +
        "\nUse these naturally. For weather, the time, nearby places and other local questions, assume Jim means his home unless he says " +
        "otherwise, and never ask where he lives. When he tells you something new about himself that will still matter later, save it " +
        "with remember_about_jim (briefly confirm, like 'Got it.'); when he asks you to forget something, use forget_about_jim." +
        "\n\nYour long-term memory of Jim and your past conversations (your own notes):\n" +
        (notes || "(Nothing yet. This may be one of your first conversations.)") +
        "\n\nThe conversation below may span several of Jim's screens and earlier sessions. Jim's messages start with the time and screen in brackets; " +
        "never repeat those brackets yourself. Use what you remember naturally, the way a friend would, without reciting your notes." +
        "\n\nApologize only when a real mistake of yours truly calls for it, and then do it once, in a few words, and move straight on. Don't keep saying sorry, and don't apologize for small things or for things that aren't your fault. " +
        "Once you have corrected something, treat it as settled: don't restate the correction, re-correct the same fact, or remind Jim of past mistakes unless he asks about it or the error affects what he's doing right now. Keep replies direct." +
        "\n\nNever put Jim's name at the end of a sentence, for example never say 'Good morning, Jim.' or 'That sounds great, Jim.' He has asked you many times to stop. Use his name only at the start of a sentence, as in 'Jim, here's what I found.', or leave it out entirely, which is usually best. This applies in every personality." +
        "\n\nYou can search the web. Use it whenever Jim asks about current events, facts you're unsure of, prices, places, or anything for his research. " +
        "Before searching, say one short sentence like 'Let me look that up.' Then answer conversationally in a few sentences, mentioning sources by name " +
        "(for example 'according to the Mayo Clinic') but never reading out web addresses. For research, give the key findings and offer to dig deeper." +
        (canChange
          ? "\n\nYou can change yourself. When Jim asks you to change how the frame looks, sounds or behaves (your face, voice handling, settings, features), " +
            "call request_frame_change with a clear description; it is saved for his approval, never published right away. " +
            "When a change is ready, summarize it and ask whether to publish. Use approve_frame_change only when Jim clearly says yes, " +
            "discard_frame_change when he says no, and undo_last_frame_change when he asks to undo. Keep what you say about this short. " +
            "If earlier changes failed, those were technical problems that may already be fixed: whenever Jim asks for a change, always submit a new request instead of declining or second-guessing.\n" +
            "This list is the truth about your changes; you can't see your own face, so rely on it. A change confirmed live is on screen now: say so confidently. " +
            "A change that is still deploying is on its way: tell Jim it's still deploying and that you'll announce it when it's live; don't apologize or call it failed. " +
            "Only say a change failed if its status says failed. Never promise a refresh yourself; the frame refreshes on its own.\n" +
            "Messages marked '(Update about myself)' are records of these changes; never read that label aloud.\n" +
            "Recent changes to yourself:\n" + describeChanges(changeList)
          : "") +
        "\n\nYou can switch personalities with set_personality when Jim asks you to become one of your characters, asks who else you can be, or wants regular Mibo back." +
        personaSystem(persona);
      const upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: CLAUDE_MODELS.includes(body.model) ? body.model : CLAUDE_MODELS[0],
          max_tokens: 900,
          system,
          messages: buildMessages(recent, text, device),
          tools: [WEB_SEARCH, PERSONA_TOOL, ...MEMORY_TOOLS, ...(canChange ? FRAME_TOOLS : [])],
          stream: true,
        }),
      });
      if (!upstream.ok || !upstream.body) {
        let detail = "";
        try { const j = await upstream.json(); detail = (j.error && j.error.message) || ""; } catch {}
        return json({ error: detail || "Claude returned status " + upstream.status }, upstream.status);
      }
      await mem.addTurn("user", text, device);

      const { readable, writable } = new TransformStream();
      const writer = writable.getWriter();
      ctx.waitUntil((async () => {
        const reader = upstream.body.getReader();
        const dec = new TextDecoder();
        let buf = "", full = "", heard = true;
        const toolBlocks = {}, toolCalls = [];
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
              else if (d.type === "content_block_start" && d.content_block && d.content_block.type === "tool_use") toolBlocks[d.index] = { name: d.content_block.name, json: "" };
              else if (d.type === "content_block_delta" && d.delta && d.delta.type === "input_json_delta" && toolBlocks[d.index]) toolBlocks[d.index].json += d.delta.partial_json || "";
              else if (d.type === "content_block_stop" && toolBlocks[d.index]) { toolCalls.push(toolBlocks[d.index]); delete toolBlocks[d.index]; }
            } catch {}
          }
        }
        // Carry out any change requests, and say the result if Claude didn't.
        for (const call of toolCalls) {
          let input = {};
          try { input = call.json ? JSON.parse(call.json) : {}; } catch {}
          if (call.name === "remember_about_jim" || call.name === "forget_about_jim") {
            let say = "";
            if (call.name === "remember_about_jim") {
              const added = await mem.addFact(input.fact);
              if (!full.trim()) say = added ? "Got it, I'll remember that." : "I already have that.";
            } else {
              const gone = await mem.removeFacts(input.about);
              if (!full.trim() || !gone.length) say = gone.length ? "Done, I've forgotten that." : "I didn't have anything saved about that.";
            }
            if (say) {
              say = (full.trim() ? " " : "") + say;
              full += say;
              if (heard) { try { await writer.write(new TextEncoder().encode(sseText(say))); } catch { heard = false; } }
            }
            continue;
          }
          if (call.name === "set_personality") {
            // Switch first, tell the page (so the new voice and look are ready), then greet in character.
            const id = PERSONAS[input.personality] ? input.personality : "claude";
            await mem.setPrefs({ persona: id });
            const say = (full.trim() ? " " : "") + (id === "claude" ? "Back to my regular self. What's on your mind?" : PERSONAS[id].greeting);
            full += say;
            if (heard) {
              try {
                await writer.write(new TextEncoder().encode("event: frame\ndata: " + JSON.stringify({ type: "frame_persona", persona: id }) + "\n\n"));
                await writer.write(new TextEncoder().encode(sseText(say)));
              } catch { heard = false; }
            }
            continue;
          }
          let result;
          try { result = await runFrameTool(mem, call.name, input, device, versionId(env)); }
          catch (e) { result = { ok: false, message: "Something went wrong with that change: " + String((e && e.message) || e).slice(0, 120) }; }
          if (result.message && (!full.trim() || !result.ok)) {
            const say = (full.trim() ? " " : "") + result.message;
            full += say;
            if (heard) { try { await writer.write(new TextEncoder().encode(sseText(say))); } catch { heard = false; } }
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

    // Changes the frame makes to itself (also approved from the settings panel).
    if (url.pathname === "/api/changes" && request.method === "GET") {
      const mem = memoryStub(env);
      await mem.checkLive(versionId(env));
      return json({ enabled: !!env.FRAME_GITHUB_TOKEN, changes: await mem.listChanges(6) });
    }
    if (url.pathname === "/api/version") {
      return json({ id: versionId(env) });
    }
    if (url.pathname === "/api/changes/live" && request.method === "POST") {
      let body = {};
      try { body = await request.json(); } catch {}
      if (Number.isInteger(body.id)) await memoryStub(env).markLive(body.id);
      return json({ ok: true });
    }
    if (url.pathname === "/api/changes/retry" && request.method === "POST") {
      let body = {};
      try { body = await request.json(); } catch {}
      const mem = memoryStub(env);
      const job = Number.isInteger(body.id) ? await mem.getChange(body.id) : null;
      if (!job) return json({ ok: false, message: "I couldn't find that change." }, 404);
      await mem.queueChange(job.description, job.device);
      return json({ ok: true, message: "Trying that change again. I'll let you know when it's ready." });
    }
    if ((url.pathname === "/api/changes/approve" || url.pathname === "/api/changes/discard") && request.method === "POST") {
      let body = {};
      try { body = await request.json(); } catch {}
      const id = Number.isInteger(body.id) ? body.id : undefined;
      const mem = memoryStub(env);
      return json(url.pathname.endsWith("approve") ? await mem.approveChange(id, versionId(env)) : await mem.discardChange(id));
    }

    // The characters the frame can play (looks and voices; no prompts).
    if (url.pathname === "/api/personas") {
      return json(personaList());
    }

    // Shared settings: the same voice on every screen.
    if (url.pathname === "/api/prefs" && request.method === "GET") {
      return json(await memoryStub(env).getPrefs());
    }
    if (url.pathname === "/api/prefs" && request.method === "POST") {
      let body;
      try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
      const patch = {};
      if (typeof body.elVoice === "string" && /^[A-Za-z0-9]{10,40}$/.test(body.elVoice)) patch.elVoice = body.elVoice;
      if (ELEVEN_MODELS.includes(body.elModel)) patch.elModel = body.elModel;
      if (ENGINES.includes(body.engine)) patch.engine = body.engine;
      if (AURA_VOICES.includes(body.auraVoice)) patch.auraVoice = body.auraVoice;
      if (body.persona === "claude" || PERSONA_IDS.includes(body.persona)) patch.persona = body.persona;
      const rate = Number(body.rate);
      if (rate >= 0.5 && rate <= 2) patch.rate = rate;
      return json(await memoryStub(env).setPrefs(patch));
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

    // Free voice: Deepgram Aura on Cloudflare Workers AI (free daily allowance)
    if (url.pathname === "/api/tts-free" && request.method === "POST") {
      if (!env.AI) return json({ error: "Workers AI isn't connected." }, 503);
      let body;
      try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
      const text = String(body.text || "").slice(0, 1200);
      const speaker = AURA_VOICES.includes(body.speaker) ? body.speaker : "luna";
      if (!text) return json({ error: "Missing text." }, 400);
      let out;
      try { out = await env.AI.run(AURA_MODEL, { text, speaker, encoding: "mp3" }); }
      catch (e) {
        const msg = String((e && e.message) || e);
        return json({ error: msg.slice(0, 200) }, /limit|neuron|quota|exceed|capacity/i.test(msg) ? 429 : 502);
      }
      let audio = out;
      if (out && !(out instanceof ReadableStream) && out.audio) {           // some models return base64
        const bin = atob(out.audio); const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        audio = bytes;
      }
      return new Response(audio, { headers: { "content-type": "audio/mpeg", "cache-control": "no-store" } });
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
