// A thin TypeScript client for Tandem's local HTTP API.
//
//   const t = await Tandem.open("Video.tandem");
//   const p = await t.project();                       // the timeline, with helpers
//   const pushes = p.transitions((tr) => tr.type === "push" && !tr.soundClipID);
//   await t.edit("Swooshes on the pushes", pushes.map((tr) =>
//     cmd.updateTransition({ transitionID: tr.id, patch: { sound: { mediaID, gainDB: -23.3, offset: -0.39 } } })));
//
// Every operation is `POST /v1/<operation>` with the same JSON the MCP tools take.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import type { Command, CommandArgs, CommandName } from "./commands.gen";
import type {
  ApplyResult,
  CheckResult,
  HistoryEvent,
  MediaResult,
  PausesResult,
  Project,
  ProjectClip,
  ProjectTransition,
  SearchResult,
  StatusResult,
  HandbackNote,
  HandbackResult,
  Track,
  TranscriptResult,
  Word,
} from "./types";

export type * from "./types";
export type * from "./commands.gen";

/** Typed command builders: `cmd.blade({ at: 12.5 })` gives `{ blade: { at: 12.5 } }`. */
export const cmd = new Proxy({} as { [K in CommandName]: (args: CommandArgs[K]) => Command }, {
  get: (_, name: string) => (args: unknown) => ({ [name]: args }) as Command,
});

export class TandemError extends Error {
  constructor(
    public code: string,
    message: string,
    public details: Record<string, unknown> = {},
  ) {
    super(`${code}: ${message}`);
  }
}

type Lock = { port: number; token: string; pid: number; owner: string };

/** The project file for a path: a .tandem file, or the folder holding exactly one. */
export function findProject(path: string): string {
  const p = resolve(path);
  if (p.endsWith(".tandem")) return p;
  // The .tandem/ folder beside a project ends in .tandem too, so only count files.
  const found = readdirSync(p).filter((f) => f.endsWith(".tandem") && statSync(join(p, f)).isFile());
  if (found.length !== 1) throw new Error(`${p} has ${found.length} .tandem projects; pass the file itself.`);
  return join(p, found[0]);
}

export function lockPath(project: string): string {
  return join(dirname(project), ".tandem", `${basename(project, ".tandem")}.lock`);
}

function readLock(project: string): Lock | undefined {
  const path = lockPath(project);
  if (!existsSync(path)) return undefined;
  try {
    const lock = JSON.parse(readFileSync(path, "utf8")) as Lock;
    process.kill(lock.pid, 0); // throws if the owner is gone
    return lock.port && lock.token ? lock : undefined;
  } catch {
    return undefined;
  }
}

export type OpenOptions = {
  /** Credited in the app's undo menu and activity feed. Default $TANDEM_AUTHOR or "claude". */
  author?: string;
  /** Start `tandem serve` when nothing serves the project (default true). close() stops it. */
  serve?: boolean;
};

export type EditOptions = {
  /** "first" (default) dry-runs, then applies. "only" dry-runs and stops. false applies straight away. */
  dryRun?: "first" | "only" | false;
  /** Default: the revision of your last read. */
  expectedRevision?: number;
  idempotencyKey?: string;
};

export class Tandem {
  /** The revision of the last thing read or applied; edit() sends it as expectedRevision. */
  revision?: number;
  private served?: ReturnType<typeof Bun.spawn>;

  private constructor(
    public readonly projectPath: string,
    private lock: Lock,
    public readonly author: string,
  ) {}

  static async open(path: string, options: OpenOptions = {}): Promise<Tandem> {
    const project = findProject(path);
    const author = options.author ?? process.env.TANDEM_AUTHOR ?? "claude";
    let lock = readLock(project);
    let served: ReturnType<typeof Bun.spawn> | undefined;
    if (!lock) {
      if (options.serve === false) throw new Error(`Nothing is serving ${project}. Run \`tandem serve\` or open it in the app.`);
      served = Bun.spawn(["tandem", "serve", "--project", project], {
        stdout: "ignore",
        stderr: "pipe",
        env: { ...process.env, TANDEM_AUTHOR: author },
      });
      const deadline = Date.now() + 30_000;
      while (!(lock = readLock(project)) || lock.pid !== served.pid) {
        if (served.exitCode !== null) throw new Error(`tandem serve exited: ${await new Response(served.stderr as ReadableStream).text()}`);
        if (Date.now() > deadline) throw new Error("tandem serve didn't start within 30 s");
        await Bun.sleep(100);
      }
    }
    const t = new Tandem(project, lock, author);
    t.served = served;
    return t;
  }

  /** Stops the `tandem serve` that open() started, if it did (it saves on the way out). */
  async close(): Promise<void> {
    if (!this.served) return;
    try {
      await this.call("release");
    } catch {}
    await this.served.exited;
    this.served = undefined;
  }

  /** Any operation: POST /v1/<op> with the MCP tool's JSON. Throws TandemError on {"error"}. */
  async call<T = any>(op: string, body: Record<string, unknown> = {}): Promise<T> {
    const res = await fetch(`http://127.0.0.1:${this.lock.port}/v1/${op}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.lock.token}`,
        "X-Tandem-Author": this.author,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    const text = await res.text();
    let json: any;
    try {
      json = JSON.parse(text);
    } catch {
      throw new TandemError(`http${res.status}`, text.slice(0, 500));
    }
    if (json?.error) throw new TandemError(json.error.code, json.error.message, json.error);
    if (typeof json?.revision === "number" && !json.dryRun) this.revision = json.revision;
    return json as T;
  }

  async schema(): Promise<any> {
    const res = await fetch(`http://127.0.0.1:${this.lock.port}/v1/schema`, {
      headers: { Authorization: `Bearer ${this.lock.token}` },
    });
    return res.json();
  }

  // Reads

  status = () => this.call<StatusResult>("status");
  media = (refresh = false) => this.call<MediaResult>("media", { refresh });
  /** Words in timeline time; pass a clip ID for one clip, a media ID for the file in file time. */
  transcript = (id?: string) => this.call<TranscriptResult>("transcript", id ? { id } : {});
  search = (phrase: string) => this.call<SearchResult>("search", { phrase });
  pauses = (min = 0.6) => this.call<PausesResult>("pauses", { min });
  history = async () => (await this.call<{ events: HistoryEvent[] }>("history")).events;
  /** Hand a round back with the two to five places Mike should look at first (they replace yours from before); without notes, what he hasn't watched yet. */
  handback = (notes?: HandbackNote[]) => this.call<HandbackResult>("handback", notes ? { notes } : {});
  /** cuts: words clipped at cuts; listen: hear each join too (`listened` in the result). */
  check = (opts: { from?: number | string; to?: number | string; changed?: boolean; quick?: boolean; cuts?: boolean; listen?: boolean } = {}) =>
    this.call<CheckResult>("check", opts);
  frame = (time: number | string, output: string) => this.call("frame", { time, output });
  /** Several frames on one contact sheet PNG, each labelled with its time. */
  frames = (opts: { times?: (number | string)[]; every?: number | string; from?: number | string; to?: number | string; width?: number; format?: string }, output: string) =>
    this.call("frames", { ...opts, output });
  clip = (start: number | string, end: number | string, output?: string) => this.call("clip", { start, end, output });
  /** The readable text view (`tandem timeline`), for when you do want to look. */
  timelineText = async (opts: { summary?: boolean; from?: number | string; to?: number | string; words?: boolean } = {}) =>
    (await this.call<{ text: string }>("timeline", opts)).text;

  /** The whole project as JSON, wrapped with helpers. Pass from/to for part of it. */
  async project(range: { from?: number | string; to?: number | string } = {}): Promise<ProjectView> {
    const r = await this.call<{ revision: number; project: Project }>("timeline", { ...range, format: "json" });
    return new ProjectView(r.project, r.revision);
  }

  /** Words whose text matches, with the words around them. Case-insensitive; punctuation ignored. */
  async findWords(pattern: RegExp | string, opts: { context?: number } = {}): Promise<(Word & { index: number; before: string; after: string })[]> {
    const { words } = await this.transcript();
    const re = typeof pattern === "string" ? new RegExp(`^${pattern}$`, "i") : pattern;
    const n = opts.context ?? 4;
    const bare = (w: Word) => w.text.replace(/[^\p{L}\p{N}'-]/gu, "");
    return words.flatMap((w, index) =>
      re.test(bare(w))
        ? [{ ...w, index, before: words.slice(Math.max(0, index - n), index).map((x) => x.text).join(" "), after: words.slice(index + 1, index + 1 + n).map((x) => x.text).join(" ") }]
        : [],
    );
  }

  // Edits

  /** Raw POST /v1/apply. */
  apply = (batch: { commands: Command[]; label?: string; dryRun?: boolean; expectedRevision?: number; idempotencyKey?: string }) =>
    this.call<ApplyResult>("apply", batch);

  /**
   * One labelled undo step. Dry-runs first (any failing command aborts before anything changes),
   * then applies with expectedRevision from your last read, so Mike's edits in between make it
   * fail with staleRevision instead of being edited over. Returns a short summary.
   */
  async edit(label: string, commands: Command[], opts: EditOptions = {}): Promise<EditSummary> {
    if (commands.length === 0) return { label, skipped: "no commands" };
    const expectedRevision = opts.expectedRevision ?? this.revision;
    const batch = { label, commands, expectedRevision, idempotencyKey: opts.idempotencyKey };
    const mode = opts.dryRun ?? "first";
    if (mode) {
      const dry = await this.apply({ ...batch, dryRun: true });
      if (mode === "only") return summarize(dry, commands.length);
    }
    return summarize(await this.apply(batch), commands.length);
  }

  /** Undoes the last edit, or the last `count` in one call (each undo is a new revision). */
  async undo(expectedRevision = this.revision, count?: number) {
    return this.call("undo", {
      ...(expectedRevision === undefined ? {} : { expectedRevision }),
      ...(count === undefined ? {} : { count }),
    });
  }
}

export type EditSummary = {
  label: string;
  skipped?: string;
  dryRun?: boolean;
  revision?: number;
  commands?: number;
  added?: number;
  changed?: number;
  removed?: number;
  createdIDs?: string[];
  warnings?: string[];
};

function summarize(r: ApplyResult, commands: number): EditSummary {
  return {
    label: r.label ?? "",
    ...(r.dryRun ? { dryRun: true } : { revision: r.revision }),
    commands,
    added: r.added.length,
    changed: r.changed.length,
    removed: r.removed.length,
    ...(r.createdIDs.length && !r.dryRun ? { createdIDs: r.createdIDs.slice(0, 20) } : {}),
    ...(r.warnings.length ? { warnings: r.warnings } : {}),
  };
}

export type ClipOn = ProjectClip & { track: Track; end: number };
export type TransitionOn = ProjectTransition & { track: Track };

/** The project JSON with ways to find things in it. Video tracks go bottom to top (V1 first). */
export class ProjectView {
  constructor(
    public readonly json: Project,
    public readonly revision: number,
  ) {}

  get tracks(): Track[] {
    return [...this.json.videoTracks, ...this.json.audioTracks];
  }

  /** A track by name ("Screen", "Captions") or ID. */
  track(nameOrID: string): Track {
    const t = this.tracks.find((t) => t.id === nameOrID || t.name === nameOrID);
    if (!t) throw new Error(`No track "${nameOrID}". Tracks: ${this.tracks.map((t) => t.name).join(", ")}`);
    return t;
  }

  /** Every clip, each with its track and end, in timeline order. */
  clips(filter: (c: ClipOn) => boolean = () => true): ClipOn[] {
    return this.tracks
      .flatMap((track) => track.clips.map((c) => ({ ...c, track, end: c.start + c.duration })))
      .filter(filter)
      .sort((a, b) => a.start - b.start);
  }

  clip(id: string): ClipOn {
    const c = this.clips((c) => c.id === id)[0];
    if (!c) throw new Error(`No clip ${id}`);
    return c;
  }

  /** Clips playing at a time, top track first. */
  at(time: number): ClipOn[] {
    return this.clips((c) => c.start <= time && time < c.end).reverse();
  }

  transitions(filter: (t: TransitionOn) => boolean = () => true): TransitionOn[] {
    return this.tracks.flatMap((track) => track.transitions.map((t) => ({ ...t, track }))).filter(filter);
  }

  /** Caption clips: text clips on a "Captions" track or tagged "captions". */
  captions(): (ClipOn & { text: string })[] {
    return this.clips((c) => !!c.content && "text" in c.content && (c.track.name === "Captions" || !!c.tags?.includes("captions"))).map(
      (c) => ({ ...c, text: (c.content as any).text.text as string }),
    );
  }

  /** A media item by ID, path (or the end of it) or role. */
  media(query: string) {
    const m = this.json.media.find((m) => m.id === query || m.path === query || m.path.endsWith(query)) ?? this.json.media.find((m) => m.role === query);
    if (!m) throw new Error(`No media "${query}"`);
    return m;
  }
}

/**
 * Commands that fix misheard words in caption clips: their text, their per-word list and
 * their name. `fixes` maps a misheard word to the right one ({ comics: "Convex" }); matching
 * ignores case and keeps the word's punctuation. Multi-word keys ("news models") match runs
 * of words. Returns the commands and what changed, for the label and for checking.
 */
export function fixCaptionWords(p: ProjectView, fixes: Record<string, string>) {
  const rules = Object.entries(fixes).map(([from, to]) => ({ from: from.toLowerCase().split(/\s+/), to }));
  const bare = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}'-]/gu, "");
  const changes: { clipID: string; before: string; after: string }[] = [];
  const commands: Command[] = [];
  for (const c of p.captions()) {
    const content = (c.content as any).text;
    const words: { text: string; start: number; end: number }[] = content.words ?? content.text.split(/\s+/).map((t: string) => ({ text: t }));
    const out: typeof words = [];
    for (let i = 0; i < words.length; ) {
      const rule = rules.find((r) => r.from.every((f, k) => words[i + k] && bare(words[i + k].text) === f));
      if (!rule) {
        out.push(words[i++]);
        continue;
      }
      const run = words.slice(i, i + rule.from.length);
      const last = run[run.length - 1];
      const punct = last.text.match(/[^\p{L}\p{N}]*$/u)?.[0] ?? "";
      out.push({ ...run[0], end: last.end, text: rule.to + punct });
      i += rule.from.length;
    }
    const text = out.map((w) => w.text).join(" ");
    if (text === content.text) continue;
    changes.push({ clipID: c.id, before: content.text, after: text });
    commands.push(
      cmd.updateClip({
        clipID: c.id,
        patch: { name: text, content: { text: { text, ...(content.words ? { words: out } : {}) } } },
      }),
    );
  }
  return { commands, changes };
}
