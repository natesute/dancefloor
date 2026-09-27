#!/bin/bash
# Builds build/Dancefloor.app. Signs with your Apple Development identity if present so the
# audio-capture permission survives rebuilds (ad-hoc signatures re-prompt every build).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Dancefloor
APP=build/Dancefloor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dancefloor "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
