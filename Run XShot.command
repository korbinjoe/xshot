#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
"$PROJECT_DIR/scripts/build.sh"
open "$PROJECT_DIR/dist/XShot.app"
