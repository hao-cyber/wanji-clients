#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_root="$repo_root/app/wanji-ios"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/wanji-swift-contracts.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
support_sources=(
  "$ios_root/Wanji/AppSettings.swift"
  "$ios_root/Wanji/KeychainStore.swift"
  "$ios_root/Wanji/AudioContainerDetector.swift"
  "$ios_root/Wanji/MeetingNotesAPI.swift"
  "$ios_root/Wanji/RecordingStore.swift"
)
failures=()

while IFS= read -r script; do
  echo "Running ${script#"$ios_root/"}"
  executable="$build_root/$(basename "$script" .swift)"
  if grep -q '@main' "$script"; then
    if ! (
      cd "$ios_root"
      swiftc -D WANJI_CONTRACT_TESTS -parse-as-library "${support_sources[@]}" "$script" -o "$executable"
      "$executable"
    ); then
      failures+=("${script#"$ios_root/"}")
    fi
  else
    if ! (
      cd "$repo_root"
      swift "$script"
    ); then
      failures+=("${script#"$ios_root/"}")
    fi
  fi
done < <(find "$ios_root/scripts" -maxdepth 1 -type f -name '*_smoke.swift' -print | sort)

if ((${#failures[@]})); then
  printf 'Failed Swift contracts:\n' >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi
