#!/usr/bin/env bash
# sync-lens.sh - copy the LENS telemetry modules PRISM reports with (lens.metrics, lens.codec) from a LENS
# checkout into lib/prism/lens/. They stay byte-for-byte identical: tests/test_modules.lua compares them
# when the LENS checkout is there. Usage: tools/sync-lens.sh [path to lens]   (default: ../lens)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LENS="${1:-$ROOT/../lens}"
for f in metrics codec; do
  cp "$LENS/lib/lens/$f.lua" "$ROOT/lib/prism/lens/$f.lua"
done
echo "copied lens.metrics and lens.codec from $LENS ($(git -C "$LENS" rev-parse --short HEAD 2>/dev/null || echo "not a git checkout"))"
