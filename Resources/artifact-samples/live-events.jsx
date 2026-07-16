import React, { useEffect, useMemo, useState } from "react";

const palette = {
  bg: "#090d10",
  panel: "#11171c",
  panel2: "#151c22",
  panel3: "#0f1419",
  panel4: "#182128",
  border: "#2a343d",
  borderStrong: "#3e505d",
  text: "#eef3f5",
  muted: "#a1adb5",
  faint: "#697781",
  green: "#60d39c",
  cyan: "#66d2e3",
  amber: "#efbb6a",
  red: "#e9777e",
  blue: "#91aaff",
  pink: "#ee8bb9",
};

const eventFamilies = [
  {
    family: "Window and workspace",
    color: palette.green,
    events: "window.created, window.focused, window.closed, workspace.created, workspace.selected, workspace.closed, workspace.reordered, workspace.prompt.submitted",
    meaning: "The navigation frame changed. A workbench can update high-level topology, counters, focus trails, and routing hints.",
  },
  {
    family: "Pane and surface",
    color: palette.cyan,
    events: "pane.created, pane.focused, pane.resized, pane.swapped, pane.joined, surface.created, surface.selected, surface.focused, surface.closed, surface.moved, surface.reordered",
    meaning: "The actual work area changed. This is the signal a live artifact uses to redraw pane maps and know which surface is worth reading.",
  },
  {
    family: "Input and actions",
    color: palette.amber,
    events: "surface.action, surface.input_sent, surface.key_sent, browser.navigation, browser.interaction, browser.input, notification.opened, notification.jump_requested",
    meaning: "A user or agent did something. These are useful for replay, audit, and making a late observer understand why the UI moved.",
  },
  {
    family: "Agent and sidebar metadata",
    color: palette.pink,
    events: "sidebar.metadata, sidebar.progress, sidebar.log, sidebar.reset, feed.item.resolved, workstream.*",
    meaning: "Long-running agent work is producing status. A conductor artifact can turn this into a readable operations feed.",
  },
  {
    family: "Runtime health",
    color: palette.red,
    events: "config.changed, app.focus_override, app.simulated_active, cmux.heartbeat, errors and failure-shaped payloads",
    meaning: "The shell is changing underneath the user. Keep these visible because they explain confusing focus or routing behavior.",
  },
];

const skillRows = [
  ["cmux", "Route windows, workspaces, panes, surfaces, focus, moves, and flash actions from an agent."],
  ["cmux-workspace", "Stay scoped to the current workspace and avoid targeting the wrong surface."],
  ["cmux-browser", "Drive browser panes, wait for page state, inspect pages, and capture screenshots."],
  ["cmux-artifacts", "Create, open, and edit artifact panes for React, HTML, SVG, Mermaid, code, and downloadable file artifacts."],
  ["cmux-markdown", "Open markdown plans and docs in a formatted live-reload viewer."],
  ["cmux-mochi-conductor", "Inspect visible agent panes, ingest their state, and coordinate work between agents."],
  ["cmux-diagnostics", "Collect hooks, notifications, restore, socket, and CLI diagnostics."],
  ["cmux-dev-workflow", "Build, reload, and launch tagged cmux Mochi dev apps without clobbering the active build."],
  ["cmux-testing", "Run focused Swift and app validation for changed cmux behavior."],
];

const surfaceRows = [
  ["Terminal", "Shell, Codex, Claude, and local command sessions. Text capture comes through terminal-specific ingest paths."],
  ["Browser", "Web pages and app previews. Use browser automation or screenshots when DOM state matters."],
  ["Markdown", "Formatted docs and plans with source text available to artifacts through readSurface."],
  ["File preview", "Readable source files, PDFs, and generated files. Text files can be read; binary files stay open/save wrappers."],
  ["Artifact", "Rendered React, HTML, SVG, Mermaid, code, or file artifact panes. React and HTML run in the sandboxed artifact runtime."],
  ["Custom sidebar", "Workspace-specific sidebars and dashboards built from ExtensionKit or user customization."],
  ["Agent session", "Codex, Claude, and conductor-driven panes that can be observed, resumed, and coordinated."],
];

const apiRows = [
  ["window.cmux.getSnapshot(options)", "Returns visible windows, workspaces, panes, surfaces, focus, and bridge metadata. Use { scope: \"all\" } for release demos."],
  ["window.cmux.eventsSnapshot(options)", "Returns retained event-bus history. Use a limit when rendering inside an artifact."],
  ["window.cmux.subscribe(options, handler)", "Streams live cmux events into the artifact and returns an unsubscribe handle."],
  ["window.cmux.readSurface(options)", "Reads source text for artifact, markdown, and text file-preview surfaces. It is read-only and scoped to visible cmux state."],
  ["window.cmux.call(method, params)", "Low-level escape hatch for bridge methods while keeping the same read-only permission boundary."],
];

function text(value, fallback = "") {
  if (value === null || value === undefined) return fallback;
  return String(value);
}

function shortId(value) {
  const string = text(value);
  return string.length > 8 ? string.slice(0, 8) : string;
}

function formatTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return text(value);
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function isHeartbeat(event) {
  return text(event.type) === "heartbeat";
}

function eventName(event) {
  return isHeartbeat(event) ? "bridge.heartbeat" : text(event.name, "event");
}

function eventCategory(event) {
  return isHeartbeat(event) ? "bridge" : text(event.category, "uncategorized");
}

function eventSource(event) {
  return isHeartbeat(event) ? "window.cmux" : text(event.source, "unknown");
}

function eventKey(event, index) {
  if (event.id) return event.id;
  return [
    text(event.type, "event"),
    text(event.subscription_id, "subscription"),
    text(event.occurred_at, "time"),
    text(event.latest_seq ?? event.seq, index),
    index,
  ].join(":");
}

function eventTone(event) {
  const category = eventCategory(event);
  const name = eventName(event);
  if (isHeartbeat(event)) return palette.green;
  if (category.includes("error") || name.includes("failed") || name.includes("error")) return palette.red;
  if (category.includes("surface")) return palette.cyan;
  if (category.includes("pane") || category.includes("workspace") || category.includes("window")) return palette.green;
  if (category.includes("artifact")) return palette.amber;
  if (category.includes("sidebar") || category.includes("workstream")) return palette.pink;
  return palette.blue;
}

function countSurfaces(snapshot) {
  return (snapshot?.windows || []).reduce((sum, win) => (
    sum + (win.workspaces || []).reduce((workspaceSum, workspace) => (
      workspaceSum + (workspace.panes || []).reduce((paneSum, pane) => paneSum + (pane.surfaces || []).length, 0)
    ), 0)
  ), 0);
}

function countPanes(snapshot) {
  return (snapshot?.windows || []).reduce((sum, win) => (
    sum + (win.workspaces || []).reduce((workspaceSum, workspace) => workspaceSum + (workspace.panes || []).length, 0)
  ), 0);
}

function flattenSurfaces(snapshot) {
  const result = [];
  for (const win of snapshot?.windows || []) {
    for (const workspace of win.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          result.push({
            ...surface,
            windowTitle: `Window ${shortId(win.id)}`,
            workspaceTitle: workspace.title || `Workspace ${shortId(workspace.id)}`,
            paneId: pane.id,
          });
        }
      }
    }
  }
  return result;
}

function Stat({ label, value, accent }) {
  return (
    <div className="card stat-card">
      <div className="eyebrow">{label}</div>
      <div className="stat-value" style={{ color: accent }}>{value}</div>
    </div>
  );
}

function RowCard({ title, detail, color }) {
  return (
    <div className="row-card">
      <div className="row-dot" style={{ background: color || palette.cyan }} />
      <div>
        <strong>{title}</strong>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function EventRow({ event }) {
  const tone = eventTone(event);
  return (
    <div className={`event-row ${isHeartbeat(event) ? "heartbeat" : ""}`}>
      <div className="event-time">{formatTime(event.occurred_at)}</div>
      <div className="event-main">
        <div className="event-name" style={{ color: tone }}>{eventName(event)}</div>
        <div className="event-meta">{eventCategory(event)} from {eventSource(event)}</div>
        {event.payload && Object.keys(event.payload).length > 0 ? (
          <pre className="payload">{JSON.stringify(event.payload, null, 2)}</pre>
        ) : null}
      </div>
      <div className="event-ids">
        <div>{isHeartbeat(event) ? `latest ${text(event.latest_seq, "-")}` : `seq ${text(event.seq, "-")}`}</div>
        <div>ws {shortId(event.workspace_id)}</div>
        <div>surf {shortId(event.surface_id)}</div>
      </div>
    </div>
  );
}

function SurfacePill({ surface, selected, onSelect }) {
  const typeColor = surface.type === "terminal" ? palette.green : surface.type === "browser" ? palette.cyan : surface.type === "artifact" ? palette.amber : palette.blue;
  return (
    <button className={`surface-pill ${selected ? "selected" : ""}`} onClick={() => onSelect(surface)}>
      <span>
        <strong>{text(surface.title, "Surface")}</strong>
        <small>{surface.workspaceTitle} / pane {shortId(surface.paneId)}</small>
      </span>
      <em style={{ color: typeColor }}>{text(surface.type, "surface")}</em>
    </button>
  );
}

function Topology({ snapshot, selectedSurfaceId, onSelectSurface }) {
  const windows = snapshot?.windows || [];
  if (!windows.length) {
    return <div className="empty">No cmux windows are visible to this artifact yet.</div>;
  }
  return (
    <div className="topology">
      {windows.map((win) => (
        <section key={win.id} className="window-card">
          <div className="window-head">
            <strong>Window {shortId(win.id)}</strong>
            <span>{win.is_key ? "key" : "background"}</span>
          </div>
          {(win.workspaces || []).map((workspace) => (
            <div key={workspace.id} className="workspace-card">
              <div className="workspace-head">
                <strong>{workspace.title || `Workspace ${shortId(workspace.id)}`}</strong>
                <span>{workspace.is_selected ? "selected" : shortId(workspace.id)}</span>
              </div>
              {(workspace.panes || []).map((pane) => (
                <div key={pane.id} className="pane-card">
                  <div className="pane-head">Pane {shortId(pane.id)} / {(pane.surfaces || []).length} surfaces</div>
                  <div className="surface-list">
                    {(pane.surfaces || []).map((surface) => (
                      <SurfacePill
                        key={surface.id}
                        surface={{
                          ...surface,
                          workspaceTitle: workspace.title || `Workspace ${shortId(workspace.id)}`,
                          paneId: pane.id,
                        }}
                        selected={selectedSurfaceId === surface.id || selectedSurfaceId === surface.surface_id}
                        onSelect={onSelectSurface}
                      />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}

function EventGuide({ events }) {
  const latest = events.find((event) => !isHeartbeat(event)) || events[0];
  return (
    <div className="page-grid">
      <section className="card wide">
        <div className="eyebrow">Event stream guide</div>
        <h2>What a late observer is seeing</h2>
        <p>
          cmux publishes an append-only stream whenever the visible workspace graph changes or something meaningful happens in a surface.
          Each event is small JSON: sequence number, event name, category, source, timestamp, optional window/workspace/pane/surface ids, and a payload.
          This artifact uses that stream to explain what changed, why the topology moved, and which surface might need a fresh read.
          Heartbeats are separate bridge pulses: they prove the subscription is still live even when no numbered cmux event has happened.
        </p>
      </section>
      <section className="card">
        <h3>Fields to care about</h3>
        <dl className="field-list">
          <dt>seq</dt><dd>Monotonic event order. Use it for replay and catching up after reconnect.</dd>
          <dt>name</dt><dd>The precise action, such as surface.selected or workspace.created.</dd>
          <dt>category</dt><dd>The broad filter bucket used by this artifact.</dd>
          <dt>source</dt><dd>The publisher path: lifecycle, socket, browser, sidebar, artifact runtime, or test.</dd>
          <dt>ids</dt><dd>window_id, workspace_id, pane_id, and surface_id let the UI point to the affected object.</dd>
          <dt>payload</dt><dd>Small structured detail, not a full screen dump.</dd>
        </dl>
      </section>
      <section className="card">
        <h3>Latest event</h3>
        {latest ? <EventRow event={latest} /> : <div className="empty">Waiting for events.</div>}
      </section>
      <section className="card wide">
        <h3>Families</h3>
        <div className="family-grid">
          {eventFamilies.map((item) => (
            <div className="family-card" key={item.family}>
              <strong style={{ color: item.color }}>{item.family}</strong>
              <code>{item.events}</code>
              <p>{item.meaning}</p>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function BridgePage({ selectedSurface, surfaceRead, onReadSurface }) {
  return (
    <div className="page-grid">
      <section className="card wide">
        <div className="eyebrow">Artifact bridge API</div>
        <h2>window.cmux is the V2 bridge</h2>
        <p>
          The artifact runtime injects a read-only cmux bridge into React, HTML, SVG, and Mermaid artifacts.
          The artifact can inspect visible cmux state, subscribe to the event bus, and read source text for safe surface types.
          It cannot send keys, run commands, move panes, or mutate workspace state.
        </p>
      </section>
      <section className="card">
        <h3>Available calls</h3>
        <div className="api-list">
          {apiRows.map(([name, detail]) => (
            <RowCard key={name} title={name} detail={detail} color={name.includes("readSurface") ? palette.amber : palette.cyan} />
          ))}
        </div>
      </section>
      <section className="card">
        <h3>Surface reader</h3>
        <p>
          Select a surface in the topology page, then read it here. Artifact, markdown, and text file-preview surfaces return source text.
          Terminals and browsers return metadata only for now, because their capture path belongs to the conductor ingest pipeline.
        </p>
        <button className="primary-button" onClick={onReadSurface} disabled={!selectedSurface}>
          Read selected surface
        </button>
        <div className="readout">
          <div>{selectedSurface ? `${selectedSurface.title || "Surface"} / ${selectedSurface.type}` : "No surface selected"}</div>
          {surfaceRead ? (
            <pre>{JSON.stringify(surfaceRead, null, 2)}</pre>
          ) : null}
        </div>
      </section>
      <section className="card wide">
        <h3>Why this is enough for V2</h3>
        <p>
          This keeps artifact code portable: generated Claude artifacts remain ordinary React or HTML files, while cmux adds a standard host capability object when they run inside Mochi.
          The same artifact can still open externally; it just loses window.cmux and shows a bridge unavailable state.
        </p>
      </section>
    </div>
  );
}

function ConductorPage() {
  return (
    <div className="page-grid">
      <section className="card wide">
        <div className="eyebrow">Conductor and skills</div>
        <h2>How agents should use the new cmux pieces</h2>
        <p>
          The conductor additions make cmux a workspace an agent can understand, not just a terminal host.
          Agents can identify surfaces, inspect visible work, ingest screenshots or text, make artifacts, open docs, and coordinate other agent panes while staying scoped to the current workspace.
        </p>
      </section>
      <section className="card">
        <h3>Suggested flow</h3>
        <ol className="flow-list">
          <li>Use cmux-workspace to find the caller workspace and avoid global targeting.</li>
          <li>Use cmux or cmux-browser for navigation, focus, and browser-pane proof.</li>
          <li>Use cmux-mochi-conductor when another visible agent pane needs inspection or orchestration.</li>
          <li>Use cmux-artifacts for rich explanations, live dashboards, and generated UI prototypes.</li>
          <li>Use cmux-testing and cmux-dev-workflow before claiming app-side changes are ready.</li>
        </ol>
      </section>
      <section className="card">
        <h3>Skills added or hardened</h3>
        <div className="api-list">
          {skillRows.map(([name, detail]) => <RowCard key={name} title={name} detail={detail} color={palette.green} />)}
        </div>
      </section>
      <section className="card wide">
        <h3>Conductor capability map</h3>
        <div className="family-grid">
          <div className="family-card">
            <strong>Observe</strong>
            <p>Read topology, watch event streams, capture browser screenshots, and summarize visible agent panes.</p>
          </div>
          <div className="family-card">
            <strong>Explain</strong>
            <p>Turn that state into markdown, artifacts, or release demos that a late user can open and understand.</p>
          </div>
          <div className="family-card">
            <strong>Coordinate</strong>
            <p>Route focus, move panes, resume agent sessions, and keep work scoped to a workspace instead of the whole app.</p>
          </div>
          <div className="family-card">
            <strong>Prove</strong>
            <p>Use tests, tagged builds, screenshots, and artifacts as the proof surface for product changes.</p>
          </div>
        </div>
      </section>
    </div>
  );
}

function SurfacesPage() {
  return (
    <div className="page-grid">
      <section className="card wide">
        <div className="eyebrow">Page and pane types</div>
        <h2>The new surface vocabulary</h2>
        <p>
          cmux now treats panes as containers and surfaces as the things inside them. Artifacts are one surface type, not a special side channel.
          That makes it possible to move them, focus them, open their source externally, save them, and include them in the same event stream as terminals and browsers.
        </p>
      </section>
      <section className="card wide">
        <div className="surface-type-grid">
          {surfaceRows.map(([name, detail]) => <RowCard key={name} title={name} detail={detail} color={name === "Artifact" ? palette.amber : palette.blue} />)}
        </div>
      </section>
      <section className="card">
        <h3>Claude artifact compatibility</h3>
        <p>
          React and HTML artifacts are wrapped into a full HTML document by the artifact runtime. The wrapper supplies React imports, styling reset, storage bridge, and window.cmux when the artifact is opened inside cmux.
          SVG and Mermaid render as specialized web documents. Code artifacts render as readable code panes. File artifacts save or open as files instead of pretending to be React.
        </p>
      </section>
      <section className="card">
        <h3>Deliberate gaps</h3>
        <p>
          Binary files such as PDF, DOCX, XLSX, and PPTX are open/save wrappers for now, not embedded Office previewers.
          Terminal and browser full text capture stays in conductor ingest rather than window.cmux.readSurface.
          Live AI calls inside artifacts are intentionally left as a future task.
        </p>
      </section>
    </div>
  );
}

function V3Plan({ snapshot }) {
  const plan = snapshot?.v3_plan || [
    "Native SwiftUI workbench surface with the same bridge contract.",
    "Dedicated log drawers for event bus, control socket commands, and artifact runtime calls.",
    "Timeline replay with persisted event log backfill and per-surface text previews.",
    "Promotion path from prototype artifact to first-party cmux debugging module.",
  ];
  return (
    <div className="page-grid">
      <section className="card wide">
        <div className="eyebrow">V3 native workbench TODO</div>
        <h2>When this graduates from artifact to first-party UI</h2>
        <p>
          The artifact is the prototype and release explainer. Native SwiftUI should only happen when the artifact proves value but hits real limits:
          performance, permissions, background retention, native navigation, or deeper logs that should not be exposed to arbitrary artifact code.
        </p>
      </section>
      <section className="card wide">
        <div className="family-grid">
          {plan.map((item) => (
            <div className="family-card" key={item}>
              <strong>{item}</strong>
              <p>Keep the bridge contract stable so the prototype and native version can share semantics.</p>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function CockpitPage({
  snapshot,
  events,
  filteredEvents,
  filter,
  setFilter,
  status,
  lastUpdate,
  livePulse,
  liveCount,
  selectedSurfaceId,
  onSelectSurface,
  refreshSnapshot,
  error,
}) {
  const categories = useMemo(() => {
    const counts = new Map();
    for (const event of events) {
      const category = eventCategory(event);
      counts.set(category, (counts.get(category) || 0) + 1);
    }
    return Array.from(counts.entries()).sort((a, b) => b[1] - a[1]).slice(0, 8);
  }, [events]);

  return (
    <>
      <section className="stat-grid">
        <Stat label="Status" value={status} accent={status === "Live" ? palette.green : palette.amber} />
        <Stat label="Windows" value={(snapshot?.windows || []).length} accent={palette.cyan} />
        <Stat label="Panes" value={countPanes(snapshot)} accent={palette.green} />
        <Stat label="Surfaces" value={countSurfaces(snapshot)} accent={palette.blue} />
        <Stat label="Latest seq" value={text(snapshot?.event?.latest_seq, "-")} accent={palette.amber} />
        <Stat label="Bridge pulse" value={livePulse || "-"} accent={palette.green} />
      </section>

      {error ? <section className="error-card">{error}</section> : null}

      <main className="workbench-grid">
        <section className="card stream-card">
          <div className="card-head">
            <strong>Event stream</strong>
            <span>{filteredEvents.length} shown / {events.length} retained / {liveCount} live pulses</span>
          </div>
          <div className="filter-row">
            {["all", "bridge", "window", "workspace", "pane", "surface", "artifact", "sidebar"].map((entry) => (
              <button key={entry} className={filter === entry ? "active" : ""} onClick={() => setFilter(entry)}>
                {entry}
              </button>
            ))}
          </div>
          <div className="event-list">
            {filteredEvents.length ? (
              filteredEvents.map((event, index) => <EventRow key={eventKey(event, index)} event={event} />)
            ) : (
              <div className="empty">No retained events match this filter yet.</div>
            )}
          </div>
        </section>

        <aside className="side-stack">
          <section className="card">
            <div className="card-head">
              <strong>Live topology</strong>
              <span>{lastUpdate || "not loaded"}</span>
            </div>
            <Topology snapshot={snapshot} selectedSurfaceId={selectedSurfaceId} onSelectSurface={onSelectSurface} />
          </section>

          <section className="card">
            <h3>Event categories</h3>
            <div className="category-list">
              {categories.length ? categories.map(([category, count]) => (
                <div key={category}>
                  <span>{category}</span>
                  <strong>{count}</strong>
                </div>
              )) : <span className="empty">Waiting for events.</span>}
            </div>
          </section>

          <button className="primary-button" onClick={() => refreshSnapshot().catch(() => {})}>
            Refresh snapshot
          </button>
        </aside>
      </main>
    </>
  );
}

export default function LiveEventsArtifact() {
  const [snapshot, setSnapshot] = useState(null);
  const [events, setEvents] = useState([]);
  const [status, setStatus] = useState("Connecting to cmux artifact bridge");
  const [error, setError] = useState("");
  const [filter, setFilter] = useState("all");
  const [activePage, setActivePage] = useState("cockpit");
  const [lastUpdate, setLastUpdate] = useState("");
  const [livePulse, setLivePulse] = useState("");
  const [liveCount, setLiveCount] = useState(0);
  const [selectedSurface, setSelectedSurface] = useState(null);
  const [surfaceRead, setSurfaceRead] = useState(null);

  async function refreshSnapshot() {
    const next = await window.cmux.getSnapshot({ scope: "all" });
    setSnapshot(next);
    const surfaces = flattenSurfaces(next);
    setSelectedSurface((current) => {
      if (current && surfaces.some((surface) => surface.id === current.id || surface.surface_id === current.surface_id)) {
        return current;
      }
      return surfaces.find((surface) => surface.is_selected) || surfaces[0] || null;
    });
    setLastUpdate(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }));
    return next;
  }

  async function readSelectedSurface() {
    if (!selectedSurface) return;
    setSurfaceRead({ ok: false, status: "Reading..." });
    try {
      const result = await window.cmux.readSurface({ surfaceId: selectedSurface.surface_id || selectedSurface.id });
      setSurfaceRead(result);
    } catch (readError) {
      setSurfaceRead({ ok: false, error: text(readError?.message, "readSurface failed") });
    }
  }

  useEffect(() => {
    let cancelled = false;
    let subscription;

    async function boot() {
      if (!window.cmux) {
        setStatus("cmux bridge unavailable");
        setError("This artifact needs the bundled cmux artifact renderer with window.cmux support.");
        return;
      }

      try {
        setStatus("Loading live cmux snapshot");
        await refreshSnapshot();
        const retained = await window.cmux.eventsSnapshot({ scope: "all", limit: 160 });
        if (!cancelled) {
          setEvents((retained.events || []).slice().reverse());
        }
        subscription = await window.cmux.subscribe({ scope: "all", replayLimit: 40 }, (event) => {
          const pulse = formatTime(event.occurred_at) || new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
          setLivePulse(pulse);
          setLiveCount((count) => count + 1);
          setStatus("Live");
          setEvents((current) => [event, ...current].slice(0, 220));
          const category = eventCategory(event);
          if (category.includes("window") || category.includes("workspace") || category.includes("pane") || category.includes("surface")) {
            refreshSnapshot().catch((refreshError) => setError(text(refreshError?.message, "snapshot refresh failed")));
          }
        });
        if (!cancelled && subscription.replay?.length) {
          setEvents((current) => [...subscription.replay.slice().reverse(), ...current].slice(0, 220));
        }
        if (!cancelled) {
          setStatus("Live");
        }
      } catch (bootError) {
        if (!cancelled) {
          setStatus("Bridge error");
          setError(text(bootError?.message, "Failed to open cmux bridge"));
        }
      }
    }

    boot();
    return () => {
      cancelled = true;
      if (subscription?.unsubscribe) {
        subscription.unsubscribe().catch(() => {});
      }
    };
  }, []);

  const filteredEvents = useMemo(() => {
    if (filter === "all") return events;
    return events.filter((event) => eventCategory(event).includes(filter) || eventName(event).includes(filter));
  }, [events, filter]);

  const pages = [
    ["cockpit", "Live event cockpit"],
    ["events", "Event stream guide"],
    ["bridge", "Artifact bridge API"],
    ["conductor", "Conductor and skills"],
    ["surfaces", "Page types"],
    ["v3", "V3 TODO"],
  ];

  return (
    <div className="shell">
      <style>{`
        * { box-sizing: border-box; }
        button { font: inherit; }
        .shell {
          min-height: 100vh;
          background:
            linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px),
            linear-gradient(0deg, rgba(255,255,255,0.03) 1px, transparent 1px),
            ${palette.bg};
          background-size: 72px 72px;
          color: ${palette.text};
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
          padding: 24px;
        }
        .hero {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          gap: 18px;
          align-items: start;
          margin-bottom: 18px;
        }
        .eyebrow {
          color: ${palette.cyan};
          font-size: 12px;
          font-weight: 800;
          letter-spacing: 0.12em;
          text-transform: uppercase;
        }
        h1, h2, h3, p { margin: 0; }
        h1 { margin-top: 8px; font-size: 46px; line-height: 1.02; letter-spacing: 0; }
        h2 { font-size: 30px; line-height: 1.12; letter-spacing: 0; }
        h3 { font-size: 17px; line-height: 1.2; letter-spacing: 0; }
        p { color: ${palette.muted}; line-height: 1.58; font-size: 15px; }
        .hero p { margin-top: 10px; max-width: 850px; font-size: 16px; }
        .nav {
          display: flex;
          gap: 8px;
          flex-wrap: wrap;
          margin: 18px 0;
        }
        .nav button, .filter-row button, .primary-button {
          border: 1px solid ${palette.border};
          color: ${palette.muted};
          background: ${palette.panel};
          border-radius: 8px;
          padding: 8px 11px;
          cursor: pointer;
        }
        .nav button.active, .filter-row button.active {
          border-color: ${palette.cyan};
          color: ${palette.cyan};
          background: #14252c;
        }
        .primary-button {
          color: ${palette.text};
          border-color: ${palette.borderStrong};
          background: ${palette.panel4};
        }
        .primary-button:disabled {
          opacity: 0.5;
          cursor: default;
        }
        .stat-grid {
          display: grid;
          grid-template-columns: repeat(6, minmax(0, 1fr));
          gap: 10px;
          margin-top: 18px;
        }
        .card {
          border: 1px solid ${palette.border};
          background: rgba(17, 23, 28, 0.96);
          border-radius: 8px;
          padding: 14px;
          min-width: 0;
        }
        .card.wide { grid-column: 1 / -1; }
        .card h2 + p, .card h3 + p { margin-top: 10px; }
        .stat-card { padding: 14px; }
        .stat-value {
          font-size: 26px;
          font-weight: 760;
          margin-top: 5px;
          overflow-wrap: anywhere;
        }
        .workbench-grid {
          display: grid;
          grid-template-columns: minmax(0, 1.18fr) minmax(320px, 0.82fr);
          gap: 14px;
          margin-top: 14px;
        }
        .page-grid {
          display: grid;
          grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
          gap: 14px;
          margin-top: 14px;
        }
        .side-stack { display: grid; gap: 14px; align-content: start; }
        .card-head {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          margin-bottom: 12px;
        }
        .card-head span, .event-time, .event-ids, .empty { color: ${palette.faint}; }
        .filter-row {
          display: flex;
          gap: 8px;
          flex-wrap: wrap;
          margin: -2px 0 12px;
        }
        .event-list {
          display: grid;
          gap: 8px;
          max-height: 680px;
          overflow: auto;
        }
        .event-row {
          display: grid;
          grid-template-columns: 82px minmax(0, 1fr) 126px;
          gap: 10px;
          align-items: start;
          border: 1px solid ${palette.border};
          background: ${palette.panel3};
          border-radius: 8px;
          padding: 10px;
          transition: border-color 160ms ease, background 160ms ease;
        }
        .event-row:hover { border-color: ${palette.cyan}; background: #151f25; }
        .event-row.heartbeat {
          border-color: rgba(96, 211, 156, 0.35);
          background: rgba(15, 30, 23, 0.86);
        }
        .event-name { font-weight: 740; overflow-wrap: anywhere; }
        .event-meta { color: ${palette.muted}; margin-top: 3px; overflow-wrap: anywhere; }
        .event-time, .event-ids {
          font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
          font-variant-numeric: tabular-nums;
        }
        .payload, .readout pre {
          margin: 8px 0 0;
          color: ${palette.muted};
          white-space: pre-wrap;
          overflow-wrap: anywhere;
          font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        .topology, .surface-list, .api-list, .category-list, .surface-type-grid {
          display: grid;
          gap: 8px;
        }
        .window-card, .workspace-card, .pane-card {
          border: 1px solid ${palette.border};
          border-radius: 8px;
          background: ${palette.panel2};
          overflow: hidden;
        }
        .workspace-card, .pane-card { padding: 10px; }
        .window-head, .workspace-head, .pane-head {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          color: ${palette.muted};
        }
        .window-head {
          padding: 10px;
          border-bottom: 1px solid ${palette.border};
        }
        .workspace-card + .workspace-card { margin-top: 8px; }
        .pane-card { margin-top: 8px; border-left: 2px solid ${palette.green}; }
        .surface-pill {
          display: flex;
          justify-content: space-between;
          gap: 8px;
          align-items: center;
          width: 100%;
          text-align: left;
          border: 1px solid ${palette.border};
          color: ${palette.text};
          background: ${palette.panel3};
          border-radius: 8px;
          padding: 9px;
          cursor: pointer;
        }
        .surface-pill.selected { border-color: ${palette.amber}; background: #211d14; }
        .surface-pill strong, .surface-pill small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .surface-pill small { color: ${palette.faint}; margin-top: 3px; }
        .surface-pill em { font-size: 11px; font-style: normal; }
        .row-card {
          display: grid;
          grid-template-columns: 10px minmax(0, 1fr);
          gap: 10px;
          border: 1px solid ${palette.border};
          background: ${palette.panel3};
          border-radius: 8px;
          padding: 10px;
        }
        .row-dot {
          width: 8px;
          height: 8px;
          border-radius: 999px;
          margin-top: 6px;
        }
        .row-card p { margin-top: 4px; font-size: 13px; }
        .family-grid {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: 10px;
          margin-top: 10px;
        }
        .family-card {
          border: 1px solid ${palette.border};
          background: ${palette.panel3};
          border-radius: 8px;
          padding: 12px;
        }
        .family-card code {
          display: block;
          color: ${palette.muted};
          margin-top: 8px;
          font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
          white-space: normal;
          overflow-wrap: anywhere;
        }
        .family-card p { margin-top: 8px; font-size: 13px; }
        .field-list {
          display: grid;
          grid-template-columns: 110px minmax(0, 1fr);
          gap: 8px 12px;
          margin: 10px 0 0;
          color: ${palette.muted};
        }
        .field-list dt { color: ${palette.text}; font-weight: 700; }
        .field-list dd { margin: 0; }
        .flow-list {
          margin: 10px 0 0;
          padding-left: 20px;
          color: ${palette.muted};
          line-height: 1.55;
        }
        .flow-list li { margin-bottom: 7px; }
        .category-list div {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          color: ${palette.muted};
        }
        .category-list strong { color: ${palette.text}; }
        .readout {
          margin-top: 10px;
          border: 1px solid ${palette.border};
          background: ${palette.panel3};
          border-radius: 8px;
          padding: 10px;
          color: ${palette.muted};
        }
        .error-card {
          margin-top: 12px;
          border: 1px solid ${palette.red};
          background: #241316;
          border-radius: 8px;
          padding: 12px;
          color: ${palette.text};
        }
        @media (max-width: 980px) {
          .hero, .workbench-grid, .page-grid { grid-template-columns: 1fr; }
          .stat-grid, .family-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
          .event-row { grid-template-columns: 1fr; }
        }
        @media (max-width: 640px) {
          .shell { padding: 16px; }
          h1 { font-size: 34px; }
          .stat-grid, .family-grid { grid-template-columns: 1fr; }
        }
      `}</style>

      <header className="hero">
        <div>
          <div className="eyebrow">cmux Mochi artifact runtime</div>
          <h1>Artifacts can explain cmux while cmux is running</h1>
          <p>
            A bundled release artifact that proves React artifacts, live events, window.cmux, conductor guidance,
            skills, and new surface types all work together. It is both a cockpit and the handoff page for the artifact feature.
          </p>
        </div>
        <button className="primary-button" onClick={() => refreshSnapshot().catch((refreshError) => setError(text(refreshError?.message, "snapshot refresh failed")))}>
          Refresh
        </button>
      </header>

      <nav className="nav">
        {pages.map(([id, label]) => (
          <button key={id} className={activePage === id ? "active" : ""} onClick={() => setActivePage(id)}>
            {label}
          </button>
        ))}
      </nav>

      {activePage === "cockpit" ? (
        <CockpitPage
          snapshot={snapshot}
          events={events}
          filteredEvents={filteredEvents}
          filter={filter}
          setFilter={setFilter}
          status={status}
          lastUpdate={lastUpdate}
          livePulse={livePulse}
          liveCount={liveCount}
          selectedSurfaceId={selectedSurface?.id || selectedSurface?.surface_id}
          onSelectSurface={(surface) => {
            setSelectedSurface(surface);
            setSurfaceRead(null);
          }}
          refreshSnapshot={refreshSnapshot}
          error={error}
        />
      ) : null}
      {activePage === "events" ? <EventGuide events={events} /> : null}
      {activePage === "bridge" ? (
        <BridgePage
          selectedSurface={selectedSurface}
          surfaceRead={surfaceRead}
          onReadSurface={readSelectedSurface}
        />
      ) : null}
      {activePage === "conductor" ? <ConductorPage /> : null}
      {activePage === "surfaces" ? <SurfacesPage /> : null}
      {activePage === "v3" ? <V3Plan snapshot={snapshot} /> : null}
    </div>
  );
}
