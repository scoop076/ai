// The frame's memory: one SQLite-backed Durable Object that keeps every
// exchange (with date and screen) plus Claude's long-term notes.
import { DurableObject } from "cloudflare:workers";

export class Memory extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS turns (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, device TEXT NOT NULL DEFAULT '')",
    );
    this.sql.exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
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

  summary() {
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM turns").one().n;
    const first = this.sql.exec("SELECT MIN(ts) AS t FROM turns").one().t;
    return { messages: n, since: first || null, notes: this.getNotes() };
  }

  forgetEverything() {
    this.sql.exec("DELETE FROM turns");
    this.sql.exec("DELETE FROM kv");
  }
}
