#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/Scripts/package_app.sh" "${1:-debug}"
open "$ROOT/build/MacSCP.app"
