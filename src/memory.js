// The frame's memory: one SQLite-backed Durable Object that keeps every
// exchange (with date and screen) plus Claude's long-term notes.
import { DurableObject } from "cloudflare:workers";
import { runChange, mergeChange, closeChange, revertChange } from "./changes.js";

export class Memory extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS turns (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, device TEXT NOT NULL DEFAULT '')",
    );
    this.sql.exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS changes (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, updated INTEGER NOT NULL, " +
      "description TEXT NOT NULL, device TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '', " +
      "spoken TEXT NOT NULL DEFAULT '', pr INTEGER, branch TEXT NOT NULL DEFAULT '', merge_sha TEXT NOT NULL DEFAULT '', " +
      "files TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '')",
    );
  }

  getValue(k) {
    const rows = this.sql.exec("SELECT v FROM kv WHERE k = ?", k).toArray();
    return rows.length ? rows[0].v : null;
  }
  setValue(k, v) {
    this.sql.exec(
      "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
      k,
      String(v),
    );
  }

  addTurn(role, content, device) {
    this.sql.exec(
      "INSERT INTO turns (ts, role, content, device) VALUES (?, ?, ?, ?)",
      Date.now(),
      role,
      String(content).slice(0, 20000),
      String(device || "").slice(0, 60),
    );
  }

  // Recent turns since the last "start a new conversation", oldest first.
  recent(limit = 30) {
    const from = Number(this.getValue("context_from") || 0);
    const rows = this.sql
      .exec("SELECT ts, role, content, device FROM turns WHERE ts >= ? ORDER BY id DESC LIMIT ?", from, limit)
      .toArray();
    return rows.reverse();
  }

  newConversation() {
    this.setValue("context_from", Date.now());
  }

  getNotes() {
    return this.getValue("notes") || "";
  }
  setNotes(notes) {
    this.setValue("notes", String(notes).slice(0, 8000));
    this.setValue("notes_updated", Date.now());
  }

  // Settings shared by every screen (the voice and how it sounds).
  getPrefs() {
    try { return JSON.parse(this.getValue("prefs") || "{}"); } catch { return {}; }
  }
  setPrefs(patch) {
    const prefs = { ...this.getPrefs(), ...patch };
    this.setValue("prefs", JSON.stringify(prefs));
    return prefs;
  }

  summary() {
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM turns").one().n;
    const first = this.sql.exec("SELECT MIN(ts) AS t FROM turns").one().t;
    return { messages: n, since: first || null, notes: this.getNotes() };
  }

  /* ---------- changes the frame makes to itself ---------- */
  async queueChange(description, device) {
    const now = Date.now();
    this.sql.exec(
      "INSERT INTO changes (ts, updated, description, device, status) VALUES (?, ?, ?, ?, 'queued')",
      now, now, String(description).slice(0, 2000), String(device || "").slice(0, 60),
    );
    const id = this.sql.exec("SELECT last_insert_rowid() AS id").one().id;
    await this.ctx.storage.setAlarm(Date.now() + 200);
    return id;
  }
  listChanges(limit = 6) {
    return this.sql
      .exec("SELECT id, ts, updated, description, status, summary, spoken, pr, files, error FROM changes ORDER BY id DESC LIMIT ?", limit)
      .toArray();
  }
  getChange(id) {
    const rows = this.sql.exec("SELECT * FROM changes WHERE id = ?", id).toArray();
    return rows[0] || null;
  }
  latestWith(status) {
    const rows = this.sql.exec("SELECT * FROM changes WHERE status = ? ORDER BY id DESC LIMIT 1", status).toArray();
    return rows[0] || null;
  }
  updateChange(id, fields) {
    const cols = Object.keys(fields);
    if (!cols.length) return;
    const sets = cols.map((c) => c + " = ?").join(", ");
    this.sql.exec("UPDATE changes SET " + sets + ", updated = ? WHERE id = ?", ...cols.map((c) => fields[c]), Date.now(), id);
  }

  // Runs queued changes in the background, one at a time.
  async alarm() {
    const rows = this.sql.exec("SELECT * FROM changes WHERE status = 'queued' ORDER BY id LIMIT 1").toArray();
    const job = rows[0];
    if (!job) return;
    this.updateChange(job.id, { status: "working" });
    try {
      await runChange(this.env, job, async (fields) => this.updateChange(job.id, fields));
    } catch (e) {
      this.updateChange(job.id, { status: "failed", error: String((e && e.message) || e).slice(0, 300) });
    }
    const more = this.sql.exec("SELECT COUNT(*) AS n FROM changes WHERE status = 'queued'").one().n;
    if (more) await this.ctx.storage.setAlarm(Date.now() + 200);
  }

  async approveChange(id) {
    const job = id ? this.getChange(id) : this.latestWith("ready");
    if (!job || job.status !== "ready") {
      const working = this.latestWith("working") || this.latestWith("queued");
      return { ok: false, message: working ? "That change is still being worked on. I'll tell you when it's ready." : "There's no change waiting for your approval." };
    }
    try {
      const sha = await mergeChange(this.env, job);
      this.updateChange(job.id, { status: "merged", merge_sha: sha });
      return { ok: true, message: "Published. The frame will refresh itself in about a minute with the change." };
    } catch (e) {
      return { ok: false, message: "I couldn't publish it. " + String((e && e.message) || e).slice(0, 160) };
    }
  }

  async discardChange(id) {
    const job = id ? this.getChange(id) : (this.latestWith("ready") || this.latestWith("queued"));
    if (!job || !["ready", "queued", "failed"].includes(job.status)) return { ok: false, message: "There's no pending change to discard." };
    try { await closeChange(this.env, job); } catch {}
    this.updateChange(job.id, { status: "discarded" });
    return { ok: true, message: "Okay, I've thrown that change away. Nothing on the frame changed." };
  }

  async undoLastChange() {
    const job = this.latestWith("merged");
    if (!job) return { ok: false, message: "There's no published change to undo." };
    try {
      await revertChange(this.env, job);
      this.updateChange(job.id, { status: "undone" });
      return { ok: true, message: "Undone. The frame will go back to how it was in about a minute." };
    } catch (e) {
      return { ok: false, message: "I couldn't undo it. " + String((e && e.message) || e).slice(0, 160) };
    }
  }

  forgetEverything() {
    this.sql.exec("DELETE FROM turns");
    this.sql.exec("DELETE FROM kv WHERE k != 'prefs'");   // keep the chosen voice
  }
}
