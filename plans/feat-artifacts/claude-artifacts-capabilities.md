# Claude Artifacts — Capabilities Reference

A complete map of the tools, libraries, and web technologies available inside Claude
artifacts (the sandboxed runtime that renders React/HTML/SVG/etc. inline in chat).

> Scope note: this is about what runs *inside an artifact's iframe* — the client-side
> sandbox. It is separate from Claude's own server-side tools (web search, file system,
> bash, connectors), which run in the conversation, not in your artifact.

> **cmux scope (working doc):** cmux targets parity with this surface EXCEPT
> **§6 "Claude API inside artifacts" — UNSUPPORTED.** The no-key Anthropic
> Messages API depends on the claude.ai runtime proxying auth; cmux does not
> provide it and will not shim `api.anthropic.com`. Everything else (rendering
> formats, the pinned JS library allow-list, HTML+CDN, styling, `window.storage`,
> constraints) is in scope. See `PLAN.md`.

---

## 1. Rendering formats

These file types render specially in the artifact UI:

| Format   | Extension   | Notes |
|----------|-------------|-------|
| React    | `.jsx`      | Functional/Hook/class components. Default export. No required props. |
| HTML     | `.html`     | HTML + CSS + JS in one file. Can pull scripts from a CDN. |
| Markdown | `.md`       | Standalone written content. |
| Mermaid  | `.mermaid`  | Flowcharts, sequence/gantt/state diagrams from text. |
| SVG      | `.svg`      | Vector graphics. |
| PDF      | `.pdf`      | Rendered document. |

Prefer single-file artifacts. For HTML and React, keep CSS and JS in the same file.

---

## 2. JavaScript libraries (React artifacts)

All importable directly — no install step. Versions are pinned by the runtime.

| Library          | Import                                       | Use for |
|------------------|----------------------------------------------|---------|
| lucide-react     | `import { Camera } from "lucide-react"`      | Icon set (v0.383.0). |
| recharts         | `import { LineChart, XAxis } from "recharts"`| Declarative React charts. |
| chart.js         | `import * as Chart from "chart.js"`          | Canvas-based charts. |
| plotly           | (imported as plotly)                          | Scientific / interactive plots. |
| d3               | `import * as d3 from "d3"`                    | Low-level data viz, scales, selections. |
| three            | `import * as THREE from "three"`             | 3D / WebGL (runtime is **r128** — see caveats). |
| mathjs           | `import * as math from "mathjs"`             | Expression parsing, matrices, units. |
| lodash           | `import _ from "lodash"`                      | Utility functions. |
| papaparse        | `import Papa from "papaparse"`               | CSV parsing. |
| SheetJS (xlsx)   | `import * as XLSX from "xlsx"`               | Read/write Excel XLSX/XLS. |
| mammoth          | `import * as mammoth from "mammoth"`         | Convert .docx → HTML/text. |
| tone             | `import * as Tone from "tone"`               | Web Audio synthesis & sequencing. |
| tensorflow       | (tensorflow.js)                               | In-browser ML inference/training. |
| shadcn/ui        | `import { Alert } from "@/components/ui/alert"` | Prebuilt UI components. |

### three.js (r128) caveats
- `THREE.OrbitControls` is **not** available.
- Don't use `THREE.CapsuleGeometry` (needs r142+). Use `CylinderGeometry`,
  `SphereGeometry`, or compose custom geometry.

---

## 3. HTML artifacts + CDN

In an `.html` artifact you can import external scripts from:

```
https://cdnjs.cloudflare.com
```

This opens up most of the cdnjs catalogue (anime.js, GSAP, p5.js, etc.) for plain
HTML/JS artifacts.

---

## 4. Styling

- **Tailwind** core utility classes work in React artifacts (no compiler, so only
  predefined base classes — arbitrary `[...]` values are unreliable; use inline styles
  or a `<style>` block for exact colours/values).
- `<style>` blocks, CSS variables, keyframes, and `@import` for web fonts all work.

---

## 5. Persistent storage (`window.storage`)

A key–value store that **persists across sessions** — for journals, trackers,
leaderboards, collaborative tools. This is the one storage that *does* work
(localStorage/sessionStorage do **not** — see Constraints).

```js
// Personal data (default, shared = false)
await window.storage.set("entries:123", JSON.stringify(entry));

// Shared data (visible to ALL users of the artifact)
await window.storage.set("leaderboard:alice", JSON.stringify(score), true);

// Retrieve
const r = await window.storage.get("entries:123");
const entry = r ? JSON.parse(r.value) : null;

// List keys by prefix
const { keys } = await window.storage.list("entries:");

// Delete
await window.storage.delete("entries:123");
```

API surface:

| Method | Returns |
|--------|---------|
| `get(key, shared?)`        | `{key, value, shared}` \| `null` |
| `set(key, value, shared?)` | `{key, value, shared}` \| `null` |
| `delete(key, shared?)`     | `{key, deleted, shared}` \| `null` |
| `list(prefix?, shared?)`   | `{keys, prefix?, shared}` \| `null` |

Rules of thumb:
- Hierarchical keys: `table:record_id` (e.g. `todos:todo_1`). No whitespace, slashes,
  or quotes. Under 200 chars.
- Values: text/JSON only, < 5 MB each.
- Batch related data into one key to avoid many sequential calls.
- Always wrap in `try/catch` — **reading a missing key throws** (it does not return null).
- Last-write-wins on concurrent updates. Always pass `shared` explicitly.

---

## 6. Claude API inside artifacts ("Claude in Claude")

Artifacts can call the Anthropic Messages endpoint with **no API key** (the runtime
handles auth). This lets you build AI-powered artifacts.

```js
const res = await fetch("https://api.anthropic.com/v1/messages", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: "claude-sonnet-4-6",   // use Sonnet 4.6
    max_tokens: 1000,             // keep at 1000
    messages: [{ role: "user", content: "Your prompt here" }],
  }),
});
const data = await res.json();

// Extract text blocks by TYPE, not by position:
const text = data.content
  .filter(b => b.type === "text")
  .map(b => b.text)
  .join("\n");
```

### Structured output
Tell the model in the system/prompt to return **only JSON, no preamble or backticks**,
then strip any ``` fences and `JSON.parse` the result inside a `try/catch`.

### Web search tool
```js
tools: [{ "type": "web_search_20250305", "name": "web_search" }]
```

### MCP servers
```js
mcp_servers: [{ "type": "url", "url": "https://mcp.asana.com/sse", "name": "asana-mcp" }]
```
Available servers map to the user's connected connectors in Claude.ai.

### Files (PDF / image input)
Send as base64 with the correct `media_type`:
```js
content: [
  { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } },
  { type: "image",    source: { type: "base64", media_type: "image/jpeg",      data: b64 } },
  { type: "text", text: "Summarise this." },
]
```

### State
The API is stateless — resend the full `messages` history each call for multi-turn
flows or game/app state.

---

## 7. Constraints & gotchas

- **No browser storage APIs.** `localStorage`, `sessionStorage`, IndexedDB, cookies —
  none work in claude.ai artifacts. Use React state (`useState`/`useReducer`) for
  session data, or `window.storage` for persistence.
- **No `<form>` tags in React artifacts.** Use `onClick` / `onChange` handlers instead
  of form submission.
- **Tailwind arbitrary values** (`bg-[#123456]`) are unreliable — there's no compiler.
  Use inline styles or `<style>`.
- **React libs:** base React + hooks (`import { useState } from "react"`). Provide
  defaults for any props; use a default export.
- **three.js is r128** — see §2 caveats.
- Keep it single-file where possible.

---

## 8. Quick chooser

| You want to…                         | Reach for |
|--------------------------------------|-----------|
| Charts in React                      | recharts (declarative) or chart.js (canvas) |
| Low-level / custom data viz          | d3 |
| 3D / WebGL                           | three (r128) |
| Icons                                | lucide-react |
| Audio / music                        | tone |
| Parse CSV                            | papaparse |
| Read/write Excel                     | SheetJS (xlsx) |
| Read Word docs                       | mammoth |
| In-browser ML                        | tensorflow.js |
| Math / units / matrices              | mathjs |
| Utilities                            | lodash |
| Prebuilt UI                          | shadcn/ui |
| Persist data across sessions         | `window.storage` |
| Call an LLM from the artifact        | Anthropic Messages API (no key) |
| Diagrams from text                   | `.mermaid` artifact |

---

*Reference compiled for the Claude artifacts runtime. Treat library versions as
runtime-pinned; if an import fails, check the version caveats above.*
