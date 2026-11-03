#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
printf '\nCoThink Agent setup installs Pi 0.73.1 in your user directory.\n'
printf 'Node.js 20.6 or newer and npm are required.\n\n'
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  printf 'Node.js and npm were not found. Install Node.js from https://nodejs.org/ and run this setup again.\n'
  read -r -p 'Press Return to close.' _
  exit 1
fi
node_path="$(command -v node)"
if ! "$node_path" -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>20 || (a===20 && b>=6) ? 0 : 1)'; then
  printf 'Node.js 20.6 or newer is required. Update it at https://nodejs.org/ and try again.\n'
  read -r -p 'Press Return to close.' _
  exit 1
fi
prefix="$HOME/.local/share/cothink/pi"
mkdir -p "$prefix"
if ! npm install --prefix "$prefix" --ignore-scripts --no-audit --no-fund @mariozechner/pi-coding-agent@0.73.1; then
  printf '\nPi installation failed. Check the error above and try again.\n'
  read -r -p 'Press Return to close.' _
  exit 1
fi
mkdir -p "$prefix/bin"
printf '#!/bin/bash\nexec %q %q "$@"\n' "$node_path" "$prefix/node_modules/@mariozechner/pi-coding-agent/dist/cli.js" > "$prefix/bin/cothink-pi"
chmod 755 "$prefix/bin/cothink-pi"
printf '\nPi installed. To configure a provider, start Pi and enter /login, then /model.\n'
printf 'For ChatGPT choose OpenAI Codex; for Z.ai choose its API-key provider.\n'
read -r -p 'Open Pi now to log in? [Y/n] ' answer
if [[ ! "$answer" =~ ^[Nn] ]]; then "$prefix/bin/cothink-pi" || true; fi
printf '\nReturn to CoThink chat settings and choose Check again, then Connect.\n'
read -r -p 'Press Return to close.' _
