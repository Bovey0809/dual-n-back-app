# DualNBack — Native macOS App (Swift)

Native Swift/SwiftUI port of the Electron dual n-back app, including the full
daily boot training lock. No Node, no Electron — a single ~5 MB .app.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (the project uses buildable folders)

## Build & Run

1. Open `macos/DualNBack.xcodeproj` in Xcode.
2. Press ⌘R.

The project is preconfigured with ad-hoc signing (`Sign to Run Locally`), so it
builds without a developer team. To distribute, select the DualNBack target →
Signing & Capabilities and pick your team.

Command line:

```bash
cd macos
xcodebuild -project DualNBack.xcodeproj -scheme DualNBack -configuration Release build
```

## Important: install location and the boot lock

The 开机锁 toggle writes `~/Library/LaunchAgents/com.dualnback.lock.plist`
pointing at the app binary **at its current location**. If you enable it while
running from Xcode's DerivedData, the LaunchAgent will point there. For real
use:

1. Build Release (Product → Archive, or `xcodebuild` above).
2. Copy `DualNBack.app` to `/Applications`.
3. Launch it from `/Applications` and enable 开机锁 from there.

If you move the app later, toggle 开机锁 off and on again to rewrite the plist.

## Feature parity with the Electron version

- Dual n-back game: 3×3 grid, spoken letters (C H K L Q R S T) via
  AVSpeechSynthesizer, A / L / Space shortcuts, feedback tones (synthesized
  with AVAudioEngine), auto-leveling (≥80% up, <60% down, after N+15 rounds),
  session timer, training records (last 50, stored in
  `~/Library/Application Support/DualNBack/records.json`).
- Daily boot lock: LaunchAgent (`com.dualnback.lock`, RunAtLoad + KeepAlive),
  fullscreen kiosk on the primary display with blackout windows on other
  displays, 20 min/day quota, idle >90 s pauses the clock, progress persisted
  every 5 s to `lock-state.json`, crash-loop fail-open (5 launches in 5 min →
  1 h degraded mode), emergency skip (pledge sentence + 60 s wait, 2 per
  rolling week), quit policy (locked → never; feature on → hide instead of
  quit).
- Kiosk hardening: NSApplication presentation options hide the Dock/menu bar
  and disable Cmd+Tab, Cmd+Q/H, force-quit and logout — stronger than the
  Electron version's shortcut blocking. Same honest boundary as before: a
  user-space process can always be killed somehow; launchd revives the app
  within seconds.

## Dev testing the lock

Run with reduced timings (Scheme → Run → Arguments, or from terminal):

```bash
./DualNBack.app/Contents/MacOS/DualNBack --test-lock dailyMinutes=0.5,idleThresholdSeconds=10
```

`--test-lock` enables lock semantics without installing the LaunchAgent, with
in-memory numeric config overrides.

## Recovery

If the lock ever wedges the machine:

```bash
launchctl bootout gui/$(id -u)/com.dualnback.lock
rm ~/Library/LaunchAgents/com.dualnback.lock.plist
```

then kill the app (Activity Monitor via another Mac/SSH, or reboot into Safe
Mode). Marking today complete manually also works: edit
`~/Library/Application Support/DualNBack/lock-state.json` and set
`lastCompletedDate` to today's `YYYY-MM-DD`. See also `../docs/RECOVERY.md`.

## Project layout

```
macos/
├── DualNBack.xcodeproj
└── DualNBack/
    ├── AppDelegate.swift          # lifecycle, windows, quit policy, shortcuts
    ├── ContentView.swift          # SwiftUI UI (normal + kiosk modes)
    ├── GameEngine.swift           # game rules, scoring, auto-level, session
    ├── AudioController.swift      # speech letters + synthesized feedback tones
    ├── RecordsStore.swift         # training records persistence
    ├── LockState.swift            # persistent lock state (port of lock-state.js)
    ├── LockManager.swift          # lock state machine (port of lock-manager.js)
    ├── KioskController.swift      # kiosk + blackout windows (port of kiosk.js)
    └── LaunchAgentInstaller.swift # LaunchAgent plist + launchctl (port of launch-agent.js)
```
