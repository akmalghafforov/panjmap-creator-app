#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

avd="${AVD:-Medium_Phone}"
api="${API_BASE_URL:-http://10.0.2.2:8000/api/v1}"
flutter="${FLUTTER:-flutter}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk" && -f android/local.properties ]]; then
  sdk="$(sed -n 's/^sdk\.dir=//p' android/local.properties | head -n 1)"
fi
sdk="${sdk:-$HOME/Android/Sdk}"
adb="$sdk/platform-tools/adb"
emulator="$sdk/emulator/emulator"
for tool in "$adb" "$emulator"; do
  [[ -x "$tool" ]] || { echo "Android tool missing: $tool. Set ANDROID_HOME." >&2; exit 1; }
done
command -v "$flutter" >/dev/null || { echo "Flutter not found: $flutter" >&2; exit 1; }
"$emulator" -list-avds | tr -d '\r' | grep -Fx -- "$avd" >/dev/null || {
  echo "AVD '$avd' does not exist. Create it in Android Studio Device Manager." >&2
  exit 1
}
"$adb" start-server >/dev/null
find_device() {
  local serial name
  while read -r serial; do
    [[ "$serial" == emulator-* ]] || continue
    name="$(timeout 5 "$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ "$name" == "$avd" ]]; then
      printf '%s\n' "$serial"
      return
    fi
  done < <("$adb" devices | awk 'NR > 1 && $2 == "device" {print $1}')
}
serial="$(find_device)"
if [[ -z "$serial" ]]; then
  log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/panjmap-capture"
  mkdir -p "$log_dir"
  log="$log_dir/emulator.log"
  echo "Starting $avd (emulator log: $log)…"
  nohup "$emulator" -avd "$avd" >"$log" 2>&1 </dev/null &
  emulator_pid=$!
  deadline=$((SECONDS + 180))
  until [[ -n "$serial" ]]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "Emulator exited. Check $log" >&2
      tail -n 20 "$log" >&2
      exit 1
    fi
    (( SECONDS < deadline )) || { echo "Timed out waiting for $avd. Check $log" >&2; exit 1; }
    sleep 2
    serial="$(find_device)"
  done
fi

echo "Waiting for $avd ($serial) to finish booting…"
deadline=$((SECONDS + 180))
until [[ "$(timeout 5 "$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)" == 1 ]]; do
  (( SECONDS < deadline )) || { echo "Android boot timed out on $serial." >&2; exit 1; }
  sleep 2
done
echo "Running Panjmap on $avd; API: $api"
exec "$flutter" run -d "$serial" "--dart-define=API_BASE_URL=$api"
