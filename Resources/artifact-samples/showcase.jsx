import React, { useState, useEffect, useRef, useMemo } from "react";
import * as THREE from "three";
import * as d3 from "d3";
import * as math from "mathjs";
import _ from "lodash";
import * as Tone from "tone";
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";
import {
  Boxes, Code2, Database, Sparkles, AudioLines, Component, Library,
  FileSpreadsheet, FileText, Brain, Sigma, Wrench, PencilRuler, TrendingUp,
  Network, Search, Copy, Check, Layers, Cpu, Zap, ArrowDownToLine,
} from "lucide-react";

/* ───────────────────────── design tokens ───────────────────────── */
const C = {
  ink: "#0A0D10",
  panel: "#10151A",
  panel2: "#0D1217",
  line: "#1C242C",
  lineSoft: "#161D24",
  text: "#E8EDF1",
  mute: "#8593A0",
  faint: "#586673",
  mint: "#5BE3C8",     // signature glow
  amber: "#F2A65A",
  peri: "#8AA6F5",
  rose: "#E78AAE",
};

const FONT_CSS = `
@import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap');
* { box-sizing: border-box; }
.cap-root { font-family: 'Space Grotesk', ui-sans-serif, system-ui, sans-serif; }
.mono { font-family: 'JetBrains Mono', ui-monospace, monospace; }
@keyframes spin360 { to { transform: rotate(360deg); } }
@keyframes orbit { to { transform: rotate(360deg); } }
@keyframes pulseGlow {
  0%,100% { opacity: .55; transform: scale(1); }
  50%     { opacity: 1;   transform: scale(1.06); }
}
@keyframes floatY { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-5px); } }
.cap-card { transition: border-color .25s ease, transform .25s ease, box-shadow .25s ease; }
.cap-card:hover { border-color: ${C.line}; transform: translateY(-2px); }
.btn { transition: all .18s ease; cursor: pointer; }
.btn:hover { filter: brightness(1.12); }
.btn:active { transform: translateY(1px); }
.navlink { transition: color .15s ease; }
.navlink:hover { color: ${C.mint} !important; }
::-webkit-scrollbar { height: 8px; width: 8px; }
::-webkit-scrollbar-thumb { background: ${C.line}; border-radius: 8px; }
@media (prefers-reduced-motion: reduce) {
  .spin, .orbitDot, .glowDisc, .floaty { animation: none !important; }
}
`;

/* ───────────────────────── small primitives ───────────────────────── */
function Eyebrow({ children, color = C.mint }) {
  return (
    <div className="mono" style={{
      fontSize: 11, letterSpacing: "0.22em", textTransform: "uppercase",
      color, marginBottom: 14, fontWeight: 600,
    }}>{children}</div>
  );
}

function Panel({ children, style }) {
  return (
    <div className="cap-card" style={{
      background: C.panel, border: `1px solid ${C.lineSoft}`,
      borderRadius: 14, padding: 22, ...style,
    }}>{children}</div>
  );
}

function Section({ id, kicker, title, blurb, children }) {
  return (
    <section id={id} style={{ scrollMarginTop: 76, marginBottom: 64 }}>
      <Eyebrow>{kicker}</Eyebrow>
      <h2 style={{
        margin: "0 0 8px", fontSize: 26, fontWeight: 600, color: C.text,
        letterSpacing: "-0.01em",
      }}>{title}</h2>
      {blurb && <p style={{ margin: "0 0 22px", color: C.mute, maxWidth: 640, lineHeight: 1.55, fontSize: 15 }}>{blurb}</p>}
      {children}
    </section>
  );
}

function Pill({ children, color = C.peri }) {
  return (
    <span className="mono" style={{
      fontSize: 11, color, border: `1px solid ${color}33`,
      background: `${color}10`, padding: "3px 9px", borderRadius: 999, whiteSpace: "nowrap",
    }}>{children}</span>
  );
}

/* ───────────────────────── signature: glowing capability disc ───────────────────────── */
function CapabilityDisc() {
  const nodes = [
    { a: 0, c: C.mint }, { a: 51, c: C.amber }, { a: 102, c: C.peri },
    { a: 153, c: C.rose }, { a: 204, c: C.mint }, { a: 255, c: C.amber }, { a: 306, c: C.peri },
  ];
  return (
    <div style={{ position: "relative", width: 220, height: 220, flexShrink: 0 }}>
      {/* glow disc */}
      <div className="glowDisc" style={{
        position: "absolute", inset: "55px", borderRadius: "50%",
        background: `radial-gradient(circle at 38% 34%, ${C.mint}, ${C.peri}55 55%, transparent 72%)`,
        boxShadow: `0 0 60px ${C.mint}55, 0 0 120px ${C.peri}33`,
        animation: "pulseGlow 4.5s ease-in-out infinite",
      }} />
      {/* rotating ring of nodes */}
      <div className="orbitDot" style={{
        position: "absolute", inset: 0, animation: "orbit 28s linear infinite",
      }}>
        {nodes.map((n, i) => {
          const r = 96, rad = (n.a * Math.PI) / 180;
          const x = 110 + r * Math.cos(rad), y = 110 + r * Math.sin(rad);
          return (
            <div key={i} style={{
              position: "absolute", left: x - 5, top: y - 5, width: 10, height: 10,
              borderRadius: "50%", background: n.c, boxShadow: `0 0 12px ${n.c}`,
            }} />
          );
        })}
      </div>
      {/* hairline ring */}
      <div style={{
        position: "absolute", inset: "14px", borderRadius: "50%",
        border: `1px solid ${C.line}`,
      }} />
    </div>
  );
}

/* ───────────────────────── recharts demo ───────────────────────── */
function RechartsDemo() {
  const data = useMemo(() => {
    let v = 40;
    return Array.from({ length: 24 }, (_, i) => {
      v += (Math.sin(i / 2) * 6) + (Math.random() * 8 - 3);
      return { t: i, load: Math.max(8, Math.round(v)) };
    });
  }, []);
  return (
    <div style={{ height: 180, width: "100%" }}>
      <ResponsiveContainer>
        <AreaChart data={data} margin={{ top: 6, right: 6, left: -22, bottom: 0 }}>
          <defs>
            <linearGradient id="g1" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={C.mint} stopOpacity={0.55} />
              <stop offset="100%" stopColor={C.mint} stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="2 5" stroke={C.line} />
          <XAxis dataKey="t" tick={{ fill: C.faint, fontSize: 10 }} stroke={C.line} />
          <YAxis tick={{ fill: C.faint, fontSize: 10 }} stroke={C.line} />
          <Tooltip contentStyle={{ background: C.ink, border: `1px solid ${C.line}`, borderRadius: 8, color: C.text, fontSize: 12 }} />
          <Area type="monotone" dataKey="load" stroke={C.mint} strokeWidth={2} fill="url(#g1)" />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

/* ───────────────────────── d3 demo (radial burst) ───────────────────────── */
function D3Demo() {
  const ref = useRef(null);
  const [seed, setSeed] = useState(0);
  useEffect(() => {
    const W = 300, H = 180, R = 72;
    const svg = d3.select(ref.current);
    svg.selectAll("*").remove();
    svg.attr("viewBox", `0 0 ${W} ${H}`);
    const g = svg.append("g").attr("transform", `translate(${W / 2},${H / 2})`);
    const n = 30;
    const data = d3.range(n).map((i) => ({ i, v: 14 + Math.abs(Math.sin(i * 0.7 + seed)) * 56 }));
    const angle = d3.scaleLinear().domain([0, n]).range([0, 2 * Math.PI]);
    const color = d3.scaleSequential(d3.interpolateCool).domain([0, n]);
    g.selectAll("line").data(data).join("line")
      .attr("x1", 0).attr("y1", 0)
      .attr("x2", (d) => Math.cos(angle(d.i)) * (R + d.v))
      .attr("y2", (d) => Math.sin(angle(d.i)) * (R + d.v))
      .attr("stroke", (d) => color(d.i)).attr("stroke-width", 2.4).attr("stroke-linecap", "round")
      .attr("opacity", 0).transition().duration(550).delay((d) => d.i * 14).attr("opacity", 0.9);
    g.append("circle").attr("r", R - 4).attr("fill", "none").attr("stroke", C.line).attr("stroke-dasharray", "2 5");
  }, [seed]);
  return (
    <div>
      <svg ref={ref} style={{ width: "100%", height: 180 }} />
      <button className="btn mono" onClick={() => setSeed((s) => s + 1.3)} style={btnStyle}>regenerate ↻</button>
    </div>
  );
}

/* ───────────────────────── three.js demo (r128-safe) ───────────────────────── */
function ThreeDemo() {
  const mount = useRef(null);
  useEffect(() => {
    const el = mount.current;
    const W = el.clientWidth, H = 200;
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(50, W / H, 0.1, 100);
    camera.position.z = 3.2;
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setSize(W, H);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    el.appendChild(renderer.domElement);

    const geo = new THREE.IcosahedronGeometry(1.1, 1);
    const wire = new THREE.LineSegments(
      new THREE.EdgesGeometry(geo),
      new THREE.LineBasicMaterial({ color: 0x5be3c8 })
    );
    const solid = new THREE.Mesh(
      geo,
      new THREE.MeshStandardMaterial({ color: 0x10212a, metalness: 0.4, roughness: 0.3, transparent: true, opacity: 0.55 })
    );
    scene.add(solid); scene.add(wire);
    const key = new THREE.PointLight(0x8aa6f5, 30); key.position.set(3, 3, 4); scene.add(key);
    const fill = new THREE.PointLight(0xf2a65a, 14); fill.position.set(-3, -2, 2); scene.add(fill);
    scene.add(new THREE.AmbientLight(0x223040, 1.2));

    let raf, t = 0, alive = true;
    const loop = () => {
      if (!alive) return;
      t += 0.01;
      solid.rotation.y = wire.rotation.y = t;
      solid.rotation.x = wire.rotation.x = t * 0.6;
      renderer.render(scene, camera);
      raf = requestAnimationFrame(loop);
    };
    loop();
    return () => {
      alive = false; cancelAnimationFrame(raf);
      renderer.dispose(); geo.dispose();
      if (renderer.domElement.parentNode) renderer.domElement.parentNode.removeChild(renderer.domElement);
    };
  }, []);
  return <div ref={mount} style={{ width: "100%", height: 200 }} />;
}

/* ───────────────────────── lodash + mathjs demo ───────────────────────── */
function ComputeDemo() {
  const [expr, setExpr] = useState("sqrt(3^2 + 4^2) + sin(pi/6)");
  let result;
  try { result = math.format(math.evaluate(expr), { precision: 6 }); }
  catch { result = "—  (invalid expression)"; }

  const sample = useMemo(() => _.range(12).map(() => _.random(2, 99)), []);
  const stats = useMemo(() => ({
    sum: _.sum(sample),
    mean: _.round(_.mean(sample), 2),
    max: _.max(sample),
    min: _.min(sample),
    chunks: _.chunk(sample, 4).length,
  }), [sample]);

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div>
        <div className="mono" style={{ fontSize: 11, color: C.faint, marginBottom: 6 }}>mathjs · evaluate()</div>
        <input className="mono" value={expr} onChange={(e) => setExpr(e.target.value)}
          style={{ ...inputStyle }} />
        <div className="mono" style={{ marginTop: 8, color: C.mint, fontSize: 14 }}>= {result}</div>
      </div>
      <div>
        <div className="mono" style={{ fontSize: 11, color: C.faint, marginBottom: 6 }}>lodash · on [{sample.join(", ")}]</div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          {Object.entries(stats).map(([k, v]) => (
            <span key={k} className="mono" style={{
              fontSize: 12, color: C.text, background: C.panel2,
              border: `1px solid ${C.lineSoft}`, padding: "4px 10px", borderRadius: 8,
            }}><span style={{ color: C.amber }}>{k}</span> {v}</span>
          ))}
        </div>
      </div>
    </div>
  );
}

/* ───────────────────────── tone.js demo ───────────────────────── */
function ToneDemo() {
  const synth = useRef(null);
  const [playing, setPlaying] = useState(false);
  async function play() {
    await Tone.start();
    if (!synth.current) synth.current = new Tone.PolySynth(Tone.Synth).toDestination();
    setPlaying(true);
    const now = Tone.now();
    ["C4", "E4", "G4", "B4"].forEach((note, i) => synth.current.triggerAttackRelease(note, "8n", now + i * 0.16));
    setTimeout(() => setPlaying(false), 1100);
  }
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
      <button className="btn" onClick={play} style={{
        ...btnStyle, background: playing ? `${C.amber}22` : C.panel2,
        borderColor: playing ? C.amber : C.line, color: playing ? C.amber : C.text,
        display: "flex", alignItems: "center", gap: 8, padding: "10px 16px",
      }}>
        <AudioLines size={16} /> {playing ? "playing…" : "play a Cmaj7 arpeggio"}
      </button>
      <span className="mono" style={{ fontSize: 11, color: C.faint }}>Web Audio · PolySynth</span>
    </div>
  );
}

/* ───────────────────────── lucide demo ───────────────────────── */
function LucideDemo() {
  const icons = [Boxes, Code2, Database, Sparkles, Component, Library, FileSpreadsheet,
    FileText, Brain, Sigma, Wrench, PencilRuler, TrendingUp, Network, Search, Layers, Cpu, Zap];
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(46px,1fr))", gap: 10 }}>
      {icons.map((Ic, i) => (
        <div key={i} className="floaty" style={{
          display: "grid", placeItems: "center", height: 46, borderRadius: 10,
          background: C.panel2, border: `1px solid ${C.lineSoft}`,
          color: [C.mint, C.amber, C.peri, C.rose][i % 4],
          animation: `floatY ${3 + (i % 5) * 0.4}s ease-in-out ${i * 0.12}s infinite`,
        }}><Ic size={18} /></div>
      ))}
    </div>
  );
}

/* ───────────────────────── Claude API demo ───────────────────────── */
function ClaudeApiDemo() {
  const [prompt, setPrompt] = useState("Write a 2-line haiku about on-device AI.");
  const [out, setOut] = useState("");
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");

  async function run() {
    setLoading(true); setErr(""); setOut("");
    try {
      const res = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: "claude-sonnet-4-6",
          max_tokens: 1000,
          messages: [{ role: "user", content: prompt }],
        }),
      });
      const data = await res.json();
      const text = (data.content || [])
        .filter((b) => b.type === "text").map((b) => b.text).join("\n");
      setOut(text || "(no text returned)");
    } catch (e) {
      setErr("Call failed — this demo only runs live inside the Claude artifact sandbox.");
    } finally { setLoading(false); }
  }

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={2}
        style={{ ...inputStyle, resize: "vertical", lineHeight: 1.5 }} />
      <div>
        <button className="btn" onClick={run} disabled={loading} style={{
          ...btnStyle, display: "inline-flex", alignItems: "center", gap: 8,
          background: C.mint, color: C.ink, borderColor: C.mint, fontWeight: 600,
          opacity: loading ? 0.6 : 1, padding: "10px 18px",
        }}>
          <Sparkles size={15} /> {loading ? "thinking…" : "send to claude-sonnet-4-6"}
        </button>
      </div>
      {(out || err) && (
        <div style={{
          background: C.panel2, border: `1px solid ${err ? C.rose + "55" : C.lineSoft}`,
          borderRadius: 10, padding: 14, color: err ? C.rose : C.text,
          whiteSpace: "pre-wrap", fontSize: 14, lineHeight: 1.55,
        }}>{err || out}</div>
      )}
      <div className="mono" style={{ fontSize: 11, color: C.faint }}>
        fetch → /v1/messages · no API key needed in-sandbox
      </div>
    </div>
  );
}

/* ───────────────────────── storage demo ───────────────────────── */
function StorageDemo() {
  const [note, setNote] = useState("");
  const [saved, setSaved] = useState(null);
  const [status, setStatus] = useState("checking…");
  const KEY = "showcase:note";

  useEffect(() => {
    (async () => {
      if (!window.storage) { setStatus("window.storage not available here"); return; }
      try {
        const r = await window.storage.get(KEY);
        setSaved(r ? r.value : null); setStatus("ready");
      } catch { setSaved(null); setStatus("ready (no note yet)"); }
    })();
  }, []);

  async function save() {
    if (!window.storage) return;
    try {
      await window.storage.set(KEY, note);
      setSaved(note); setStatus("saved ✓ — reopen this artifact and it persists");
    } catch { setStatus("save failed"); }
  }

  return (
    <div style={{ display: "grid", gap: 10 }}>
      <input value={note} onChange={(e) => setNote(e.target.value)}
        placeholder="type a note, save it, reload the artifact…" style={inputStyle} />
      <div>
        <button className="btn mono" onClick={save} style={btnStyle}>window.storage.set()</button>
      </div>
      <div className="mono" style={{ fontSize: 12, color: C.mute }}>
        stored value: <span style={{ color: C.mint }}>{saved === null ? "∅" : `"${saved}"`}</span>
      </div>
      <div className="mono" style={{ fontSize: 11, color: C.faint }}>{status}</div>
    </div>
  );
}

/* ───────────────────────── reference data ───────────────────────── */
const FORMATS = [
  [".jsx", "React", "Hooks, class & functional components"],
  [".html", "HTML", "HTML + CSS + JS, CDN scripts"],
  [".md", "Markdown", "Written content"],
  [".mermaid", "Mermaid", "Diagrams from text"],
  [".svg", "SVG", "Vector graphics"],
  [".pdf", "PDF", "Rendered documents"],
];

const LIBS = [
  ["recharts", "Declarative React charts", C.mint],
  ["chart.js", "Canvas charts", C.mint],
  ["plotly", "Scientific / interactive plots", C.mint],
  ["d3", "Low-level data viz", C.peri],
  ["three (r128)", "3D / WebGL", C.peri],
  ["lucide-react", "Icon set (v0.383)", C.amber],
  ["tone", "Web Audio synthesis", C.amber],
  ["mathjs", "Expressions, units, matrices", C.rose],
  ["lodash", "Utilities", C.rose],
  ["papaparse", "CSV parsing", C.peri],
  ["xlsx (SheetJS)", "Read/write Excel", C.peri],
  ["mammoth", "Read .docx → HTML/text", C.peri],
  ["tensorflow", "In-browser ML", C.amber],
  ["shadcn/ui", "Prebuilt UI components", C.amber],
];

const CONSTRAINTS = [
  ["No localStorage / sessionStorage", "Use React state or window.storage instead"],
  ["No <form> tags in React", "Use onClick / onChange handlers"],
  ["Tailwind arbitrary values unreliable", "No compiler — use inline styles or <style>"],
  ["three.js is r128", "No OrbitControls; avoid CapsuleGeometry (r142+)"],
  ["Single-file preferred", "Keep CSS + JS together"],
];

const MD = `# Claude Artifacts — Capabilities Reference

## Rendering formats
React (.jsx) · HTML (.html) · Markdown (.md) · Mermaid (.mermaid) · SVG (.svg) · PDF (.pdf)

## JS libraries (import directly, no install)
- lucide-react  — import { Camera } from "lucide-react"   (icons, v0.383.0)
- recharts      — import { LineChart, XAxis } from "recharts"
- chart.js      — import * as Chart from "chart.js"
- plotly        — interactive/scientific plots
- d3            — import * as d3 from "d3"
- three         — import * as THREE from "three"   (runtime is r128)
- mathjs        — import * as math from "mathjs"
- lodash        — import _ from "lodash"
- papaparse     — import Papa from "papaparse"   (CSV)
- xlsx (SheetJS)— import * as XLSX from "xlsx"    (Excel)
- mammoth       — import * as mammoth from "mammoth"  (.docx -> html)
- tone          — import * as Tone from "tone"    (Web Audio)
- tensorflow    — tensorflow.js, in-browser ML
- shadcn/ui     — import { Alert } from "@/components/ui/alert"

three.js (r128) caveats: no THREE.OrbitControls; avoid THREE.CapsuleGeometry (needs r142+).

## HTML artifacts + CDN
Import external scripts from https://cdnjs.cloudflare.com (anime.js, GSAP, p5.js, ...).

## Styling
Tailwind core utility classes work (no compiler -> arbitrary [..] values unreliable;
use inline styles or <style>). <style> blocks, CSS vars, keyframes, @import fonts all work.

## Persistent storage (window.storage) — persists across sessions
  await window.storage.set("table:id", JSON.stringify(v));        // personal
  await window.storage.set("lb:alice", JSON.stringify(s), true);  // shared (all users)
  const r = await window.storage.get("table:id");                 // {key,value,shared}|null
  await window.storage.list("table:");                            // {keys,...}
  await window.storage.delete("table:id");
Rules: hierarchical keys "table:id", <200 chars, no whitespace/slashes/quotes; values
text/JSON <5MB; wrap in try/catch (reading a MISSING key THROWS, not null); pass shared
explicitly; last-write-wins.

## Claude API inside artifacts ("Claude in Claude") — no API key needed
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 1000,
      messages: [{ role: "user", content: "..." }],
    }),
  });
  const data = await res.json();
  const text = data.content.filter(b => b.type === "text").map(b => b.text).join("\\n");
- Structured output: instruct "JSON only, no preamble/backticks", strip fences, JSON.parse in try/catch.
- Web search tool:  tools: [{ "type": "web_search_20250305", "name": "web_search" }]
- MCP servers:      mcp_servers: [{ "type": "url", "url": "...", "name": "..." }]
- Files: send PDFs/images as base64 with correct media_type (document / image content blocks).
- Stateless: resend full messages[] history each call.

## Constraints
- No localStorage / sessionStorage / IndexedDB / cookies — use React state or window.storage.
- No <form> tags in React artifacts — use onClick/onChange.
- Tailwind arbitrary values unreliable (no compiler).
- three.js r128 caveats (above).
- React: base React + hooks; default export; provide prop defaults.
`;

/* ───────────────────────── shared inline styles ───────────────────────── */
const btnStyle = {
  background: C.panel2, color: C.text, border: `1px solid ${C.line}`,
  borderRadius: 9, padding: "8px 14px", fontSize: 12,
};
const inputStyle = {
  width: "100%", background: C.ink, color: C.text, border: `1px solid ${C.line}`,
  borderRadius: 9, padding: "10px 12px", fontSize: 13, outline: "none",
  fontFamily: "'JetBrains Mono', monospace",
};

/* ───────────────────────── main component ───────────────────────── */
export default function App() {
  const [copied, setCopied] = useState(false);
  function copyMd() {
    navigator.clipboard?.writeText(MD).then(() => {
      setCopied(true); setTimeout(() => setCopied(false), 1800);
    });
  }
  const nav = [
    ["formats", "Formats"], ["viz", "Visualization"], ["compute", "Compute & audio"],
    ["ai", "Claude API"], ["storage", "Storage"], ["libs", "All libraries"],
    ["limits", "Constraints"], ["md", "Copy .md"],
  ];

  return (
    <div className="cap-root" style={{ background: C.ink, color: C.text, minHeight: "100vh" }}>
      <style>{FONT_CSS}</style>

      {/* sticky nav */}
      <nav style={{
        position: "sticky", top: 0, zIndex: 20, background: `${C.ink}E8`,
        backdropFilter: "blur(10px)", borderBottom: `1px solid ${C.lineSoft}`,
        padding: "12px 22px", display: "flex", gap: 18, alignItems: "center", flexWrap: "wrap",
      }}>
        <span className="mono" style={{ color: C.mint, fontWeight: 600, fontSize: 13, letterSpacing: "0.04em" }}>
          ◖ artifact.runtime
        </span>
        <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
          {nav.map(([id, label]) => (
            <a key={id} href={`#${id}`} className="navlink mono"
              style={{ color: C.mute, fontSize: 12, textDecoration: "none" }}>{label}</a>
          ))}
        </div>
      </nav>

      <div style={{ maxWidth: 880, margin: "0 auto", padding: "46px 22px 90px" }}>

        {/* hero */}
        <header style={{
          display: "flex", gap: 36, alignItems: "center", flexWrap: "wrap",
          marginBottom: 64, justifyContent: "space-between",
        }}>
          <div style={{ flex: "1 1 360px" }}>
            <Eyebrow>what runs inside the sandbox</Eyebrow>
            <h1 style={{
              margin: "0 0 16px", fontSize: 40, lineHeight: 1.05, fontWeight: 600,
              letterSpacing: "-0.02em", color: C.text,
            }}>
              Everything an artifact<br />
              <span style={{ color: C.mint }}>can reach for.</span>
            </h1>
            <p style={{ margin: 0, color: C.mute, maxWidth: 460, lineHeight: 1.6, fontSize: 16 }}>
              A live tour of the libraries, web tech, persistent storage, and the in-sandbox
              Claude API available when I render a React/HTML artifact. Each panel below is the
              real library doing the real thing — not a screenshot.
            </p>
            <div style={{ display: "flex", gap: 8, marginTop: 22, flexWrap: "wrap" }}>
              <Pill color={C.mint}>14 JS libraries</Pill>
              <Pill color={C.amber}>6 render formats</Pill>
              <Pill color={C.peri}>window.storage</Pill>
              <Pill color={C.rose}>Claude API</Pill>
            </div>
          </div>
          <CapabilityDisc />
        </header>

        {/* formats */}
        <Section id="formats" kicker="01 · render targets" title="File formats that render"
          blurb="Save an artifact with one of these extensions and the UI renders it specially.">
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(165px,1fr))", gap: 12 }}>
            {FORMATS.map(([ext, name, desc]) => (
              <Panel key={ext} style={{ padding: 16 }}>
                <div className="mono" style={{ color: C.mint, fontSize: 13, marginBottom: 4 }}>{ext}</div>
                <div style={{ fontWeight: 600, fontSize: 14, marginBottom: 4 }}>{name}</div>
                <div style={{ color: C.mute, fontSize: 12, lineHeight: 1.4 }}>{desc}</div>
              </Panel>
            ))}
          </div>
        </Section>

        {/* visualization */}
        <Section id="viz" kicker="02 · visualization" title="Charts, data viz & 3D — live"
          blurb="recharts, d3, and three.js are all importable directly. Below they're running for real.">
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(260px,1fr))", gap: 16 }}>
            <Panel>
              <div style={demoHead}><TrendingUp size={15} color={C.mint} /> recharts</div>
              <RechartsDemo />
            </Panel>
            <Panel>
              <div style={demoHead}><Network size={15} color={C.peri} /> d3</div>
              <D3Demo />
            </Panel>
            <Panel style={{ gridColumn: "1 / -1" }}>
              <div style={demoHead}><Boxes size={15} color={C.peri} /> three.js <span className="mono" style={{ color: C.faint, fontSize: 11 }}>· r128 · wireframe icosahedron</span></div>
              <ThreeDemo />
            </Panel>
          </div>
        </Section>

        {/* compute & audio */}
        <Section id="compute" kicker="03 · compute & audio" title="Math, utilities, icons & sound"
          blurb="mathjs and lodash crunch on the client; tone.js drives Web Audio; lucide-react ships the icon set this whole page uses.">
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(260px,1fr))", gap: 16 }}>
            <Panel>
              <div style={demoHead}><Sigma size={15} color={C.rose} /> mathjs + lodash</div>
              <ComputeDemo />
            </Panel>
            <Panel>
              <div style={demoHead}><AudioLines size={15} color={C.amber} /> tone.js</div>
              <ToneDemo />
              <div style={{ marginTop: 20, ...demoHead }}><Sparkles size={15} color={C.amber} /> lucide-react</div>
              <LucideDemo />
            </Panel>
          </div>
        </Section>

        {/* AI */}
        <Section id="ai" kicker="04 · claude in claude" title="Call the Anthropic API — no key"
          blurb="Artifacts can POST to /v1/messages with auth handled by the runtime. Type a prompt and send it to claude-sonnet-4-6 live.">
          <Panel style={{ borderColor: `${C.mint}33` }}>
            <ClaudeApiDemo />
          </Panel>
        </Section>

        {/* storage */}
        <Section id="storage" kicker="05 · persistence" title="window.storage — survives reloads"
          blurb="The one storage that works (localStorage does not). Personal or shared key–value, persisting across sessions.">
          <Panel>
            <StorageDemo />
          </Panel>
        </Section>

        {/* all libs */}
        <Section id="libs" kicker="06 · the full set" title="All importable libraries"
          blurb="Importable directly in React artifacts — no install step, versions pinned by the runtime.">
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(220px,1fr))", gap: 10 }}>
            {LIBS.map(([name, desc, col]) => (
              <div key={name} style={{
                display: "flex", gap: 10, alignItems: "flex-start",
                background: C.panel, border: `1px solid ${C.lineSoft}`, borderRadius: 10, padding: "11px 13px",
              }}>
                <span style={{ width: 7, height: 7, borderRadius: "50%", background: col, marginTop: 6, flexShrink: 0, boxShadow: `0 0 8px ${col}` }} />
                <div>
                  <div className="mono" style={{ fontSize: 12.5, color: C.text }}>{name}</div>
                  <div style={{ fontSize: 11.5, color: C.mute, marginTop: 2 }}>{desc}</div>
                </div>
              </div>
            ))}
          </div>
          <p className="mono" style={{ color: C.faint, fontSize: 12, marginTop: 16 }}>
            + HTML artifacts can pull any script from cdnjs.cloudflare.com (GSAP, p5.js, anime.js…)
          </p>
        </Section>

        {/* constraints */}
        <Section id="limits" kicker="07 · know the edges" title="Constraints & gotchas"
          blurb="The sharp corners worth remembering before you build.">
          <div style={{ display: "grid", gap: 10 }}>
            {CONSTRAINTS.map(([t, d]) => (
              <div key={t} style={{
                display: "flex", gap: 14, alignItems: "baseline",
                background: C.panel, border: `1px solid ${C.lineSoft}`,
                borderLeft: `3px solid ${C.amber}`, borderRadius: 10, padding: "13px 16px",
              }}>
                <span style={{ fontWeight: 600, fontSize: 14, color: C.text, flex: "0 0 240px" }}>{t}</span>
                <span style={{ color: C.mute, fontSize: 13 }}>{d}</span>
              </div>
            ))}
          </div>
        </Section>

        {/* copy md */}
        <Section id="md" kicker="08 · take it with you" title="Copy the whole reference"
          blurb="The same information as a plain-text Markdown block — grab it for your notes or a README.">
          <Panel style={{ borderColor: `${C.mint}33` }}>
            <div style={{ display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap", marginBottom: 14 }}>
              <button className="btn" onClick={copyMd} style={{
                ...btnStyle, display: "inline-flex", alignItems: "center", gap: 8,
                background: copied ? `${C.mint}22` : C.mint, color: copied ? C.mint : C.ink,
                borderColor: C.mint, fontWeight: 600, padding: "10px 18px", fontSize: 13,
              }}>
                {copied ? <Check size={15} /> : <Copy size={15} />}
                {copied ? "copied to clipboard" : "copy reference as Markdown"}
              </button>
              <span className="mono" style={{ fontSize: 11, color: C.faint, display: "inline-flex", gap: 6, alignItems: "center" }}>
                <ArrowDownToLine size={13} /> a .md file is also attached to this message
              </span>
            </div>
            <pre className="mono" style={{
              margin: 0, maxHeight: 280, overflow: "auto", background: C.ink,
              border: `1px solid ${C.lineSoft}`, borderRadius: 10, padding: 16,
              fontSize: 11.5, lineHeight: 1.55, color: C.mute, whiteSpace: "pre-wrap",
            }}>{MD}</pre>
          </Panel>
        </Section>

        <footer className="mono" style={{ color: C.faint, fontSize: 11, textAlign: "center", paddingTop: 20, borderTop: `1px solid ${C.lineSoft}` }}>
          rendered inside the artifact sandbox · every panel above is a live library
        </footer>
      </div>
    </div>
  );
}

const demoHead = {
  display: "flex", alignItems: "center", gap: 8, fontSize: 13, fontWeight: 600,
  color: C.text, marginBottom: 14,
};
