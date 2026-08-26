#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/mobile-attach-qr.sh [--tag TAG] [--ttl-seconds N] [--out-dir DIR] [--open]
       scripts/mobile-attach-qr.sh --legacy-stack-attach [--route-id ID|--route-kind KIND] [...]

Creates a private QR page. The default is a v3 DeviceLink pairing code minted
by mobile.pairing.code.create. It contains no Stack bearer and must include a
non-loopback Tailscale route. Legacy Stack/Iroh attach is explicit opt-in.
EOF
}

TAG="${CMUX_TAG:-swmob}"
TTL_SECONDS="3600"
ROUTE_ID=""
ROUTE_KIND="iroh"
OUT_DIR=""
OPEN_HTML="0"
LEGACY_STACK_ATTACH="0"
MAX_ATTEMPTS="${CMUX_ATTACH_QR_MAX_ATTEMPTS:-20}"
POLL_INTERVAL_SECONDS="${CMUX_ATTACH_QR_POLL_INTERVAL_SECONDS:-0.5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --ttl-seconds) TTL_SECONDS="${2:-}"; shift 2 ;;
    --legacy-stack-attach) LEGACY_STACK_ATTACH="1"; shift ;;
    --route-id) ROUTE_ID="${2:-}"; ROUTE_KIND=""; shift 2 ;;
    --route-kind) ROUTE_KIND="${2:-}"; ROUTE_ID=""; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --open) OPEN_HTML="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$TTL_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "error: --ttl-seconds must be positive" >&2; exit 2; }
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_ATTACH_QR_MAX_ATTEMPTS must be positive" >&2; exit 2; }
if [[ "$LEGACY_STACK_ATTACH" != "1" && ( -n "$ROUTE_ID" || "$ROUTE_KIND" != "iroh" ) ]]; then
  echo "error: --route-id/--route-kind require --legacy-stack-attach" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"

TMP_ROOT="${TMPDIR:-/tmp}"
OUT_DIR="${OUT_DIR:-${TMP_ROOT%/}/cmux-mobile-pairing-qr-$TAG}"
umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

RAW_JSON="$OUT_DIR/pairing-code.raw.json"
HTML_PATH="$OUT_DIR/index.html"
RAW_JSON_TMP="$(mktemp "$OUT_DIR/pairing-code.raw.json.XXXXXX")"
trap 'rm -f "$RAW_JSON_TMP"' EXIT

READY="0"
for _attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if [[ "$LEGACY_STACK_ATTACH" == "1" ]]; then
    PARAMS="$(TTL_SECONDS="$TTL_SECONDS" ROUTE_ID="$ROUTE_ID" ROUTE_KIND="$ROUTE_KIND" /usr/bin/python3 - <<'PY'
import json
import os
params = {
    "ttl_seconds": int(os.environ["TTL_SECONDS"]),
    "scope": "mac",
    "target": "physical_device",
}
if os.environ.get("ROUTE_ID"):
    params["route_id"] = os.environ["ROUTE_ID"]
elif os.environ.get("ROUTE_KIND"):
    params["route_kind"] = os.environ["ROUTE_KIND"]
print(json.dumps(params, separators=(",", ":")))
PY
    )"
    CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" \
      rpc mobile.attach_ticket.create "$PARAMS" > "$RAW_JSON_TMP" 2>/dev/null || true
  else
    CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" \
      rpc mobile.pairing.code.create "{\"ttl_seconds\":${TTL_SECONDS}}" > "$RAW_JSON_TMP" 2>/dev/null || true
  fi

  if PAIRING_RESPONSE_PATH="$RAW_JSON_TMP" PAIRING_MODE="$LEGACY_STACK_ATTACH" /usr/bin/python3 - <<'PY'
import ipaddress
import json
import os
import urllib.parse

try:
    with open(os.environ["PAIRING_RESPONSE_PATH"], encoding="utf-8") as stream:
        response = json.load(stream)
except (OSError, ValueError):
    raise SystemExit(1)

if os.environ["PAIRING_MODE"] == "1":
    routes = (response.get("ticket") or {}).get("routes") or []
    if not response.get("attach_url") or not any(route.get("kind") == "iroh" for route in routes):
        raise SystemExit(1)
    raise SystemExit(0)

pairing_url = response.get("pairing_url")
if not isinstance(pairing_url, str):
    raise SystemExit(1)
parsed = urllib.parse.urlparse(pairing_url)
query = urllib.parse.parse_qs(parsed.query)
routes = query.get("r", [])
if query.get("v") != ["3"] or not query.get("f") or not query.get("t") or not routes:
    raise SystemExit(1)

def phone_reachable(route: str) -> bool:
    host = route.rsplit(":", 1)[0].strip("[]").lower()
    if host == "localhost":
        return False
    try:
        return not ipaddress.ip_address(host).is_loopback
    except ValueError:
        return True

if not any(phone_reachable(route) for route in routes):
    raise SystemExit(1)
PY
  then
    READY="1"
    break
  fi
  [[ "$_attempt" -ge "$MAX_ATTEMPTS" ]] || sleep "$POLL_INTERVAL_SECONDS"
done

if [[ "$READY" != "1" ]]; then
  if [[ "$LEGACY_STACK_ATTACH" == "1" ]]; then
    echo "error: tagged Mac '$TAG' did not publish the requested legacy Iroh route" >&2
  else
    echo "error: tagged Mac '$TAG' did not publish a phone-reachable v3 DeviceLink/Tailscale code" >&2
  fi
  exit 1
fi

chmod 600 "$RAW_JSON_TMP"
mv "$RAW_JSON_TMP" "$RAW_JSON"

REPO_ROOT="$REPO_ROOT" RAW_JSON="$RAW_JSON" HTML_PATH="$HTML_PATH" \
PAIRING_MODE="$LEGACY_STACK_ATTACH" TTL_SECONDS="$TTL_SECONDS" node --input-type=module <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const payload = JSON.parse(fs.readFileSync(process.env.RAW_JSON, "utf8"));
const legacy = process.env.PAIRING_MODE === "1";
const pairingURL = legacy ? payload.attach_url : payload.pairing_url;
if (typeof pairingURL !== "string" || pairingURL.length === 0) {
  throw new Error("pairing response did not include a URL");
}

const parsed = new URL(pairingURL);
const routes = legacy
  ? (Array.isArray(payload.ticket?.routes) ? payload.ticket.routes.map((route) => ({
      kind: route.kind,
      address: route.endpoint?.type === "host_port"
        ? `${route.endpoint.host}:${route.endpoint.port}`
        : "encrypted peer",
    })) : [])
  : parsed.searchParams.getAll("r").map((address) => ({ kind: "tailscale", address }));

let qrSVG = "";
try {
  const QRCode = require(path.join(process.env.REPO_ROOT, "web", "node_modules", "qrcode"));
  qrSVG = await QRCode.toString(pairingURL, {
    type: "svg", errorCorrectionLevel: "M", margin: 3, width: 1024,
  });
} catch {
  qrSVG = `<pre class="fallback">${escapeHTML(pairingURL)}</pre>`;
}

const routeRows = routes.map((route) =>
  `<tr><td>${escapeHTML(route.kind)}</td><td>${escapeHTML(route.address)}</td></tr>`
).join("");
const mode = legacy ? "Legacy Stack/Iroh compatibility" : "No account · DeviceLink v3 · Tailscale";
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux mobile pairing</title><style>
:root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
body { margin:0; min-height:100vh; display:grid; place-items:center; background:#101111; color:#f5f5f5; }
main { width:min(920px,calc(100vw - 48px)); display:grid; grid-template-columns:minmax(280px,420px) 1fr; gap:32px; align-items:center; }
.qr { padding:24px; background:white; border-radius:18px; } .qr svg { display:block; width:100%; height:auto; }
h1 { margin:0 0 12px; font-size:34px; } p { color:#b8b8b8; font-size:17px; line-height:1.4; }
table { width:100%; border-collapse:collapse; margin-top:24px; } td,th { padding:10px 0; border-bottom:1px solid #343636; text-align:left; }
code,.fallback { overflow-wrap:anywhere; white-space:pre-wrap; font-family:"SF Mono",Menlo,monospace; }
@media(max-width:760px){main{grid-template-columns:1fr;padding:32px 0}}
</style></head><body><main><div class="qr">${qrSVG}</div><section>
<h1>Scan to pair cmux</h1><p>${escapeHTML(mode)}</p>
<p>Open cmux on iPhone, tap <strong>Scan QR Code</strong>, and scan this code.</p>
<table><thead><tr><th>Transport</th><th>Address</th></tr></thead><tbody>${routeRows}</tbody></table>
<p>Code lifetime: ${escapeHTML(process.env.TTL_SECONDS)} seconds.</p>
</section></main></body></html>`;

writePrivate(process.env.HTML_PATH, html);
const report = {
  schema_version: 1,
  mode: legacy ? "legacy_stack_iroh" : "devicelink_v3_tailscale",
  routes,
  ttl_seconds: Number(process.env.TTL_SECONDS),
  contains_stack_bearer: legacy,
};
writePrivate(path.join(path.dirname(process.env.HTML_PATH), "pairing-code.report.json"), JSON.stringify(report, null, 2));
console.log(process.env.HTML_PATH);

function writePrivate(target, contents) {
  const temporary = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, contents, { mode: 0o600 });
  fs.renameSync(temporary, target);
  fs.chmodSync(target, 0o600);
}
function escapeHTML(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}
NODE

if [[ "$OPEN_HTML" == "1" ]]; then
  open -a "Google Chrome" "$HTML_PATH"
fi
