---
name: cmux-inline-vscode
description: Open a directory as a full Visual Studio Code serve-web workbench in a native cmux pane. Use when the user asks to open VS Code, VS Code Server, or a project editor inside cmux, including when they want to use the normal Claude Code Marketplace extension within that workbench.
---

# cmux Inline VS Code

Open the ordinary VS Code workbench inside cmux. Treat Claude Code as a normal VS Code extension; never extract its tab, create a Claude-only server profile, seed extension registries, or open a raw serve-web URL with `cmux browser`.

## Open a workbench

```bash
# Current directory in the caller's workspace. Does not steal focus.
cmux vscode open

# A specific directory.
cmux vscode open /path/to/project

# Explicit routing or intentional focus.
cmux vscode open /path/to/project --workspace workspace:2 --focus true
```

The first workbench beside a full-width pane creates the normal right-hand split. Later opens reuse that right pane as tabs according to cmux's shared adaptive-right placement policy.

## Handle setup errors

- `vscode_not_installed`: tell the user to install the standard Visual Studio Code app in `/Applications`, then retry. Do not silently install software.
- `invalid_path`: resolve the directory to an existing absolute path and retry.
- `browser_disabled`: explain that cmux's browser surfaces must be enabled for the embedded workbench.
- `vscode_start_failed`: report that VS Code serve-web did not start; do not fall back to a blank browser pane.

## Claude Code inside the workbench

If the user wants Claude Code:

1. Open the full workbench with `cmux vscode open`.
2. Ask them to use the normal Extensions view and install the official Claude Code extension from the VS Code Marketplace if it is not already present in the served environment.
3. Ask them to sign in through the extension's normal UI.

Never copy the desktop extension directory, write `extensions.json`, create a separate `--server-data-dir`, or automate authentication. VS Code's desktop and serve-web extension hosts may legitimately require separate Marketplace installation.
