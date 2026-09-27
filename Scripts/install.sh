#!/bin/bash
# Builds Dancefloor, replaces /Applications/Dancefloor.app and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh
pkill -x Dancefloor || true
sleep 1
rm -rf /Applications/Dancefloor.app
cp -R build/Dancefloor.app /Applications/
open /Applications/Dancefloor.app
echo "Installed /Applications/Dancefloor.app"
