// Changes the frame makes to itself: Claude reads the frame's code from
// GitHub, writes exact edits, and saves them as a pull request. Nothing goes
// live until Jim approves; then the pull request is merged and Cloudflare
// deploys it. Undo restores the files from before the last published change.
//
// Needs the secret FRAME_GITHUB_TOKEN: a fine-grained GitHub token limited to
// scoop076/ai with Contents and Pull requests set to Read and write.

const API = "https://api.github.com/repos/scoop076/ai";
const EDITABLE = ["public/index.html", "src/worker.js", "src/memory.js", "src/changes.js", "src/personas.js"];
const CODE_MODEL = "claude-sonnet-5-5";

async function gh(env, path, opts = {}) {
  const headers = {
    authorization: "Bearer " + env.FRAME_GITHUB_TOKEN,
    accept: "application/vnd.github+json",
    "user-agent": "claude-frame",
    "x-github-api-version": "2022-11-28",
  };
  if (opts.body) headers["content-type"] = "application/json";
  const r = await fetch(API + path, { ...opts, headers });
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) {
    const e = new Error("GitHub said " + r.status + ": " + String((data && data.message) || text).slice(0, 200));
    e.status = r.status;
    throw e;
  }
  return data;
}

function b64encode(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
function b64decode(b64) {
  const bin = atob(String(b64).replace(/\s/g, ""));
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

async function getFile(env, path, ref) {
  const d = await gh(env, "/contents/" + path + "?ref=" + encodeURIComponent(ref));
  return { text: b64decode(d.content), sha: d.sha };
}

const EDIT_TOOL = {
  name: "submit_changes",
  description: "Submit the code edits that make Jim's requested change.",
  input_schema: {
    type: "object",
    properties: {
      summary: { type: "string", description: "One short line describing the change, used as the pull request title." },
      spoken: { type: "string", description: "One or two plain sentences, read aloud to Jim, saying what you changed. No code, no file names." },
      edits: {
        type: "array",
        items: {
          type: "object",
          properties: {
            path: { type: "string", enum: EDITABLE },
            old: { type: "string", description: "Exact current text to replace. It must appear exactly once in the file, so include enough surrounding lines." },
            new: { type: "string", description: "The replacement text." },
          },
          required: ["path", "old", "new"],
        },
      },
    },
    required: ["summary", "spoken", "edits"],
  },
};

const ENGINEER = [
  "You are the engineer for Claude Frame, a talking portrait web app that hangs on Jim's wall and runs in his browsers.",
  "It is a Cloudflare Worker. public/index.html is the entire front end (HTML, CSS and JavaScript in one file).",
  "src/worker.js relays requests to Claude and ElevenLabs behind Cloudflare Access and stores memory; src/memory.js is the Durable Object that keeps memory, shared settings and the change queue;",
  "src/changes.js is the code that makes these changes; src/personas.js defines the personalities (characters) the frame can switch into, with their voices and looks.",
  "Make the smallest correct change that does what Jim asked, keeping the existing style, structure and design tokens.",
  "Never put API keys, tokens or secrets in code. Do not break listening, speaking, memory, the settings panel, sign-in, or the change system itself.",
  "The page also runs inside Jim's native iPad and iPhone app, which handles the microphone and sound through the APP / NativeSR / toApp / window.__frameNative bridge in index.html. Keep that bridge and its APP branches working.",
  "Each edit is an exact search and replace: 'old' must match the current file text exactly, including spaces, and appear exactly once.",
].join(" ");

async function askForEdits(env, request, listing, previousError) {
  let content = "Call the submit_changes tool with your edits. Jim's request (spoken aloud, so it may be loosely worded):\n\"" + request + "\"\n\nCurrent files:\n\n" + listing;
  if (previousError) content += "\n\nYour previous edits could not be applied: " + previousError + "\nTry again with exact, unique 'old' text copied from the files above.";
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model: CODE_MODEL,
      max_tokens: 16000,
      system: ENGINEER,
      tools: [EDIT_TOOL],
      tool_choice: { type: "auto" },
      messages: [{ role: "user", content }],
    }),
  });
  if (!r.ok) {
    let detail = "";
    try { const j = await r.json(); detail = (j.error && j.error.message) || ""; } catch {}
    throw new Error("Claude couldn't work on it (status " + r.status + (detail ? ": " + detail.slice(0, 200) : "") + ").");
  }
  const data = await r.json();
  const call = (data.content || []).find((b) => b.type === "tool_use");
  if (!call) return { edits: [] };          // no edits this time; the caller retries once
  return call.input || {};
}

// Apply edits to copies of the files. Returns "" on success, or what went wrong.
function applyEdits(files, edits) {
  for (const f of Object.values(files)) f.next = undefined;
  if (!Array.isArray(edits) || !edits.length) return "no edits were given";
  for (const e of edits) {
    const f = files[e.path];
    if (!f) return "the file " + e.path + " can't be edited";
    const current = f.next !== undefined ? f.next : f.text;
    const old = String(e.old || "");
    if (!old) return "an edit for " + e.path + " had empty 'old' text";
    const count = current.split(old).length - 1;
    if (count !== 1) return "an edit for " + e.path + " matched " + count + " places: " + JSON.stringify(old.slice(0, 120));
    f.next = current.replace(old, () => String(e.new));
  }
  return "";
}

export async function runChange(env, job, update) {
  if (!env.FRAME_GITHUB_TOKEN) throw new Error("GitHub access isn't set up yet.");
  const main = await gh(env, "/git/ref/heads/main");
  const baseSha = main.object.sha;
  const files = {};
  for (const p of EDITABLE) {
    try { files[p] = await getFile(env, p, baseSha); }
    catch (e) { if (e.status !== 404) throw e; }
  }
  const listing = Object.entries(files).map(([p, f]) => '<file path="' + p + '">\n' + f.text + "\n</file>").join("\n\n");

  let result = null, problem = "";
  for (let attempt = 0; attempt < 2; attempt++) {
    result = await askForEdits(env, job.description, listing, problem);
    problem = applyEdits(files, result.edits);
    if (!problem) break;
  }
  if (problem) throw new Error(problem === "no edits were given" ? "Claude didn't come up with any edits for that." : "The edits didn't fit the code (" + problem + ").");
  const changed = Object.entries(files).filter(([, f]) => f.next !== undefined && f.next !== f.text);
  if (!changed.length) throw new Error("Nothing needed to change.");

  const summary = String(result.summary || job.description).slice(0, 100);
  const branch = "frame/change-" + job.id + "-" + Date.now().toString(36);
  await gh(env, "/git/refs", { method: "POST", body: JSON.stringify({ ref: "refs/heads/" + branch, sha: baseSha }) });
  for (const [path, f] of changed) {
    await gh(env, "/contents/" + path, {
      method: "PUT",
      body: JSON.stringify({ message: "Frame change #" + job.id + ": " + summary, content: b64encode(f.next), sha: f.sha, branch }),
    });
  }
  const pr = await gh(env, "/pulls", {
    method: "POST",
    body: JSON.stringify({
      title: "Frame change #" + job.id + ": " + summary,
      head: branch,
      base: "main",
      body: "Requested by Jim through Claude Frame:\n\n> " + job.description + "\n\n" + (result.spoken || "") +
        "\n\nFiles changed: " + changed.map(([p]) => p).join(", ") + "\n\nSay \"approve\" to the frame to publish this, or \"discard\" to drop it.",
    }),
  });
  await update({ status: "ready", summary, spoken: String(result.spoken || "").slice(0, 600), pr: pr.number, branch, files: changed.map(([p]) => p).join(",") });
}

export async function mergeChange(env, job) {
  const m = await gh(env, "/pulls/" + job.pr + "/merge", {
    method: "PUT",
    body: JSON.stringify({ merge_method: "squash", commit_title: "Frame change #" + job.id + ": " + job.summary }),
  });
  try { await gh(env, "/git/refs/heads/" + job.branch, { method: "DELETE" }); } catch {}
  return m.sha;
}

export async function closeChange(env, job) {
  if (job.pr) await gh(env, "/pulls/" + job.pr, { method: "PATCH", body: JSON.stringify({ state: "closed" }) });
  if (job.branch) { try { await gh(env, "/git/refs/heads/" + job.branch, { method: "DELETE" }); } catch {} }
}

// Put the files back the way they were before a published change.
export async function revertChange(env, job) {
  const commit = await gh(env, "/commits/" + job.merge_sha);
  const parent = commit.parents && commit.parents[0] && commit.parents[0].sha;
  if (!parent) throw new Error("Couldn't find the version before that change.");
  for (const path of String(job.files || "").split(",").filter(Boolean)) {
    let before = null;
    try { before = await getFile(env, path, parent); } catch (e) { if (e.status !== 404) throw e; }
    let now = null;
    try { now = await getFile(env, path, "main"); } catch (e) { if (e.status !== 404) throw e; }
    if (before && now && before.text === now.text) continue;
    if (before) {
      await gh(env, "/contents/" + path, {
        method: "PUT",
        body: JSON.stringify({ message: "Undo frame change #" + job.id + ": " + job.summary, content: b64encode(before.text), sha: now ? now.sha : undefined, branch: "main" }),
      });
    } else if (now) {
      await gh(env, "/contents/" + path, {
        method: "DELETE",
        body: JSON.stringify({ message: "Undo frame change #" + job.id + ": " + job.summary, sha: now.sha, branch: "main" }),
      });
    }
  }
}

export const __test = { applyEdits, b64encode, b64decode };
