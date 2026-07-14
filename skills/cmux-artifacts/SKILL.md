---
name: cmux-artifacts
description: Create and edit cmux artifact panes. Use when the user asks to make, create, open, render, show, prototype, or save an artifact/artefact, React artifact, HTML artifact, or artifact capabilities showcase in cmux.
---

# cmux Artifacts

Use this skill when the user wants a live artifact pane in cmux. "Artefact" and
"artifact" mean the same thing.

Artifacts are Claude-artifacts-style panes backed by a real file in the global
store at `~/.config/cmux/artifacts/`. The pane hot-reloads when that file is
edited.

## Current Command Surface

```bash
cmux artifact new [options]
cmux artifact open <id|path> [options]
cmux artifact list [--repo <path>] [--limit N]
```

Supported options:

```bash
--title <text>
--kind <react|html|svg|mermaid|code|file>
--template <name>
--workspace <id|ref|index>
--surface <id|ref|index>
--window <id|ref|index>
--direction <left|right|up|down>
--focus <true|false>
```

## Fast Start

Create an artifact beside the calling surface:

```bash
cmux artifact new --surface "$CMUX_SURFACE_ID" --focus true
```

Create the bundled capabilities showcase:

```bash
cmux artifact new --template showcase --surface "$CMUX_SURFACE_ID" --focus true
```

Create the bundled live-events cockpit:

```bash
cmux artifact new --template live-events --surface "$CMUX_SURFACE_ID" --focus true
```

Create a named React artifact:

```bash
cmux artifact new --title "Pricing table" --kind react --surface "$CMUX_SURFACE_ID" --focus true
```

Create a named HTML artifact:

```bash
cmux artifact new --title "Browser capture" --kind html --surface "$CMUX_SURFACE_ID" --focus true
```

Create a Mermaid or SVG artifact:

```bash
cmux artifact new --title "System flow" --kind mermaid --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact new --title "Logo sketch" --kind svg --surface "$CMUX_SURFACE_ID" --focus true
```

List recent artifacts:

```bash
cmux artifact list --limit 10
cmux artifact list --repo . --limit 10
```

Reopen an artifact by id, path, or filename:

```bash
cmux artifact open <id-or-path> --surface "$CMUX_SURFACE_ID" --focus true
```

Open an existing Claude-style artifact file directly:

```bash
cmux artifact open /path/to/artifact.jsx --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact open /path/to/artifact.html --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact open /path/to/diagram.svg --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact open /path/to/flow.mermaid --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact open /path/to/script.py --surface "$CMUX_SURFACE_ID" --focus true
cmux artifact open /path/to/report.pdf --surface "$CMUX_SURFACE_ID" --focus true
```

This works for normal exported/copied Claude artifact source files: React source
saved as `.jsx`, `.tsx`, `.js`, or `.ts`, and HTML saved as `.html` or `.htm`.
It also accepts `.svg`, `.mermaid`/`.mmd`, common plain-code/text extensions,
and generated document files such as `.pdf`, `.docx`, `.xlsx`, and `.pptx`.
Generated documents are opened as downloadable/openable file artifacts rather
than compiled in the web runtime. React files should still export a default
component. If you only have artifact code in the clipboard, save it to a file
first, then open that file.

## Common Intent Recipes

Use live topology checks, not command-discovery checks, before placing artifacts:

```bash
cmux identify --json
cmux tree --all --id-format both
```

Do not run repeated `cmux artifact --help` / `cmux <command> --help` during a
normal flow. This skill is the command recipe; use help only when a command
fails in a way that suggests the installed cmux version has drifted.

### "Make an artifact in the pane to the right"

If there is no right-side helper pane yet, create the artifact to the right of
the caller surface:

```bash
cmux artifact new --surface "${CMUX_SURFACE_ID:-}" --focus false
```

If a right-side helper pane already exists, the user usually means "put another
tab/surface in that right pane", not "split the workspace again". In that case,
create or open the artifact in the existing helper pane rather than creating
another split. Use `cmux tree --all --id-format both` to identify the helper
pane, then target that pane when the installed command supports pane targeting;
otherwise report the missing targeting surface instead of creating duplicate
splits.

After creation, read the returned output:

```text
OK surface=surface:N pane=pane:N path=/Users/.../.config/cmux/artifacts/...
```

Treat that `surface:N` as the artifact surface for follow-up placement requests
such as "below it", "under that artifact", or "next to that".

### "Put Codex below the artifact"

Resolve "it" or "that" to the most recently created artifact surface when
unambiguous, then split from that surface and launch Codex in the new surface:

```bash
cmux identify --json
cmux tree --all --id-format both
cmux new-split down --workspace "${CMUX_WORKSPACE_ID:-}" --surface "$ARTIFACT_SURFACE" --focus false
cmux tree --all --id-format both
cmux send --surface "$NEW_SURFACE" --enter "codex"
```

Prefer a future higher-level agent command when available:

```bash
cmux agent new --provider codex --below "$ARTIFACT_SURFACE" --cwd "$PWD"
```

Until that exists, use the explicit split-and-send flow and keep focus false.

## Tagged Dev Builds

When dogfooding a tagged Debug app from the cmux repo, use the tag-bound helper
instead of a bare `cmux` binary:

```bash
CMUX_TAG=artifacts scripts/cmux-debug-cli.sh artifact new --template showcase --focus true
```

Use the tag that matches the running dev build. Do not use `/tmp/cmux-cli` for
tagged dogfood.

## Workflow

1. If `$CMUX_SURFACE_ID` is set, target it with `--surface "$CMUX_SURFACE_ID"`.
2. If `$CMUX_SURFACE_ID` is missing, run `cmux identify --json` to inspect the
   caller context. If the caller cannot be resolved, omit `--surface`; cmux will
   use the focused surface/workspace.
3. Run `cmux artifact new ...` and read the output:

   ```text
   OK surface=surface:N pane=pane:N path=/Users/.../.config/cmux/artifacts/...
   ```

4. Edit the returned `path` directly when the user requested custom content.
   The artifact pane reloads on save.
5. If the user requested a capabilities demo, use `--template showcase` rather
   than recreating the showcase by hand. If they asked for live events,
   operational signals, incident streams, eval streams, or real-time status, use
   `--template live-events`.
6. For recall requests like "open my last artifact", run
   `cmux artifact list --limit 1 --json`, then pass the returned `id` to
   `cmux artifact open`.

## Authoring Notes

- React artifacts should export a default React component.
- HTML artifacts should be complete HTML fragments or documents.
- SVG artifacts should be one complete `<svg>` document or fragment.
- Mermaid artifacts should contain Mermaid source only.
- Plain code artifacts are rendered read-only in a syntax-highlighted code pane;
  use a real editor for edits.
- PDF/Office artifacts are file artifacts: use the pane buttons to open them in
  the system app or save them to Downloads.
- `window.storage` is available inside artifact iframes as async
  `get/set/delete/list` and persists under the artifact store.
- Artifact source edits are snapshotted under the artifact store `versions/`
  directory for history/recovery.
- Keep artifact code self-contained unless the user explicitly asks for
  external assets.
- Markdown is intentionally handled by `cmux markdown`, not `cmux artifact`.
- In-artifact LLM calls (`window.claude`/Anthropic API proxying) are not wired
  yet.
- If an artifact feels slow only inside cmux, test again after the pane finishes
  first load. The renderer may be doing initial WebKit/runtime warmup.
- For visible verification, use cmux surface text or screenshot commands after
  creating the artifact.

## Related Skills

- `cmux`: topology, panes, surfaces, focus, and routing.
- `cmux-dev-workflow`: tagged Debug app build and CLI dogfood rules.
- `cmux-mochi-conductor`: driving visible agent panes when coordinating work.
