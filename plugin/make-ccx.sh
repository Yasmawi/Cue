#!/bin/bash
# Packages Cue Bridge as a .ccx installer (a .ccx is a zip with manifest.json at the root).
set -euo pipefail
cd "$(dirname "$0")"
OUT="../CueBridge.ccx"
rm -f "$OUT"
zip -rqX "$OUT" manifest.json index.html styles.css js icons -x "*.DS_Store"
echo "✓ Created $(cd .. && pwd)/CueBridge.ccx"
