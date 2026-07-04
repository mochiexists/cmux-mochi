---
name: cmux-claude-code
description: Open Claude Code's VS Code extension in a cmux browser pane by launching VS Code serve-web from a real project folder. Use when the user asks for Claude Code in cmux, Claude Code VS Code, inline Claude Code, or a VS Code Web pane that keeps VS Code/Claude state outside cmux app internals.
---

# Claude Code in cmux

Use this skill to run VS Code Web with the Claude Code extension and open it in a cmux browser pane. This is an operator workflow, not cmux app runtime behavior.

## Rules

- Use the user's normal Visual Studio Code install.
- Keep VS Code server data outside `~/Library/Application Support/cmux`.
- Launch from a real project folder, not `/`, raw `$HOME`, or an unclear directory.
- If the project folder is unclear, ask the user. Do not invent a fallback.
- Do not promise that VS Code chrome can be fully hidden; use remembered VS Code layout/settings when they work.
- Do not modify cmux source code or release workflows for this task.
- Prefer an existing VS Code Web server when one is already running for the user.
- If starting a server, leave `serve-web` running in a persistent terminal/session. Do not background it from a transient agent shell and assume it will survive.

## Quick Start

```bash
CODE="${CODE:-/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
SERVER_DATA_DIR="${SERVER_DATA_DIR:-$HOME/.local/state/cmux/vscode-serve-web/claude-code}"

case "$PROJECT_DIR" in
  /|"${HOME}") echo "Choose a real project folder, not $PROJECT_DIR" >&2; exit 2 ;;
esac

"$CODE" --install-extension anthropic.claude-code

mkdir -p "$SERVER_DATA_DIR"
"$CODE" serve-web \
  --host 127.0.0.1 \
  --port 0 \
  --accept-server-license-terms \
  --server-data-dir "$SERVER_DATA_DIR" \
  --default-folder "$PROJECT_DIR"
```

Leave that command running. The server owns the VS Code Web session.

Copy the exact local URL printed by `serve-web`, including any token or path, then open it in cmux:

```bash
cmux new-pane \
  --workspace "${CMUX_WORKSPACE_ID:-}" \
  --type browser \
  --direction right \
  --url "$VSCODE_WEB_URL"
```

If `CMUX_WORKSPACE_ID` is unset, use `cmux identify --json` first or open the URL with:

```bash
cmux browser open "$VSCODE_WEB_URL"
```

## Workflow

1. Identify the project folder.
   ```bash
   pwd
   printf 'workspace=%s\nsurface=%s\n' "${CMUX_WORKSPACE_ID:-}" "${CMUX_SURFACE_ID:-}"
   ```
2. Confirm VS Code's CLI exists.
   ```bash
   command -v code || test -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
   ```
3. Install or update the Claude Code extension.
   ```bash
   "$CODE" --install-extension anthropic.claude-code
   "$CODE" --list-extensions | grep -i '^anthropic\.claude-code$'
   ```
4. Reuse an existing VS Code Web server if one is already listening and points at a safe data dir.
   ```bash
   ps -axo pid,command | grep '[c]ode.*serve-web'
   lsof -nP -iTCP -sTCP:LISTEN | grep code-tunn
   ```
5. Otherwise start `serve-web` in a persistent terminal/session with a stable `--server-data-dir`.
6. Leave the server command running.
7. Open the printed local URL in a right-side cmux browser pane.
8. In VS Code Web, open the Claude Code panel using the command palette if it does not open automatically.

## State and Sign-In

Claude Code sign-in and extension state belong to VS Code, not cmux. Reuse the same `SERVER_DATA_DIR` for future launches if the user wants the same web VS Code state. If the extension asks for sign-in again, complete sign-in inside VS Code Web and retry with the same server data dir.

## Optional Chrome Reduction

After VS Code Web opens, use VS Code's own commands/settings:

- `View: Toggle Activity Bar Visibility`
- `View: Toggle Primary Side Bar Visibility`
- `View: Toggle Status Bar Visibility`
- `Claude Code: Open`

These are VS Code behaviors and may vary by version/profile. Treat them as UI polish, not a hard cmux guarantee.

## Troubleshooting

- If macOS shows "Visual Studio Code would like to access data from other apps," stop the server and verify `--server-data-dir` is not inside cmux's Application Support directory.
- If the cmux pane opens to `about:blank`, open the full printed `serve-web` URL directly; `--content-mode vscode-claude-code` alone does not start VS Code Server.
- If the pane loads once and then changes to "refused to connect," the `serve-web` process exited. Restart it in a persistent terminal/session and keep it running.
- If `code` is missing from `PATH`, use the app-bundled CLI at `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`.
- If no Claude command appears, run `"$CODE" --install-extension anthropic.claude-code` again and restart `serve-web`.
