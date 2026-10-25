---
name: android-emulator-debugger
description: Real-time Android emulator debugging, UI inspection, touch automation, logcat crash tracing, and visual verification for AI agents.
---

# Android Emulator Debugger Skill

Use this skill when diagnosing, reproducing, testing, or verifying bugs in the Android fitness app (or any Android app) running inside an Android emulator.

## Tool Entrypoint
The primary helper is located at:
`bin/android-debug-bridge.sh`

Default Package: `app.fitness.demo` (override via `PACKAGE="your.pkg.id"`)

## Core Capabilities & Agent Workflow

### 1. Inspect Current State & Activity
```bash
bin/android-debug-bridge.sh status
```
Prints the focused window/activity and package installation timestamp.

### 2. Live UI Tree & Element Discovery
Find elements on screen without guessing coordinates:
```bash
# Find any element by visible text or content-description:
bin/android-debug-bridge.sh find-text "开始训练"

# Dump full UI hierarchy to XML (default: ~/.local/state/android-debug-bridge/android-ui.xml):
bin/android-debug-bridge.sh dump-ui
```

### 3. Drive UI & Reproduce Bugs (Tap, Type, Swipe, Key)
```bash
# Tap by visible text (automatically calculates center coordinates):
bin/android-debug-bridge.sh tap-text "开始训练"

# Tap by exact coordinates:
bin/android-debug-bridge.sh tap 540 1200

# Type printable ASCII text into focused field (non-ASCII such as CJK is rejected):
bin/android-debug-bridge.sh type "squat set 1"

# Send hardware/navigation keys (BACK, HOME, ENTER):
bin/android-debug-bridge.sh key BACK

# Swipe gesture (x1 y1 x2 y2 duration_ms):
bin/android-debug-bridge.sh swipe 540 1800 540 600 300
```

### 4. Capture Logs & Stack Traces (Console)
```bash
# Clear old log buffer before repro:
bin/android-debug-bridge.sh logcat-clear

# Trigger the suspicious action...

# Dump recent app logs and fatal exceptions:
bin/android-debug-bridge.sh logcat 200
```

### 5. Multi-modal Screenshot & Visual Verification
```bash
bin/android-debug-bridge.sh screenshot
```
Captures the current emulator frame for inspection or visual verification. Without a path it saves to `~/.local/state/android-debug-bridge/android-screenshot.png`; the directory is created with mode 0700 because screens can show personal data. Pass a path to choose another location.

### 6. Reset / Restart App
```bash
bin/android-debug-bridge.sh restart
```
Force-stops and re-launches the main Activity.
