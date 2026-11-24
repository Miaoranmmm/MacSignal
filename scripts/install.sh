#!/bin/bash
# Builds MacSignal, replaces /Applications/MacSignal.app and starts it. The agents' hooks run the
# app at the path it starts from, so install before launching it.
set -euo pipefail
cd "$(dirname "$0")/.."

# A fixed certificate keeps Accessibility and Bluetooth access across rebuilds: MACSIGNAL_SIGN_IDENTITY, else
# "MacSignal Local Signing" when the keychain has it, else ad hoc.
if [ -z "${MACSIGNAL_SIGN_IDENTITY:-}" ] && security find-certificate -c "MacSignal Local Signing" >/dev/null 2>&1; then
    export MACSIGNAL_SIGN_IDENTITY="MacSignal Local Signing"
fi
scripts/build.sh

target=/Applications/MacSignal.app
# Only one copy runs at a time (a second one exits at launch): quit the running one and wait.
osascript -e 'quit app id "local.macsignal.app"' >/dev/null 2>&1 || true
for _ in $(seq 50); do
    pgrep -qf 'MacSignal.app/Contents/MacOS/MacSignal$' || break
    sleep 0.1
done
if pgrep -qf 'MacSignal.app/Contents/MacOS/MacSignal$'; then
    echo "MacSignal is still running; quit it from its menu and run this again." >&2
    exit 1
fi

rm -rf "$target"
ditto build/MacSignal.app "$target"
open "$target"
printf 'Installed and started: %s\n' "$target"
