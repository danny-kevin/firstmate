#!/usr/bin/env bash
set -euo pipefail

# android-debug-bridge.sh: CLI tool for AI agents to inspect, tap, screenshot, and debug Android emulator apps.

ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
PACKAGE="${PACKAGE:-app.fitness.demo}"

if [ ! -x "$ADB" ]; then
  # Fallback to PATH adb if available
  if command -v adb >/dev/null 2>&1; then
    ADB="adb"
  else
    echo "error: adb not found at $ADB" >&2
    exit 1
  fi
fi

cmd="${1:-help}"
shift || true

case "$cmd" in
  devices)
    "$ADB" devices -l
    ;;

  status)
    echo "=== Focused Window ==="
    "$ADB" shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp" || true
    echo "=== Package Info ($PACKAGE) ==="
    "$ADB" shell dumpsys package "$PACKAGE" | grep -E "versionCode|versionName|lastUpdateTime" || true
    ;;

  logcat)
    # Dump recent app logs or crash stack traces
    lines="${1:-100}"
    echo "=== Recent logs for $PACKAGE (last $lines lines) ==="
    "$ADB" logcat -d -t "$lines" -v time | grep -E "$PACKAGE|AndroidRuntime|FATAL" || true
    ;;

  logcat-clear)
    "$ADB" logcat -c
    echo "Logcat buffer cleared."
    ;;

  screenshot)
    out="${1:-/tmp/android-screenshot.png}"
    "$ADB" exec-out screencap -p > "$out"
    echo "Screenshot saved to $out"
    ;;

  dump-ui)
    out="${1:-/tmp/android-ui.xml}"
    "$ADB" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1
    "$ADB" pull /sdcard/window_dump.xml "$out" >/dev/null 2>&1
    echo "UI hierarchy dumped to $out"
    ;;

  find-text)
    query="${1:-}"
    if [ -z "$query" ]; then
      echo "error: search text required" >&2
      exit 1
    fi
    tmp="/tmp/android-ui-find.xml"
    "$ADB" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1
    "$ADB" pull /sdcard/window_dump.xml "$tmp" >/dev/null 2>&1
    python3 -c "
import xml.etree.ElementTree as ET
import re, sys

tree = ET.parse('$tmp')
root = tree.getroot()
query = '''$query'''.lower()
found = []

for node in root.iter('node'):
    text = node.attrib.get('text', '')
    desc = node.attrib.get('content-desc', '')
    bounds = node.attrib.get('bounds', '')
    if query in text.lower() or query in desc.lower():
        # parse bounds [x1,y1][x2,y2]
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            cx = (x1 + x2) // 2
            cy = (y1 + y2) // 2
            found.append({
                'text': text,
                'desc': desc,
                'class': node.attrib.get('class', ''),
                'center': (cx, cy),
                'bounds': bounds
            })

if not found:
    print('No elements matching \"$query\" found.')
    sys.exit(0)

print(f'Found {len(found)} matching element(s):')
for idx, el in enumerate(found, 1):
    cx, cy = el['center']
    print(f\"{idx}. [{el['class']}] text='{el['text']}' desc='{el['desc']}' -> Center: ({cx}, {cy}) bounds={el['bounds']}\")
"
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
    tmp="/tmp/android-ui-tap.xml"
    "$ADB" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1
    "$ADB" pull /sdcard/window_dump.xml "$tmp" >/dev/null 2>&1
    coords=$(python3 -c "
import xml.etree.ElementTree as ET
import re, sys

tree = ET.parse('$tmp')
root = tree.getroot()
query = '''$query'''.lower()

for node in root.iter('node'):
    text = node.attrib.get('text', '')
    desc = node.attrib.get('content-desc', '')
    bounds = node.attrib.get('bounds', '')
    if query in text.lower() or query in desc.lower():
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print(f'{(x1 + x2) // 2} {(y1 + y2) // 2}')
            sys.exit(0)
sys.exit(1)
" || true)

    if [ -z "$coords" ]; then
      echo "error: could not find element containing '$query'" >&2
      exit 1
    fi
    # shellcheck disable=SC2086
    "$ADB" shell input tap $coords
    echo "Tapped '$query' at ($coords)"
    ;;

  type)
    text="${1:-}"
    if [ -z "$text" ]; then
      echo "error: text required" >&2
      exit 1
    fi
    "$ADB" shell input text "$text"
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

  *)
    cat <<EOF
Usage: bin/android-debug-bridge.sh <command> [args...]

Commands:
  devices               List connected devices/emulators
  status                Show currently focused activity and package metadata
  logcat [lines]        Show recent app logs, crash traces, and exceptions
  logcat-clear          Clear logcat buffer
  screenshot [path]     Capture screen and save to PNG
  dump-ui [path]        Dump full accessibility UI tree XML
  find-text <text>      Find text on screen and return its center coordinates
  tap <x> <y>           Tap screen at coordinates
  tap-text <text>       Find element by text/desc and tap its center
  type <text>           Type text into currently focused input
  key <code|name>       Send keyevent (e.g. BACK, HOME, ENTER)
  swipe <x1> <y1> <x2> <y2> [duration]
                        Swipe gesture
  restart               Force stop and launch MainActivity

Environment:
  PACKAGE               Default package name (current: $PACKAGE)
  ADB                   Adb binary path (current: $ADB)
EOF
    ;;
esac
