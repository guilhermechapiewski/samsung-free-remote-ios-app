#!/bin/bash
# Captures screenshots of demo mode (fictional TVs only) and exports them to <out>/<device>/.
# <out> is $SCREENSHOTS_DIR, else build/screenshots (git-ignored).
# Needs Xcode with the iOS 27.0 simulator runtime. Usage: [SCREENSHOTS_DIR=dir] scripts/screenshots.sh
set -euo pipefail

cd "$(dirname "$0")/.."
RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
# "device name|device type id" - 6.9" (iPhone 17 Pro Max) and iPhone 17 Pro.
DEVICES=(
  "iPhone 17 Pro Max|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
  "iPhone 17 Pro|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
)
OUT="${SCREENSHOTS_DIR:-build/screenshots}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "error: $*" >&2; exit 1; }

xcrun simctl list runtimes | grep -q "$RUNTIME_ID" \
  || fail "the iOS 27.0 simulator runtime is not installed (install it in Xcode > Settings > Components)."

# Prints the UDID of an available simulator with this name on the iOS 27.0 runtime, creating it if needed.
ensure_device() {
  local name="$1" type="$2" udid
  xcrun simctl list devicetypes | grep -q "$type" \
    || fail "device type '$name' ($type) is not available in this Xcode."
  udid=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name, runtime = sys.argv[1:3]
for d in json.load(sys.stdin)["devices"].get(runtime, []):
    if d["name"] == name and d.get("isAvailable", True):
        print(d["udid"]); raise SystemExit
' "$name" "$RUNTIME_ID")
  if [ -z "$udid" ]; then
    udid=$(xcrun simctl create "$name" "$type" "$RUNTIME_ID") || fail "could not create a '$name' simulator."
  fi
  echo "$udid"
}

mkdir -p "$OUT"
for entry in "${DEVICES[@]}"; do
  name="${entry%%|*}"; type="${entry##*|}"
  slug=$(echo "$name" | tr ' ' '-')
  echo "== $name"
  udid=$(ensure_device "$name" "$type")

  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiMode active --wifiBars 3 --cellularMode notSupported

  bundle="$WORK/$slug.xcresult"
  # TEST_RUNNER_-prefixed variables reach the tests without the prefix; ScreenshotTests skip without it.
  TEST_RUNNER_FREE_REMOTE_SCREENSHOTS=1 xcodebuild test -project FreeRemote.xcodeproj -scheme FreeRemote \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:FreeRemoteUITests/ScreenshotTests \
    -resultBundlePath "$bundle" >"$WORK/$slug.log" 2>&1 \
    || { tail -30 "$WORK/$slug.log" >&2; fail "ScreenshotTests failed on $name."; }

  raw="$WORK/$slug-raw"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw" --filter '*.png' >/dev/null
  dest="$OUT/$slug"
  rm -rf "$dest"; mkdir -p "$dest"
  # Name each file after the attachment ("01-remote" ...), from the export manifest.
  python3 -I - "$raw" "$dest" <<'PY'
import json, os, re, shutil, sys
raw, dest = sys.argv[1:3]
manifest = json.load(open(os.path.join(raw, "manifest.json")))
for test in manifest:
    for a in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", os.path.splitext(a["suggestedHumanReadableName"])[0])
        shutil.copy(os.path.join(raw, a["exportedFileName"]), os.path.join(dest, name + ".png"))
PY
  xcrun simctl status_bar "$udid" clear 2>/dev/null || true # the test run may already have shut it down
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done

echo "== Screenshots"
find "$OUT" -name '*.png' | sort
