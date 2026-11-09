#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="${BUNDLE:-com.haowang.wanji}"
ABILITY="${ABILITY:-EntryAbility}"
HAP="${HAP:-$ROOT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap}"
PACK_INFO="${PACK_INFO:-$ROOT_DIR/entry/build/default/outputs/default/pack.info}"
APP_PACKAGE="${APP_PACKAGE:-$ROOT_DIR/build/outputs/default/harmony-watch-default-unsigned.app}"
EVIDENCE_ROOT="${EVIDENCE_ROOT:-$ROOT_DIR/build/device-evidence}"
WATCH_ADDR="${WATCH_ADDR:-}"

usage() {
  cat <<EOF
Usage: $0 <command> [target]

Commands:
  targets            List hdc targets with verbose status.
  doctor [target]    Print hdc path, server env, target list, and optional TCP probe.
  connect            Run hdc tconn using WATCH_ADDR.
  check [target]     Require a single Online hdc target or the given Online target.
  build              Build the Harmony HAP.
  build-app          Build the AppGallery APP package.
  release-check      Require signing config and a non-unsigned APP package.
  install [target]   Require Online target, then install the current HAP.
  start [target]     Start Wanji on an Online target.
  evidence [target]  Capture package/process/log evidence into build/device-evidence.
  ble-evidence [target]
                     Capture BLE sync-focused evidence and filtered hilog.
  run [target]       build -> install -> start -> evidence.

Environment:
  HDC=/path/to/hdc
  WATCH_ADDR=<your-watch-ip:port>
  BUNDLE=com.haowang.wanji
  ABILITY=EntryAbility
  HAP=/path/to/entry-default-unsigned.hap
  APP_PACKAGE=/path/to/harmony-watch-default-signed.app
  EVIDENCE_ROOT=/path/to/output
EOF
}

hdc_for_target() {
  local target="${1:-}"
  shift || true
  if [[ -n "$target" ]]; then
    "$HDC" -t "$target" "$@"
  else
    "$HDC" "$@"
  fi
}

list_targets() {
  "$HDC" list targets -v
}

online_targets() {
  list_targets 2>/dev/null \
    | tr -d '\r' \
    | awk '
      /^\[Empty\]$/ { next }
      NF == 0 { next }
      /Offline|Unauthorized|unknown|\[Fail\]/ { next }
      { print $1 }
    '
}

target_is_online() {
  local target="$1"
  online_targets | awk -v target="$target" '$1 == target { found = 1 } END { exit found ? 0 : 1 }'
}

require_target() {
  local requested="${1:-}"
  local targets

  if [[ -n "$requested" ]]; then
    if target_is_online "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "Target is not Online via hdc: $requested" >&2
    echo "Current targets:" >&2
    list_targets >&2 || true
    return 1
  fi

  targets="$(online_targets)"
  local count
  count="$(printf '%s\n' "$targets" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$targets"
    return 0
  fi

  if [[ "$count" == "0" ]]; then
    echo "No Online hdc target. Keep the watch awake on Wireless Debugging, run connect, or use DevEco IP Connection." >&2
  else
    echo "Multiple Online hdc targets. Pass one target explicitly." >&2
  fi
  echo "Current targets:" >&2
  list_targets >&2 || true
  return 1
}

print_package_summary() {
  if [[ -f "$PACK_INFO" ]]; then
    echo "Package summary:"
    sed -n '1p' "$PACK_INFO"
  fi
  if [[ -f "$HAP" ]]; then
    ls -lh "$HAP"
  else
    echo "HAP does not exist yet: $HAP" >&2
  fi
}

build_hap() {
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
  export JAVA_HOME="${JAVA_HOME:-/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home}"
  export PATH="$JAVA_HOME/bin:$PATH"
  local node="${N:-/Applications/DevEco-Studio.app/Contents/tools/node/bin/node}"
  local hvigor="${H:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js}"

  cd "$ROOT_DIR"
  "$node" "$hvigor" --mode module -p product=default -p module=entry@default assembleHap
  print_package_summary
}

build_app() {
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
  export JAVA_HOME="${JAVA_HOME:-/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home}"
  export PATH="$JAVA_HOME/bin:$PATH"
  local node="${N:-/Applications/DevEco-Studio.app/Contents/tools/node/bin/node}"
  local hvigor="${H:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js}"

  cd "$ROOT_DIR"
  "$node" "$hvigor" --mode project -p product=default assembleApp
  find "$ROOT_DIR/build/outputs" -maxdepth 3 -type f -name '*.app' -exec ls -lh {} \;
}

release_check() {
  if grep -Eq '"signingConfigs"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$ROOT_DIR/build-profile.json5"; then
    echo "No HarmonyOS signing config. In DevEco Studio open Project Structure > Signing Configs and enable automatic signing." >&2
    return 1
  fi
  build_app
  local candidate="$APP_PACKAGE"
  if [[ ! -f "$candidate" ]]; then
    candidate="$(find "$ROOT_DIR/build/outputs" -maxdepth 3 -type f -name '*.app' ! -name '*unsigned*' | head -1)"
  fi
  if [[ -z "$candidate" || ! -f "$candidate" || "$candidate" == *unsigned* ]]; then
    echo "A signed APP package was not produced. Refusing to mark the release ready." >&2
    return 1
  fi
  echo "Signed AppGallery candidate: $candidate"
  shasum -a 256 "$candidate"
}

connect_watch() {
  if [[ -z "$WATCH_ADDR" ]]; then
    echo "Set WATCH_ADDR to the IP:port shown on the watch Wireless Debugging screen." >&2
    return 2
  fi
  "$HDC" tconn "$WATCH_ADDR"
  list_targets
}

doctor() {
  local target="${1:-}"
  echo "HDC: $HDC"
  "$HDC" -v || true
  echo "HDC_SERVER_PORT: ${HDC_SERVER_PORT:-}"
  echo
  echo "Targets:"
  list_targets || true

  if [[ -n "$WATCH_ADDR" ]]; then
    local host="${WATCH_ADDR%:*}"
    local port="${WATCH_ADDR##*:}"
    echo
    echo "TCP probe: $WATCH_ADDR"
    ping -c 1 -W 1000 "$host" || true
    nc -vz -w 2 "$host" "$port" || true
  fi

  if [[ -n "$target" ]]; then
    echo
    echo "Target package probe: $target"
    hdc_for_target "$target" shell bm dump -n "$BUNDLE" || true
  fi
}

install_hap() {
  local target
  target="$(require_target "${1:-}")"
  if [[ ! -f "$HAP" ]]; then
    echo "HAP not found. Run build first: $HAP" >&2
    return 1
  fi
  print_package_summary
  hdc_for_target "$target" install -r "$HAP"
}

start_app() {
  local target
  target="$(require_target "${1:-}")"
  hdc_for_target "$target" shell aa start -b "$BUNDLE" -a "$ABILITY"
}

capture_evidence() {
  local target
  target="$(require_target "${1:-}")"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local out_dir="$EVIDENCE_ROOT/$stamp"
  mkdir -p "$out_dir"

  {
    echo "timestamp=$stamp"
    echo "target=$target"
    echo "hdc=$HDC"
    echo "HDC_SERVER_PORT=${HDC_SERVER_PORT:-}"
    echo "bundle=$BUNDLE"
    echo "ability=$ABILITY"
    echo "hap=$HAP"
    echo
    print_package_summary
  } >"$out_dir/summary.txt"

  list_targets >"$out_dir/targets.txt" 2>&1 || true
  hdc_for_target "$target" shell bm dump -n "$BUNDLE" >"$out_dir/bm-dump.txt" 2>&1 || true
  hdc_for_target "$target" shell aa dump -l >"$out_dir/aa-dump.txt" 2>&1 || true
  hdc_for_target "$target" shell ps -ef >"$out_dir/ps.txt" 2>&1 || true
  hdc_for_target "$target" shell hidumper -s AbilityManagerService -a -l >"$out_dir/ability-manager.txt" 2>&1 || true
  hdc_for_target "$target" hilog -x -t 2000 >"$out_dir/hilog-tail.txt" 2>&1 || true

  echo "$out_dir"
}

capture_ble_evidence() {
  local target
  target="$(require_target "${1:-}")"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local out_dir="$EVIDENCE_ROOT/ble-$stamp"
  mkdir -p "$out_dir"

  {
    echo "timestamp=$stamp"
    echo "target=$target"
    echo "bundle=$BUNDLE"
    echo "ability=$ABILITY"
    echo
    echo "Expected phone-side TestFlight: Wanji build 16 or newer."
    echo "Expected iPhone UI sequence: 查找手表 -> 连接手表 -> 读取手表服务 -> 唤起手表同步 -> 已通知手表同步."
    echo "Expected watch hilog sequence: watch sync advertiser started -> watch sync command accepted -> 蓝牙传手机/已自动传到手机."
    echo
    print_package_summary
  } >"$out_dir/summary.txt"

  list_targets >"$out_dir/targets.txt" 2>&1 || true
  hdc_for_target "$target" shell bm dump -n "$BUNDLE" >"$out_dir/bm-dump.txt" 2>&1 || true
  hdc_for_target "$target" shell aa dump -l >"$out_dir/aa-dump.txt" 2>&1 || true
  hdc_for_target "$target" shell ps -ef >"$out_dir/ps.txt" 2>&1 || true
  hdc_for_target "$target" hilog -x -t 4000 >"$out_dir/hilog-tail.txt" 2>&1 || true
  LC_ALL=C grep -Ei \
    'watch sync|BluetoothUploader|BLEDeviceFind|startBLEScan|蓝牙|手机腕记|自动传|传到手机|token mismatch|accepted|ERROR|WARN' \
    "$out_dir/hilog-tail.txt" >"$out_dir/hilog-ble-filtered.txt" 2>&1 || true

  echo "$out_dir"
}

cmd="${1:-}"
case "$cmd" in
  targets)
    list_targets
    ;;
  doctor)
    doctor "${2:-}"
    ;;
  connect)
    connect_watch
    ;;
  check)
    require_target "${2:-}" >/dev/null
    ;;
  build)
    build_hap
    ;;
  build-app)
    build_app
    ;;
  release-check)
    release_check
    ;;
  install)
    install_hap "${2:-}"
    ;;
  start)
    start_app "${2:-}"
    ;;
  evidence)
    capture_evidence "${2:-}"
    ;;
  ble-evidence)
    capture_ble_evidence "${2:-}"
    ;;
  run)
    target="$(require_target "${2:-}")"
    build_hap
    install_hap "$target"
    start_app "$target"
    capture_evidence "$target"
    ;;
  "" | -h | --help | help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
