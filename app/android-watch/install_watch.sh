#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$TARGET" || "$TARGET" == "--help" || "$TARGET" == "-h" ]]; then
  echo "Usage: $0 <device-serial-or-ip:port>"
  echo "Builds and installs a debug APK on the explicitly selected device."
  [[ -n "$TARGET" ]] && exit 0
  exit 2
fi
ADB="${ADB:-$(command -v adb || true)}"
if [[ -z "$ADB" && -n "${ANDROID_HOME:-}" ]]; then
  ADB="$ANDROID_HOME/platform-tools/adb"
fi
ADB_CONNECT_TIMEOUT_SECONDS="${ADB_CONNECT_TIMEOUT_SECONDS:-12}"
APK="$ROOT/app/build/outputs/apk/debug/app-debug.apk"
GRADLE="$ROOT/gradlew"

if [[ ! -x "$ADB" ]]; then
  echo "adb not found: $ADB" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ROOT/scripts/adb_helpers.sh"

"$GRADLE" -p "$ROOT" :app:assembleDebug

INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wanji-install.XXXXXX")"
trap 'rm -rf "$INSTALL_TMP"' EXIT
ADB_DEVICES_SNAPSHOT="$INSTALL_TMP/adb-devices.txt"
adb_devices_with_timeout "$ADB" "$ADB_CONNECT_TIMEOUT_SECONDS" "$ADB_DEVICES_SNAPSHOT" || true
if awk -v target="$TARGET" '$1 == target && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }' "$ADB_DEVICES_SNAPSHOT"; then
  echo "device already online: $TARGET"
elif [[ "$TARGET" == *:* ]]; then
  adb_connect_with_timeout "$ADB" "$TARGET" "$ADB_CONNECT_TIMEOUT_SECONDS" /dev/stdout || true
fi
state="$(adb_get_state_with_timeout "$ADB" "$TARGET" "$ADB_CONNECT_TIMEOUT_SECONDS" 2>"$INSTALL_TMP/adb-state.err" || true)"
if [[ "$state" != "device" ]]; then
  echo "device is not online: ${state:-unknown}" >&2
  cat "$ADB_DEVICES_SNAPSHOT" >&2
  cat "$INSTALL_TMP/adb-state.err" >&2
  exit 3
fi
"$ADB" -s "$TARGET" install -r -g "$APK"
"$ADB" -s "$TARGET" shell am force-stop com.haowang.wristnote
"$ADB" -s "$TARGET" shell am start \
  -a com.haowang.wristnote.action.SHOW_DIAL \
  -n com.haowang.wristnote/.MainActivity
"$ADB" -s "$TARGET" shell pidof com.haowang.wristnote || true
