#!/usr/bin/env bash

adb_connect_with_timeout() {
  local adb="$1"
  local device="$2"
  local timeout_s="$3"
  local out="$4"
  python3 - "$adb" "$device" "$timeout_s" > "$out" 2>&1 <<'PY'
import subprocess
import sys

adb, device, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    proc = subprocess.run(
        [adb, "connect", device],
        text=True,
        capture_output=True,
        timeout=timeout_s,
        check=False,
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace"))
    if exc.stderr:
        sys.stderr.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "replace"))
    print(f"adb connect timed out after {timeout_s:g}s for {device}", file=sys.stderr)
    raise SystemExit(124)
PY
}

adb_get_state_with_timeout() {
  local adb="$1"
  local device="$2"
  local timeout_s="$3"
  python3 - "$adb" "$device" "$timeout_s" <<'PY'
import subprocess
import sys

adb, device, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    proc = subprocess.run(
        [adb, "-s", device, "get-state"],
        text=True,
        capture_output=True,
        timeout=timeout_s,
        check=False,
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace"))
    if exc.stderr:
        sys.stderr.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "replace"))
    print(f"adb get-state timed out after {timeout_s:g}s for {device}", file=sys.stderr)
    raise SystemExit(124)
PY
}

adb_devices_with_timeout() {
  local adb="$1"
  local timeout_s="$2"
  local out="$3"
  python3 - "$adb" "$timeout_s" > "$out" 2>&1 <<'PY'
import subprocess
import sys

adb, timeout_s = sys.argv[1], float(sys.argv[2])
try:
    proc = subprocess.run(
        [adb, "devices", "-l"],
        text=True,
        capture_output=True,
        timeout=timeout_s,
        check=False,
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace"))
    if exc.stderr:
        sys.stderr.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "replace"))
    print(f"adb devices -l timed out after {timeout_s:g}s", file=sys.stderr)
    raise SystemExit(124)
PY
}
