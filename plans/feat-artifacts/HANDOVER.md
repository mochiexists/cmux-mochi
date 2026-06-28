# Artifacts feature — handover checklist (for Codex)

Branch: `feat/artifacts` (off `main`). Read `PLAN.md` and
`claude-artifacts-capabilities.md` in this folder first — they are the spec.
**Scope reminder: §6 "Claude API inside artifacts" is OUT OF SCOPE** — do not
proxy `api.anthropic.com`.

---

## 0. State of play (what's DONE and building)

Phase A is complete and compiles end-to-end. Commits on `feat/artifacts`:

| Commit | What |
|--------|------|
| docs | plan + capabilities brief + showcase.jsx |
| `ArtifactStore` | global store model (`~/.config/cmux/artifacts/`), `index.jsonl`, provenance, slug/path helpers, `kind(forFileExtension:)`, `createNew` — **14 unit tests green** |
| panel skeleton | `PanelType.artifact`, `ArtifactPanel` (file-watch live-reload), `ArtifactPanelView` (PLACEHOLDER: renders source as text), `PanelContentView` routing, `SurfaceKind.artifact`, all exhaustive switches extended |
| creation | `ArtifactScaffold`, `Workspace.newArtifactSurface` / `splitPaneWithArtifact` / `createArtifact` |
| entrypoint | `cmux artifact new` CLI + `artifact.new` RPC → opens an artifact pane **beside** `$CMUX_SURFACE_ID` |

The end-to-end flow WORKS today but renders the artifact **source as plain
text** (placeholder). Your job is the live renderer + polish.

Key files:
- `Sources/Artifacts/ArtifactStore.swift`, `ArtifactScaffold.swift`,
  `ArtifactPanel.swift`, `ArtifactPanelView.swift` ← **replace the placeholder body**
- `Sources/Workspace.swift` (search `// MARK: - Artifacts`)
- `Sources/TerminalController.swift` (search `v2ArtifactNew`)
- `CLI/cmux.swift` (search `runArtifactCommand`)
- `cmuxTests/ArtifactStoreTests.swift`

---

**✅ The full loop is VALIDATED on this machine (2026-06-28):** built the tagged
Debug app, launched it, and `cmux artifact new` opened a pane beside the focused
surface + wrote the store/index with provenance, app stable. Commands below are
confirmed working.

## 1. The build/test loop (USE THIS — the machine has a zig break)

This Mac is on Xcode 26.5 / macOS 26, which breaks the zig 0.15.2 link of the
Ghostty CLI helper. You MUST pass `CMUX_SKIP_ZIG_BUILD=1` or every build fails at
`undefined symbol: __availability_version_check`. Details in
`zig-macos26-link-break-and-local-deploy-workaround` memory.

**Compile + run unit tests** (the `cmux` scheme excludes tests — use `cmux-unit`):
```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux-unit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-artifacts \
  test -only-testing:cmuxTests/ArtifactStoreTests CMUX_SKIP_ZIG_BUILD=1
```

**Compile-only (find Swift errors fast)**: same but `build` instead of `test`.
Ignore log lines matching `__availability_version_check`/`undefined symbol`/
`linkd` — those are the benign helper-link skip.

**Build a launchable tagged Debug app**:
```bash
CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag artifacts        # add --launch to open it
```
Grab the `App path:` line from the output for a `file://` link.

**Drive it via the conductor CLI** (tagged, isolated socket):
```bash
CMUX_TAG=artifacts scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=artifacts scripts/cmux-debug-cli.sh artifact new --title "Smoke test" --kind react
# Acceptance fixture — opens the bundled showcase (full lib allow-list):
CMUX_TAG=artifacts scripts/cmux-debug-cli.sh artifact new --template showcase --focus true
```
(The debug CLI scrubs `$CMUX_SURFACE_ID`, so the handler falls back to the
workspace's focused surface — that's expected.)

**Adding a new Swift file**: no synchronized groups — you MUST wire it into
`cmux.xcodeproj/project.pbxproj`. Use the ruby gem (system ruby lacks it):
```bash
/opt/homebrew/opt/ruby/bin/ruby -e 'require "xcodeproj"; p=Xcodeproj::Project.open("cmux.xcodeproj");
  g=p.groups.find{|x|x.path.to_s=="Sources"}; t=p.targets.find{|x|x.name=="cmux"};
  r=g.new_file(File.join(Dir.pwd,"Sources/Artifacts/NewFile.swift")); t.add_file_references([r]); p.save'
python3 scripts/normalize-pbxproj.py
```
Tests go in the `cmuxTests` group + `cmuxTests` target. Run
`./scripts/lint-pbxproj-test-wiring.sh` after.

---

## 2. Phase B — the live WebView renderer (the main job)

Goal: replace `ArtifactPanelView`'s placeholder with a real WKWebView that renders
the artifact to Claude-artifacts parity. Model EVERYTHING on the markdown viewer,
which already does file→WKWebView with a stable session and content push:
- `Sources/Panels/MarkdownPanel.swift` (panel), `MarkdownWebRenderer.swift`
  (`loadHTMLString` + `evaluateJavaScript` push at ~line 262), `MarkdownPanelView.swift`
  (SwiftUI host), `MarkdownViewerAssets.swift` (bundled shell + `{{placeholder}}`
  substitution), `Resources/markdown-viewer/shell.html`.

Checklist:
- [ ] `Resources/artifact-viewer/` runtime shell: React + ReactDOM + **esbuild-wasm**
      transform of the source's default export, mounted in a sandboxed surface.
      Build it through `webviews/` (Vite, React 19) via `scripts/build-webviews-app.sh`,
      OR hand-author a self-contained shell.html. Decide vendor-vs-CDN (see PLAN §4).
- [ ] Module resolution: import-map → pinned esm.sh for the allow-list (lucide-react,
      recharts, chart.js, plotly, d3, three **r128**, mathjs, lodash, papaparse,
      xlsx, mammoth, tone, tensorflow, shadcn `@/components/ui/*`). Vendor for offline
      + SRI (supply-chain note in PLAN).
- [ ] Tailwind core utilities; `<style>`/CSS-vars/web-fonts.
- [ ] `.html` kind: load the file as-is (allow cdnjs `<script>`).
- [ ] Error boundary → in-pane overlay (never a white screen).
- [ ] `ArtifactRendererSession` + `ArtifactWebRenderer` (own the WKWebView so it
      survives split/tab churn — copy `MarkdownRendererSession`).
- [ ] `ArtifactPanel` owns the renderer session; push `source` on every file-watch
      change → hot reload.
- [ ] **Acceptance test**: `plans/feat-artifacts/artifact-capabilities-showcase.jsx`
      (743 lines, imports three/d3/mathjs/lodash/tone/recharts/lucide) renders fully.
      Copy it into the store and `cmux artifact open` it.

## 3. Phase C — parity + integration

- [ ] **`window.storage`**: WKScriptMessageHandler bridging JS↔Swift, async
      `get/set/delete/list`, personal + `shared` scopes, backed by
      `~/.config/cmux/artifacts/storage/{personal,shared}/`. Match documented quirks:
      missing-key `get` THROWS, values text/JSON <5 MB, last-write-wins.
- [ ] **`cmux artifact open <id|path>`** and **`cmux artifact list`** CLI + RPCs
      (list reads `index.jsonl`, filter by `--repo`). Mirror `artifact.new`
      (`v2ArtifactNew` in TerminalController.swift) + `runArtifactCommand` in CLI.
- [ ] **`cmux-artifacts` skill** under `skills/` (extends `cmux-mochi-conductor`):
      reads `$CMUX_SURFACE_ID`, runs `cmux artifact new --surface … --direction right`,
      and does recall via `cmux artifact list`. This is the "user says 'make an
      artifact' → pane opens beside them" UX.
- [ ] **Persistence/restore**: replace the two `// TODO(artifacts)` `return nil`s in
      `Workspace.swift` (session snapshot build + restore) so artifact panes (filePath
      + kind) survive relaunch. Model on the markdown/project snapshot arms.

## 4. Polish / gates (cmux required-before-merge)

- [ ] **Localization**: every new user-facing string → `Resources/Localizable.xcstrings`
      (en + ja). New keys so far: `artifact.title`, `artifact.placeholder.banner`,
      `artifact.unavailable`, `commandPalette.kind.artifact`. They currently only have
      `defaultValue` English fallbacks — the audit requires real entries. Run the
      `cmux-localization` skill.
- [ ] **Shortcut**: if you add a "New Artifact" keybinding, register it in
      `KeyboardShortcutSettings`, Settings UI, `cmux.json`, and the shortcut docs.
- [ ] **Tests**: add a `createNew` round-trip test; two-commit red/green for any bug
      fix; wire test files into pbxproj (`lint-pbxproj-test-wiring.sh`).
- [ ] **Docs**: document `cmux artifact` in the CLI/config docs under `web/`.
- [ ] Run `/ask-codex` review loop per the repo policy before declaring done.

## 5. Gotchas

- `FileWatcher` lives in **`CmuxFoundation`**, not `CmuxFileWatch` (that module
  doesn't exist — easy stale-import trap).
- `.gitignore` has `artifacts/` (release scratch). `Sources/Artifacts/` is
  re-included via `!Sources/Artifacts/**` — keep that or new files vanish silently.
- New-artifact default extension is `tsx` (repo TS pref) but the classifier accepts
  `jsx/js/ts/html/htm` so claude.ai `.jsx` and the showcase open fine.
- Every exhaustive `PanelType` switch must handle `.artifact`; the compiler finds
  them. `SurfaceKind` also has an `.artifact` case now.
- `v2ArtifactNew` runs on the main actor via `v2MainSync`; `ArtifactStore.createNew`
  does sync git + file I/O there — fine for a user action, don't move to a hot path.
