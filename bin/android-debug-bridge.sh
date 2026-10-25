#!/usr/bin/env bash
set -euo pipefail

# android-debug-bridge.sh: CLI tool for AI agents to inspect, tap, screenshot, and debug Android emulator apps.

ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
PACKAGE="${PACKAGE:-app.fitness.demo}"
DEVICE_DUMP=/sdcard/window_dump.xml

if [ ! -x "$ADB" ]; then
  # Fallback to PATH adb if available
  if command -v adb >/dev/null 2>&1; then
    ADB="adb"
  else
    echo "error: adb not found at $ADB" >&2
    exit 1
  fi
fi

state_dir() {
  local dir="$HOME/.local/state/android-debug-bridge"
  mkdir -p -m 700 "$dir"
  echo "$dir"
}

dump_ui() {
  local out="$1" report tmp
  "$ADB" shell rm -f "$DEVICE_DUMP"
  report=$("$ADB" shell uiautomator dump "$DEVICE_DUMP" 2>&1) || true
  tmp=$(mktemp "$out.XXXXXX")
  "$ADB" pull "$DEVICE_DUMP" "$tmp" >/dev/null 2>&1 || true
  "$ADB" shell rm -f "$DEVICE_DUMP"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "error: UI dump failed: $report" >&2
    exit 1
  fi
  mv -f "$tmp" "$out"
}

# Mode "list" prints every match; mode "tap" prints "x y" for exactly one match.
# Exact text/content-desc matches win over substring matches.
ui_find() {
  python3 -I - "$@" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

xml_path, query, mode = sys.argv[1], sys.argv[2], sys.argv[3]
needle = query.lower()
exact = []
partial = []
for node in ET.parse(xml_path).getroot().iter('node'):
    text = node.attrib.get('text', '')
    desc = node.attrib.get('content-desc', '')
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.attrib.get('bounds', ''))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1 or node.attrib.get('visible-to-user') == 'false':
        continue
    el = {
        'text': text,
        'desc': desc,
        'class': node.attrib.get('class', ''),
        'center': ((x1 + x2) // 2, (y1 + y2) // 2),
        'bounds': node.attrib.get('bounds', ''),
    }
    if needle in (text.lower(), desc.lower()):
        exact.append(el)
    elif needle in text.lower() or needle in desc.lower():
        partial.append(el)

matches = []
seen_centers = set()
for el in exact or partial:
    if el['center'] not in seen_centers:
        seen_centers.add(el['center'])
        matches.append(el)
if mode == 'tap':
    if not matches:
        print(f'error: could not find element containing "{query}"', file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f'error: "{query}" matches {len(matches)} elements; use a more specific text or tap <x> <y>', file=sys.stderr)
        for el in matches:
            print(f"  [{el['class']}] text='{el['text']}' desc='{el['desc']}' bounds={el['bounds']}", file=sys.stderr)
        sys.exit(1)
    cx, cy = matches[0]['center']
    print(f'{cx} {cy}')
    sys.exit(0)

if not matches:
    print(f'No elements matching "{query}" found.')
    sys.exit(0)
print(f'Found {len(matches)} matching element(s):')
for idx, el in enumerate(matches, 1):
    cx, cy = el['center']
    print(f"{idx}. [{el['class']}] text='{el['text']}' desc='{el['desc']}' -> Center: ({cx}, {cy}) bounds={el['bounds']}")
PY
}

usage() {
  cat <<EOF
Usage: bin/android-debug-bridge.sh <command> [args...]

Commands:
  devices               List connected devices/emulators
  status                Show currently focused activity and package metadata
  logcat [lines]        Show recent app logs, crash traces, and exceptions
  logcat-clear          Clear logcat buffer
  screenshot [path]     Capture screen and save to PNG (default: ~/.local/state/android-debug-bridge/android-screenshot.png)
  dump-ui [path]        Dump full accessibility UI tree XML (default: ~/.local/state/android-debug-bridge/android-ui.xml)
  find-text <text>      Find text on screen and return its center coordinates
  tap <x> <y>           Tap screen at coordinates
  tap-text <text>       Find element by text/desc and tap its center
  type <text>           Type printable ASCII text into currently focused input
  key <code|name>       Send keyevent (e.g. BACK, HOME, ENTER)
  swipe <x1> <y1> <x2> <y2> [duration]
                        Swipe gesture
  restart               Force stop and launch MainActivity

Environment:
  PACKAGE               Default package name (current: $PACKAGE)
  ADB                   Adb binary path (current: $ADB)
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  devices)
    "$ADB" devices -l
    ;;

  status)
    echo "=== Focused Window ==="
    window=$("$ADB" shell dumpsys window)
    grep -E "mCurrentFocus|mFocusedApp" <<< "$window" || true
    echo "=== Package Info ($PACKAGE) ==="
    package=$("$ADB" shell dumpsys package "$PACKAGE")
    grep -E "versionCode|versionName|lastUpdateTime" <<< "$package" || true
    ;;

  logcat)
    # Dump recent app logs or crash stack traces
    lines="${1:-100}"
    echo "=== Recent logs for $PACKAGE (last $lines lines) ==="
    log=$("$ADB" logcat -d -t "$lines" -v time)
    grep -E "$PACKAGE|AndroidRuntime|FATAL" <<< "$log" || true
    ;;

  logcat-clear)
    "$ADB" logcat -c
    echo "Logcat buffer cleared."
    ;;

  screenshot)
    out="${1:-$(state_dir)/android-screenshot.png}"
    "$ADB" exec-out screencap -p > "$out"
    echo "Screenshot saved to $out"
    ;;

  dump-ui)
    out="${1:-$(state_dir)/android-ui.xml}"
    dump_ui "$out"
    echo "UI hierarchy dumped to $out"
    ;;

  find-text)
    query="${1:-}"
    if [ -z "$query" ]; then
      echo "error: search text required" >&2
      exit 1
    fi
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    dump_ui "$tmp"
    ui_find "$tmp" "$query" list
    ;;

  tap)
    x="${1:-}"
    y="${2:-}"
    if [ -z "$x" ] || [ -z "$y" ]; then
      echo "error: x and y coordinates required" >&2
      exit 1
    fi
    "$ADB" shell input tap "$x" "$y"
    echo "Tapped ($x, $y)"
    ;;

  tap-text)
    query="${1:-}"
    if [ -z "$query" ]; then
      echo "error: text query required" >&2
      exit 1
    fi
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    dump_ui "$tmp"
    coords=$(ui_find "$tmp" "$query" tap)
    read -r tap_x tap_y <<< "$coords"
    "$ADB" shell input tap "$tap_x" "$tap_y"
    echo "Tapped '$query' at ($tap_x, $tap_y)"
    ;;

  type)
    text="${1:-}"
    if [ -z "$text" ]; then
      echo "error: text required" >&2
      exit 1
    fi
    if [ -n "$(printf '%s' "$text" | LC_ALL=C tr -d ' -~')" ]; then
      echo "error: type supports printable ASCII text only" >&2
      exit 1
    fi
    if [[ "$text" == *%s* ]]; then
      echo "error: type cannot send a literal %s sequence" >&2
      exit 1
    fi
    # adb joins arguments into one device-side shell command: escape everything
    # for that shell, and encode spaces as %s, which input text turns back into spaces.
    device_text=""
    for ((i = 0; i < ${#text}; i++)); do
      char="${text:i:1}"
      case "$char" in
        [[:alnum:]]) device_text+="$char" ;;
        " ") device_text+="%s" ;;
        *) device_text+="\\$char" ;;
      esac
    done
    "$ADB" shell input text "$device_text"
    echo "Typed '$text'"
    ;;

  key)
    code="${1:-}"
    if [ -z "$code" ]; then
      echo "error: keycode required (e.g., BACK, HOME, 4, 66)" >&2
      exit 1
    fi
    "$ADB" shell input keyevent "$code"
    echo "Sent key event $code"
    ;;

  swipe)
    x1="${1:-}"
    y1="${2:-}"
    x2="${3:-}"
    y2="${4:-}"
    ms="${5:-300}"
    "$ADB" shell input swipe "$x1" "$y1" "$x2" "$y2" "$ms"
    echo "Swiped ($x1, $y1) -> ($x2, $y2)"
    ;;

  restart)
    echo "Restarting $PACKAGE..."
    "$ADB" shell am force-stop "$PACKAGE"
    "$ADB" shell am start -n "$PACKAGE/.MainActivity"
    ;;

  help)
    usage
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
