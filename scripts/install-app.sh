#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
ditto "dist/CoThink Board.app" "$HOME/Applications/CoThink Board.app"
printf 'Installed CoThink Board to %s/Applications.\n' "$HOME"
read -r -p 'Set up Pi for agent chat now? [y/N] ' answer
if [[ "$answer" =~ ^[Yy] ]]; then ./scripts/install-pi.command; fi
