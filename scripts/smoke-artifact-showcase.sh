#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TAG="${CMUX_TAG:-artifacts}"

run_cmux() {
  CMUX_TAG="$TAG" "$PROJECT_DIR/scripts/cmux-debug-cli.sh" "$@"
}

echo "==> checking tagged cmux socket (tag: $TAG)"
run_cmux capabilities --json >/dev/null

echo "==> creating showcase artifact"
create_output="$(run_cmux artifact new --template showcase)"
echo "$create_output"
surface_ref="$(printf '%s\n' "$create_output" | sed -n 's/^OK surface=\([^ ]*\).*/\1/p')"
if [[ -z "$surface_ref" ]]; then
  echo "error: could not parse surface ref from artifact command output" >&2
  exit 1
fi

echo "==> waiting for rendered artifact text ($surface_ref)"
rendered_text=""
for _ in {1..40}; do
  rendered_text="$(run_cmux surface text --surface "$surface_ref" --mode rendered || true)"
  if [[ "$rendered_text" == *"File formats that render"* && "$rendered_text" == *"recharts"* ]]; then
    break
  fi
  sleep 0.5
done

if [[ "$rendered_text" == *"Artifact render failed"* ]]; then
  echo "error: showcase rendered error card" >&2
  printf '%s\n' "$rendered_text" >&2
  exit 1
fi
if [[ "$rendered_text" != *"File formats that render"* || "$rendered_text" != *"recharts"* ]]; then
  echo "error: showcase did not expose expected rendered text" >&2
  printf '%s\n' "$rendered_text" | sed -n '1,80p' >&2
  exit 1
fi

echo "==> ingesting showcase surface"
ingest_json="$(run_cmux surface ingest --surface "$surface_ref" --mode rendered --json)"

python3 - "$rendered_text" "$ingest_json" <<'PY'
import json
import os
import sys

rendered_text = sys.argv[1]
payload = json.loads(sys.argv[2])
ingest_text = ((payload.get("text") or {}).get("text")) or ""
if "Artifact render failed" in ingest_text:
    raise SystemExit("error: ingest text contains render failure")
for needle in ("File formats that render", "recharts"):
    if needle not in rendered_text:
        raise SystemExit(f"error: rendered text missing {needle!r}")
if "recharts" not in ingest_text:
    raise SystemExit("error: ingest text missing visible rendered content")

screenshot = payload.get("screenshot") or {}
for key in ("width", "height", "byte_count"):
    value = screenshot.get(key)
    if not isinstance(value, int) or value <= 0:
        raise SystemExit(f"error: screenshot {key} is not positive: {value!r}")

audit = payload.get("audit") or {}
for key in ("image_path", "text_path", "manifest_path"):
    path = audit.get(key)
    if not path or not os.path.exists(path):
        raise SystemExit(f"error: audit {key} missing on disk: {path!r}")

print(json.dumps({
    "surface": payload.get("surface_ref"),
    "capture_id": audit.get("capture_id"),
    "image": {
        "format": screenshot.get("format"),
        "width": screenshot.get("width"),
        "height": screenshot.get("height"),
        "bytes": screenshot.get("byte_count"),
    },
    "text_chars": len(rendered_text),
    "ingest_text_chars": len(ingest_text),
    "manifest_path": audit.get("manifest_path"),
}, sort_keys=True))
PY
