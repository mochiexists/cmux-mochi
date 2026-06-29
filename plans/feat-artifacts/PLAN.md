# cmux Artifacts — implementation plan

A Claude-artifacts-style pane for cmux: a window that live-renders a throwaway
React/TSX UI, with every artifact archived to a single **global** store (Codex
session-history style) and recallable via a conductor-aware skill.

Status: IN PROGRESS. The core React/HTML artifact renderer exists; compatibility
work is expanding it toward Claude artifact formats while keeping Markdown on
the existing MarkdownPanel path.

---

## 1. Product shape (decided with Phil)

- **Render target (Phase 1):** React/TSX. The artifact file `export default`s a
  React component; it renders in a sandboxed iframe with an in-browser transform
  and a curated allow-list of libraries (Claude-artifacts parity).
- **Storage model:** ONE global store, not per-repo folders. Mirrors how
  Codex/Claude store session history globally. Per-directory `.cmux/artifacts/`
  was explicitly rejected as messy (a folder would appear in every cwd you ever
  triggered from).
- **Provenance:** each artifact records the cwd / git repo root / workspace /
  surface it was created from, so we keep the "where was this made" signal
  without scattering files.
- **Recall:** a cmux skill knows the global location and can list / search /
  reopen artifacts ("open my last artifact", "show artifacts from this repo").
- **Auto-positioning:** built on the conductor concept — when a user in an agent
  session says "make an artifact", the skill resolves the current surface and
  opens the artifact pane *next to it* automatically.

---

## 2. Storage layout

Root: `~/.config/cmux/artifacts/` (idiomatic — cmux already uses
`~/.config/cmux/cmux.json`; see `CmuxConfig.swift:1916`).

Codex-style date-bucketed files + an append-only index:

```
~/.config/cmux/artifacts/
  index.jsonl                          # append-only provenance log (source of truth for recall)
  2026/06/28/
    20260628-143022-pricing-table-a1b2.tsx
    20260628-143022-pricing-table-a1b2.json   # per-artifact sidecar (redundant w/ index for robustness)
```

`index.jsonl` record (one JSON object per line):

```json
{
  "id": "a1b2c3d4",
  "createdAt": "2026-06-28T14:30:22Z",
  "title": "pricing-table",
  "file": "2026/06/28/20260628-143022-pricing-table-a1b2.tsx",
  "kind": "react",
  "origin": {
    "cwd": "/Users/phil/code/foo/src/components",
    "repoRoot": "/Users/phil/code/foo",
    "workspaceId": "…",
    "surfaceId": "…",
    "sessionTag": "…"
  }
}
```

- **Naming:** `<yyyymmdd-hhmmss>-<slug>-<shortid>.<ext>`. Timestamp = chrono sort
  + collision-free; slug from the first component name or a "name this" field;
  shortid disambiguates same-second creates.
- **cwd capture** is the literal answer to "we record the CWDs where they were
  created" — resolved at trigger time via the same chain new splits use
  (`resolvedTerminalStartupWorkingDirectory`, `Workspace.swift:7206`):
  focused-pane live cwd (`panelDirectories[panelId]`) → `gitRepoRoot(for:)`
  (`FileExplorerStore.swift:1321`) → workspace `currentDirectory`.
- **Override:** `artifacts.directory` in `cmux.json` to relocate the global root.

---

## 3. Swift architecture (`Sources/Panels/`, modeled on `MarkdownPanel`)

The Markdown viewer is a near-exact template — file on disk, `FileWatcher`
live-reload, stable WKWebView that survives split churn, bundled HTML shell with
`{{placeholder}}` substitution, pushed content via `evaluateJavaScript`.

| New file | Mirrors | Role |
|---|---|---|
| `PanelType.artifact` in `Panel.swift:6` | existing enum | new pane kind + decode fallback |
| `ArtifactPanel.swift` | `MarkdownPanel.swift` | holds `filePath` in the global store, watches it, live-reloads on save |
| `ArtifactRendererSession` + `ArtifactWebRenderer.swift` | `MarkdownRendererSession` / `MarkdownWebRenderer.swift:262` | stable WKWebView; load shell once, push file contents on change |
| `ArtifactViewerAssets.swift` | `MarkdownViewerAssets.swift` | load bundled runtime shell, substitute placeholders |
| `Workspace.newArtifactSplit/Surface(...)` | `newMarkdownSplit` (`Workspace.swift:7525`) | scaffold starter file in global store, open pane via `createPanel` (`Workspace.swift:1551`) |
| `ArtifactStore.swift` | (new) | resolve global root, allocate path, append `index.jsonl`, capture provenance, list/search for recall |

Persistence: add `PanelType.artifact` + `filePath` to `SessionPersistence` so
artifact panes restore on relaunch (markdown already does this).

---

## 4. The React runtime (`webviews/` → `Resources/artifact-viewer/`)

**Target contract:** match the Claude-artifacts runtime surface documented in
`plans/feat-artifacts/claude-artifacts-capabilities.md` so agent-authored
artifacts written for claude.ai run unmodified in cmux. `webviews/` is already a
Vite + React 19 project bundled into `Resources/` via
`scripts/build-webviews-app.sh`; add an `artifact-viewer` entry.

Harness:
- Sandboxed iframe + React + ReactDOM + **esbuild-wasm** transform (faster /
  smaller than Babel-standalone, native TS). Imports the file's default export,
  mounts it; no required props.
- Error boundary → in-pane overlay (never a white screen).
- No dev server, no per-artifact build: save → watcher → re-transform →
  re-render. Hot-reload is free given the file watcher.

Module resolution (no install step, runtime-pinned) — provide via **import map →
pinned esm.sh URLs**, vendor for offline later:
- `react`, `react-dom` (+ hooks), `lucide-react`, `recharts`, `chart.js`,
  `plotly`, `d3`, `three` (**pin r128** — OrbitControls/CapsuleGeometry absent),
  `mathjs`, `lodash`, `papaparse`, `xlsx` (SheetJS), `mammoth`, `tone`,
  `tensorflow`, and the `@/components/ui/*` shadcn set (we bundle these).
- HTML artifacts: allow `<script src="https://cdnjs.cloudflare.com/...">`.
- **Supply-chain:** the host-injected libs are *our* dependency, not user
  content. Pin exact versions and add `integrity="sha384-…" crossorigin` (SRI)
  to any CDN `<script>`, or — preferred — **vendor the allow-list into
  `Resources/artifact-viewer/`** so the runtime is offline and tamper-evident.
  Artifact *user code* stays sandboxed in the iframe regardless.

Styling: Tailwind **core utility classes** (Play CDN or prebuilt base — no
compiler, so arbitrary `[...]` values unreliable; doc that), `<style>` blocks,
CSS variables, keyframes, `@import` web fonts.

Host-provided APIs (we own the host, so we implement these natively):
- **`window.storage`** — async KV persisting across sessions, `get/set/delete/list`
  with personal + `shared` scopes. Back it with files under the store root
  (e.g. `~/.config/cmux/artifacts/storage/{personal,shared}/…`). Mirror the
  documented semantics: missing-key `get` THROWS, values text/JSON < 5 MB,
  last-write-wins.

**Out of scope: "Claude-in-artifact" (no-key Anthropic Messages API).** The
claude.ai runtime proxies `fetch("https://api.anthropic.com/v1/messages")`
through its own auth; cmux does not, so artifacts that call the Anthropic API
will not work and we do NOT shim it. (See §6 of the capabilities brief — marked
unsupported there.) Artifacts needing an LLM should go through a cmux agent
pane, not an in-artifact API call.

Constraints to enforce/document (from the brief): no `localStorage`/
`sessionStorage`/IndexedDB/cookies (use React state or `window.storage`); no
`<form>` in React artifacts; default export required.

Current compatibility routing:
- `.tsx`/`.jsx`/`.ts`/`.js` → React artifact runtime.
- `.html`/`.htm` → HTML iframe runtime.
- `.svg` → SVG runtime wrapper in the artifact shell.
- `.mermaid`/`.mmd` → Mermaid runtime wrapper in the artifact shell.
- Plain code/text extensions → readable, syntax-highlighted code artifact pane
  with plain monospace fallback if the highlighter cannot load.
- `.pdf`/`.docx`/`.xlsx`/`.pptx` and similar generated document files → file
  artifact pane with Open File and Save to Downloads actions; they are not
  compiled or rendered as React.
- `.md` stays on the existing `MarkdownPanel` path rather than being duplicated
  as an artifact kind.

Implemented compatibility storage/history:
- `window.storage` is available inside React/HTML/SVG/Mermaid artifact iframes
  as async `get`, `set`, `delete`, and `list`, backed by
  `~/.config/cmux/artifacts/storage/{personal,shared}/`.
- Artifact source changes are snapshotted into
  `~/.config/cmux/artifacts/versions/` with an append-only revision index. The
  live source file remains mutable, but the previous contents are retained for
  history/recovery.

TODOs intentionally left out of this compatibility pass:
- `window.claude` / in-artifact LLM calls. Keep unsupported for now; add only
  after a separate auth/runtime design.

---

## 5. CLI + conductor/skill integration (the killer UX)

**Precedent already exists:** `cmux markdown open <path> --workspace --surface
--window --direction right|down|left|up --focus` (`CLI/cmux.swift:5238`). The
artifact CLI is a direct sibling.

New CLI verbs (mirror markdown):

```
cmux artifact new  [--title <t>] [--surface <id>] [--direction right] [--focus true]
cmux artifact open <id|path> [--surface <id>] [--direction right]
cmux artifact list [--repo <path>] [--limit N]      # reads index.jsonl
```

**Auto-positioning flow** ("open a window next to me automatically"):

1. A pane self-locates via the env vars cmux injects: `$CMUX_SURFACE_ID`,
   `$CMUX_WORKSPACE_ID` (confirmed present in `Sources/`).
2. User in a Claude/Codex session says "make me an artifact of X".
3. The **`cmux-artifacts` skill** (new, builds on `cmux-mochi-conductor`) runs
   `cmux artifact new --surface $CMUX_SURFACE_ID --direction right --focus false`.
4. cmux resolves cwd from that surface, scaffolds the file in the global store,
   records provenance, and opens an artifact pane **split to the right of the
   triggering session** — no focus theft (per socket focus policy).
5. The agent writes/edits the artifact file; the pane live-reloads as it types.

The skill also wraps `cmux artifact list` for recall ("reopen my last artifact",
"what artifacts did I make in this repo" — filters `index.jsonl` by `repoRoot`).

This is the conductor pattern reused verbatim: the skill already knows how to
drive panes by surface/workspace ID via the CLI; artifacts just add a new verb.

---

## 6. Phase 2 (spread): SwiftUI artifacts for iOS projects

When the triggering cwd is a Swift/iOS project, an artifact could be a live
**SwiftUI view** that picks up the project's styling, instead of TSX.

- Detection: cwd contains `.xcodeproj`/`Package.swift` → offer `kind: "swiftui"`.
- Rendering options to evaluate (harder than the web path — flagged as a
  separate spread, and Codex may already be building something here, so
  coordinate before investing):
  - Compile the view into a tiny throwaway SwiftPM target + render to image via
    a helper process (heavy, but real).
  - Drive an Xcode Preview / `#Preview` harness and screenshot it.
  - A lightweight DSL subset interpreted natively (fast, limited).
- Same global store + provenance + skill recall; only the renderer differs.

Decision deferred. Phase 1 (React/TSX) ships first and stands alone.

---

## 7. Repo obligations (part of "full feature", per CLAUDE.md)

- **Localization audit:** every user-facing string in `Resources/Localizable.xcstrings`
  + `web/messages/{en,ja}.json`. Enumerate touched surfaces at handoff.
- **Shortcut policy:** the "New Artifact" shortcut goes in `KeyboardShortcutSettings`,
  is editable in Settings, supported in `cmux.json`, and documented.
- **Shared-behavior policy:** palette / shortcut / CLI / skill all call ONE
  `Workspace.newArtifact…` path. No per-surface duplication.
- **Tests:** two-commit red/green regression tests, wired into
  `cmux.xcodeproj/project.pbxproj` (the silent "Executed 0 tests" trap).
- **SwiftUI list rules** if an artifact picker/sidebar is added (snapshot
  boundary, no state mutation in `body`).

---

## 8. Build phases

1. **Skeleton** — `PanelType.artifact`, `ArtifactPanel` (clone Markdown),
   `ArtifactStore` (global path + index.jsonl + provenance), static-HTML render
   only. One entrypoint (palette). Tagged dev build, verify live-reload.
2. **React runtime** — `artifact-viewer` bundle (esbuild-wasm + allow-list),
   `ArtifactWebRenderer`, error overlay.
3. **CLI + skill** — `cmux artifact new/open/list`, `cmux-artifacts` skill,
   auto-position-beside-surface, recall.
4. **Polish** — persistence/restore, shortcut, Settings, localization, tests.
5. **(Spread)** SwiftUI-view artifacts for iOS projects — separate plan,
   coordinate with Codex effort.
