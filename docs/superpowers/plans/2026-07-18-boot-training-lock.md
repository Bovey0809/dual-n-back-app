# Daily Boot Training Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS daily lock to the dual n-back Electron app: on first use each day the machine is locked behind a kiosk window until the user accumulates 20 minutes of training (or spends a limited high-friction skip).

**Architecture:** Single Electron app with two modes (lock kiosk / normal), plus a launchd LaunchAgent (`RunAtLoad` + `KeepAlive={SuccessfulExit:false}`) that starts the app at login and revives it if force-quit. The main process is the timing/unlock authority (renderer only sends heartbeats); state persists atomically to `userData/lock-state.json`. Spec: `docs/superpowers/specs/2026-07-18-boot-training-lock-design.md`.

**Tech Stack:** Electron 37 (CommonJS), vanilla JS renderer (single `index.html`), vitest for pure-logic unit tests, launchd/launchctl (macOS).

## Global Constraints

- macOS only; all files/actions stay in the user's home directory (no sudo).
- CommonJS everywhere in `src/main/` (`require`/`module.exports`); test files use ESM `import` (vitest transforms them).
- Every BrowserWindow keeps `contextIsolation: true, nodeIntegration: false`; renderer talks only through `src/preload.js`.
- `process.exit(0)` / normal quit is allowed ONLY in DEGRADED mode or when the lock feature is disabled (agent not installed and no `--test-lock`). All other paths keep the process resident.
- LaunchAgent label is exactly `com.dualnback.lock`; state filename exactly `lock-state.json`.
- IPC channel names exactly: `lock:get-state`, `lock:heartbeat`, `lock:state-changed`, `lock:request-skip`, `agent:get-status`, `agent:set-enabled`. (The two `agent:*` channels are an addendum to spec §4.6, required by spec §5's settings toggle.)
- Default config values (spec §4.3): `dailyMinutes: 20`, `idleThresholdSeconds: 90`, `skipsPerWeek: 2`, `skipWaitSeconds: 60`, `skipPhrase: "我承认我今天没有完成训练,我欠自己20分钟"`.
- Crash-loop rule (spec §6): ≥5 launches within 5 minutes while a lock would show → DEGRADED for 1 hour.
- Commit messages: short imperative sentences matching existing history; NO "Co-Authored-By" lines.
- vitest requires Node ≥18 (dev machine only; does not affect the packaged app).

---

### Task 1: Restructure renderer path + test tooling

**Files:**
- Move: `index.html` → `src/renderer/index.html` (`git mv`)
- Modify: `main.js` (loadFile path only)
- Modify: `package.json` (test script, vitest devDependency, build.files)

**Interfaces:**
- Consumes: nothing
- Produces: `src/renderer/index.html` path used by all later tasks; `npm test` runs vitest.

- [ ] **Step 1: Move the renderer file**

```bash
mkdir -p src/renderer src/main test docs
git mv index.html src/renderer/index.html
```

- [ ] **Step 2: Point main.js at the new path**

In `main.js` replace:

```js
    win.loadFile('index.html');
```

with:

```js
    win.loadFile('src/renderer/index.html');
```

- [ ] **Step 3: Update package.json**

Replace the `"scripts"` and `"devDependencies"` sections and `build.files`:

```json
  "scripts": {
    "start": "electron .",
    "test": "vitest run",
    "build": "electron-packager . DualNBackApp --platform=darwin --arch=arm64 --out=dist --overwrite --prune=true && xattr -cr dist/DualNBackApp-darwin-arm64/DualNBackApp.app && codesign --force --deep --sign - dist/DualNBackApp-darwin-arm64/DualNBackApp.app",
    "dist": "electron-builder"
  },
```

```json
    "files": [
      "main.js",
      "src/**/*",
      "node_modules/**/*"
    ],
```

```json
  "devDependencies": {
    "electron": "^37.2.5",
    "electron-builder": "^26.0.12",
    "electron-packager": "^17.1.2",
    "vitest": "^3.2.0"
  }
```

- [ ] **Step 4: Install and smoke-test**

```bash
npm install
npm start   # verify the app window opens and the game still runs; then quit
npx vitest run --passWithNoTests   # expected: "No test files found" + exit 0
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Move renderer to src/renderer and add vitest tooling"
```

---

### Task 2: lock-state.js — persistence (TDD)

**Files:**
- Create: `src/main/lock-state.js`
- Test: `test/lock-state.test.js`

**Interfaces:**
- Consumes: Node `fs`, `path` only (NO electron import — must stay vitest-runnable).
- Produces (exact exports used by Tasks 3/6/7):
  - `DEFAULT_CONFIG` (object with the 5 config keys from Global Constraints)
  - `STATE_FILENAME = 'lock-state.json'`
  - `localDateString(date) -> 'YYYY-MM-DD'` (local timezone)
  - `defaultState(now) -> state`
  - `loadState(dir, now) -> { state, corrupted }`
  - `saveState(dir, state) -> void` (atomic: tmp file + rename)

- [ ] **Step 1: Write the failing tests**

Create `test/lock-state.test.js`:

```js
import { describe, it, expect, beforeEach } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  DEFAULT_CONFIG, STATE_FILENAME, localDateString, defaultState, loadState, saveState,
} from '../src/main/lock-state.js';

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'lockstate-'));
}

describe('localDateString', () => {
  it('formats local date as YYYY-MM-DD', () => {
    expect(localDateString(new Date(2026, 6, 18, 23, 59))).toBe('2026-07-18');
    expect(localDateString(new Date(2026, 0, 5, 0, 0))).toBe('2026-01-05');
  });
});

describe('defaultState', () => {
  it('starts today with zero progress and default config', () => {
    const s = defaultState(new Date(2026, 6, 18));
    expect(s.progressDate).toBe('2026-07-18');
    expect(s.progressSecondsToday).toBe(0);
    expect(s.lastCompletedDate).toBeNull();
    expect(s.skips).toEqual([]);
    expect(s.recentLaunches).toEqual([]);
    expect(s.config).toEqual(DEFAULT_CONFIG);
    expect(s.config).not.toBe(DEFAULT_CONFIG); // must be a copy
  });
});

describe('load/save', () => {
  let dir;
  beforeEach(() => { dir = tmpDir(); });

  it('returns default state when file missing', () => {
    const { state, corrupted } = loadState(dir, new Date(2026, 6, 18));
    expect(corrupted).toBe(false);
    expect(state.progressDate).toBe('2026-07-18');
  });

  it('round-trips through save', () => {
    const s = defaultState(new Date(2026, 6, 18));
    s.progressSecondsToday = 123;
    saveState(dir, s);
    expect(fs.existsSync(path.join(dir, STATE_FILENAME))).toBe(true);
    expect(fs.existsSync(path.join(dir, STATE_FILENAME + '.tmp'))).toBe(false);
    const { state } = loadState(dir, new Date(2026, 6, 18));
    expect(state.progressSecondsToday).toBe(123);
  });

  it('rebuilds default and keeps .corrupt backup on parse error', () => {
    fs.writeFileSync(path.join(dir, STATE_FILENAME), '{not json');
    const { state, corrupted } = loadState(dir, new Date(2026, 6, 18));
    expect(corrupted).toBe(true);
    expect(state.progressSecondsToday).toBe(0);
    expect(fs.existsSync(path.join(dir, STATE_FILENAME + '.corrupt'))).toBe(true);
  });

  it('merges missing config keys from defaults (forward compat)', () => {
    const partial = { progressDate: '2026-07-18', progressSecondsToday: 5, config: { dailyMinutes: 10 } };
    fs.writeFileSync(path.join(dir, STATE_FILENAME), JSON.stringify(partial));
    const { state } = loadState(dir, new Date(2026, 6, 18));
    expect(state.config.dailyMinutes).toBe(10);
    expect(state.config.idleThresholdSeconds).toBe(90);
    expect(state.skips).toEqual([]);
    expect(state.recentLaunches).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npx vitest run test/lock-state.test.js
```

Expected: FAIL — cannot resolve `../src/main/lock-state.js`.

- [ ] **Step 3: Implement `src/main/lock-state.js` (persistence half)**

```js
// Persistent lock state. Pure Node (fs/path) — NO electron imports, so vitest can run it.
const fs = require('fs');
const path = require('path');

const STATE_FILENAME = 'lock-state.json';

const DEFAULT_CONFIG = {
  dailyMinutes: 20,
  idleThresholdSeconds: 90,
  skipsPerWeek: 2,
  skipWaitSeconds: 60,
  skipPhrase: '我承认我今天没有完成训练,我欠自己20分钟',
};

function localDateString(date = new Date()) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function defaultState(now = new Date()) {
  return {
    progressDate: localDateString(now),
    progressSecondsToday: 0,
    lastCompletedDate: null,
    skips: [],
    recentLaunches: [],
    config: { ...DEFAULT_CONFIG },
  };
}

function normalize(parsed, now) {
  const base = defaultState(now);
  return {
    ...base,
    ...parsed,
    skips: Array.isArray(parsed.skips) ? parsed.skips : [],
    recentLaunches: Array.isArray(parsed.recentLaunches) ? parsed.recentLaunches : [],
    config: { ...DEFAULT_CONFIG, ...(parsed.config || {}) },
  };
}

function loadState(dir, now = new Date()) {
  const file = path.join(dir, STATE_FILENAME);
  if (!fs.existsSync(file)) return { state: defaultState(now), corrupted: false };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return { state: normalize(parsed, now), corrupted: false };
  } catch (err) {
    // Spec §6: corrupted file → keep .corrupt backup, rebuild "today incomplete, zero progress"
    try { fs.renameSync(file, file + '.corrupt'); } catch (_) { /* best effort */ }
    return { state: defaultState(now), corrupted: true };
  }
}

function saveState(dir, state) {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, STATE_FILENAME);
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, file); // POSIX-atomic replace
}

module.exports = {
  DEFAULT_CONFIG, STATE_FILENAME,
  localDateString, defaultState, loadState, saveState,
};
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run test/lock-state.test.js
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/lock-state.js test/lock-state.test.js
git commit -m "Add lock-state persistence with atomic writes and corruption recovery"
```

---

### Task 3: lock-state.js — domain rules (TDD)

**Files:**
- Modify: `src/main/lock-state.js`
- Test: `test/lock-state.test.js` (append)

**Interfaces:**
- Consumes: Task 2 exports.
- Produces (exact signatures used by Task 6; `config` params default to `state.config` so `--test-lock` overrides can be injected without persisting them):
  - `ensureToday(state, now) -> state` (resets `progressDate`/`progressSecondsToday` on date change)
  - `isCompletedToday(state, now) -> boolean`
  - `remainingSeconds(state, config?) -> number`
  - `accumulateSeconds(state, deltaSeconds, now, config?) -> boolean` (true = quota reached)
  - `skipsRemaining(state, now, config?) -> number`
  - `recordSkip(state, now) -> void` (push ISO timestamp, mark today completed)
  - `recordCompletion(state, now) -> void`
  - `recordLaunch(state, now) -> void` (keep last 10)
  - `isCrashLooping(state, now) -> boolean` (≥5 launches in 5 min)
  - `clampHeartbeatDelta(lastMs, nowMs) -> number` (seconds in [0,1]; 1 when lastMs is null)

- [ ] **Step 1: Append failing tests to `test/lock-state.test.js`**

```js
import {
  ensureToday, isCompletedToday, remainingSeconds, accumulateSeconds,
  skipsRemaining, recordSkip, recordCompletion, recordLaunch, isCrashLooping,
  clampHeartbeatDelta,
} from '../src/main/lock-state.js';

const D18 = new Date(2026, 6, 18, 9, 0, 0);
const D19 = new Date(2026, 6, 19, 9, 0, 0);

describe('day rollover', () => {
  it('keeps progress on same day, resets on new day', () => {
    const s = defaultState(D18);
    s.progressSecondsToday = 500;
    ensureToday(s, new Date(2026, 6, 18, 23, 0));
    expect(s.progressSecondsToday).toBe(500);
    ensureToday(s, D19);
    expect(s.progressDate).toBe('2026-07-19');
    expect(s.progressSecondsToday).toBe(0);
  });

  it('isCompletedToday matches lastCompletedDate to local today', () => {
    const s = defaultState(D18);
    expect(isCompletedToday(s, D18)).toBe(false);
    recordCompletion(s, D18);
    expect(s.lastCompletedDate).toBe('2026-07-18');
    expect(isCompletedToday(s, D18)).toBe(true);
    expect(isCompletedToday(s, D19)).toBe(false);
  });
});

describe('accumulation', () => {
  it('counts toward quota and reports completion', () => {
    const s = defaultState(D18);
    s.config.dailyMinutes = 1; // 60s quota
    expect(accumulateSeconds(s, 59, D18)).toBe(false);
    expect(remainingSeconds(s)).toBe(1);
    expect(accumulateSeconds(s, 1, D18)).toBe(true);
    expect(remainingSeconds(s)).toBe(0);
  });

  it('accepts injected config without touching persisted config', () => {
    const s = defaultState(D18);
    const testCfg = { ...s.config, dailyMinutes: 0.5 }; // 30s quota
    expect(accumulateSeconds(s, 30, D18, testCfg)).toBe(true);
    expect(s.config.dailyMinutes).toBe(20);
    expect(remainingSeconds(s, testCfg)).toBe(0);
  });

  it('resets accumulation across days', () => {
    const s = defaultState(D18);
    accumulateSeconds(s, 100, D18);
    accumulateSeconds(s, 1, D19);
    expect(s.progressSecondsToday).toBe(1);
  });
});

describe('clampHeartbeatDelta', () => {
  it('caps at 1s, floors at 0, first beat counts 1s', () => {
    expect(clampHeartbeatDelta(null, 5000)).toBe(1);
    expect(clampHeartbeatDelta(1000, 2000)).toBe(1);
    expect(clampHeartbeatDelta(1000, 1400)).toBeCloseTo(0.4);
    expect(clampHeartbeatDelta(1000, 9000)).toBe(1);   // wall-clock cap: no fast-forward
    expect(clampHeartbeatDelta(2000, 1000)).toBe(0);   // clock went backwards
  });
});

describe('skips (rolling 7 days)', () => {
  it('limits to skipsPerWeek within rolling window', () => {
    const s = defaultState(D18);
    expect(skipsRemaining(s, D18)).toBe(2);
    recordSkip(s, new Date(2026, 6, 12, 10, 0)); // 6 days before D18 → inside window
    expect(skipsRemaining(s, D18)).toBe(1);
    recordSkip(s, D18);
    expect(skipsRemaining(s, D18)).toBe(0);
    // 8 days later both fall outside the window
    expect(skipsRemaining(s, new Date(2026, 6, 26, 11, 0))).toBe(2);
  });

  it('recordSkip marks today completed and keeps history', () => {
    const s = defaultState(D18);
    recordSkip(s, D18);
    expect(isCompletedToday(s, D18)).toBe(true);
    expect(s.skips.length).toBe(1);
  });
});

describe('crash-loop detection', () => {
  it('flags ≥5 launches within 5 minutes, keeps last 10', () => {
    const s = defaultState(D18);
    const base = D18.getTime();
    for (let i = 0; i < 4; i++) recordLaunch(s, new Date(base + i * 1000));
    expect(isCrashLooping(s, new Date(base + 10_000))).toBe(false);
    recordLaunch(s, new Date(base + 5_000));
    expect(isCrashLooping(s, new Date(base + 10_000))).toBe(true);
    // 6 minutes later the burst has aged out
    expect(isCrashLooping(s, new Date(base + 6 * 60_000 + 5_000))).toBe(false);
    for (let i = 0; i < 20; i++) recordLaunch(s, new Date(base + 60_000 + i));
    expect(s.recentLaunches.length).toBe(10);
  });
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
npx vitest run test/lock-state.test.js
```

Expected: FAIL — `ensureToday` (etc.) not exported.

- [ ] **Step 3: Implement the domain rules in `src/main/lock-state.js`**

Insert above `module.exports` and extend the export list:

```js
function ensureToday(state, now = new Date()) {
  const today = localDateString(now);
  if (state.progressDate !== today) {
    state.progressDate = today;
    state.progressSecondsToday = 0;
  }
  return state;
}

function isCompletedToday(state, now = new Date()) {
  return state.lastCompletedDate === localDateString(now);
}

function remainingSeconds(state, config = state.config) {
  return Math.max(0, config.dailyMinutes * 60 - state.progressSecondsToday);
}

function accumulateSeconds(state, deltaSeconds, now = new Date(), config = state.config) {
  ensureToday(state, now);
  state.progressSecondsToday += deltaSeconds;
  return remainingSeconds(state, config) === 0;
}

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

function skipsRemaining(state, now = new Date(), config = state.config) {
  const used = state.skips.filter((ts) => now.getTime() - Date.parse(ts) < WEEK_MS).length;
  return Math.max(0, config.skipsPerWeek - used);
}

function recordSkip(state, now = new Date()) {
  state.skips.push(now.toISOString());
  state.lastCompletedDate = localDateString(now);
}

function recordCompletion(state, now = new Date()) {
  state.lastCompletedDate = localDateString(now);
}

const CRASH_WINDOW_MS = 5 * 60 * 1000;
const CRASH_THRESHOLD = 5;

function recordLaunch(state, now = new Date()) {
  state.recentLaunches.push(now.toISOString());
  state.recentLaunches = state.recentLaunches.slice(-10);
}

function isCrashLooping(state, now = new Date()) {
  const recent = state.recentLaunches.filter(
    (ts) => now.getTime() - Date.parse(ts) < CRASH_WINDOW_MS
  );
  return recent.length >= CRASH_THRESHOLD;
}

function clampHeartbeatDelta(lastMs, nowMs) {
  if (lastMs == null) return 1;
  return Math.max(0, Math.min(1, (nowMs - lastMs) / 1000));
}
```

```js
module.exports = {
  DEFAULT_CONFIG, STATE_FILENAME,
  localDateString, defaultState, loadState, saveState,
  ensureToday, isCompletedToday, remainingSeconds, accumulateSeconds,
  skipsRemaining, recordSkip, recordCompletion,
  recordLaunch, isCrashLooping, clampHeartbeatDelta,
};
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run test/lock-state.test.js
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/lock-state.js test/lock-state.test.js
git commit -m "Add lock-state domain rules for quota, skips, and crash-loop detection"
```

---

### Task 4: launch-agent.js (plist TDD + launchctl wrapper)

**Files:**
- Create: `src/main/launch-agent.js`
- Test: `test/launch-agent.test.js`

**Interfaces:**
- Consumes: Node `fs`/`path`/`os`/`child_process`; `electron` lazily (only inside `programArguments`, so tests never touch it).
- Produces (used by Tasks 6/7/10):
  - `LABEL = 'com.dualnback.lock'`
  - `plistPath() -> string`
  - `buildPlist(programArgs: string[]) -> string` (pure, XML-escaped)
  - `isInstalled() -> boolean`
  - `install() -> void` (write plist + `launchctl bootstrap gui/$UID <plist>`)
  - `uninstall() -> void` (delete plist first, then `launchctl bootout gui/$UID/<LABEL>`)

- [ ] **Step 1: Write the failing test**

Create `test/launch-agent.test.js`:

```js
import { describe, it, expect } from 'vitest';
import { LABEL, buildPlist } from '../src/main/launch-agent.js';

describe('buildPlist', () => {
  const xml = buildPlist(['/Applications/My App.app/Contents/MacOS/App', '--autostart']);

  it('contains label, args, RunAtLoad, KeepAlive on SuccessfulExit=false', () => {
    expect(LABEL).toBe('com.dualnback.lock');
    expect(xml).toContain('<string>com.dualnback.lock</string>');
    expect(xml).toContain('<string>/Applications/My App.app/Contents/MacOS/App</string>');
    expect(xml).toContain('<string>--autostart</string>');
    expect(xml).toContain('<key>RunAtLoad</key>');
    expect(xml).toMatch(/<key>RunAtLoad<\/key>\s*<true\/>/);
    expect(xml).toMatch(/<key>SuccessfulExit<\/key>\s*<false\/>/);
    expect(xml).toContain('<key>ProcessType</key>');
    expect(xml).toContain('<string>Interactive</string>');
  });

  it('escapes XML-special characters in paths', () => {
    const evil = buildPlist(['/tmp/a&b<c>.app']);
    expect(evil).toContain('/tmp/a&amp;b&lt;c&gt;.app');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
npx vitest run test/launch-agent.test.js
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/main/launch-agent.js`**

```js
// LaunchAgent install/uninstall for the daily lock (spec §5).
// buildPlist is pure so it stays unit-testable; electron is required lazily.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const LABEL = 'com.dualnback.lock';

function plistPath() {
  return path.join(os.homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`);
}

function escapeXml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function buildPlist(programArgs) {
  const args = programArgs.map((a) => `    <string>${escapeXml(a)}</string>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
`;
}

// In dev (process.defaultApp) the exe is the bare Electron binary, which needs
// the app path as its first argument. In a packaged app the exe alone suffices.
function programArguments() {
  const { app } = require('electron');
  const exe = app.getPath('exe');
  return process.defaultApp
    ? [exe, app.getAppPath(), '--autostart']
    : [exe, '--autostart'];
}

function isInstalled() {
  return fs.existsSync(plistPath());
}

function launchctl(args) {
  try {
    execFileSync('launchctl', args, { stdio: 'ignore' });
  } catch (err) {
    // bootstrap fails if already loaded, bootout if not loaded — both are fine.
    console.log(`launchctl ${args.join(' ')} exited nonzero (often benign):`, err.message);
  }
}

function install() {
  const file = plistPath();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, buildPlist(programArguments()));
  launchctl(['bootstrap', `gui/${process.getuid()}`, file]);
}

// Delete the plist BEFORE bootout: bootout SIGTERMs this very process, and the
// quit decision in main.js checks isInstalled() to decide whether quitting is allowed.
function uninstall() {
  const file = plistPath();
  try { fs.unlinkSync(file); } catch (_) { /* already gone */ }
  launchctl(['bootout', `gui/${process.getuid()}/${LABEL}`]);
}

module.exports = { LABEL, plistPath, buildPlist, isInstalled, install, uninstall };
```

- [ ] **Step 4: Run all tests**

```bash
npm test
```

Expected: lock-state + launch-agent suites all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/launch-agent.js test/launch-agent.test.js
git commit -m "Add LaunchAgent plist builder and launchctl install/uninstall"
```

---

### Task 5: kiosk.js + blackout.html

**Files:**
- Create: `src/main/kiosk.js`
- Create: `src/renderer/blackout.html`

**Interfaces:**
- Consumes: `electron` (`BrowserWindow`, `globalShortcut`, `screen`, `Menu`).
- Produces (used by Task 6):
  - `createKiosk({ preloadPath, indexPath, blackoutPath }) -> void` (idempotent)
  - `destroyKiosk() -> void` (idempotent)
  - `isKioskActive() -> boolean`
  - `getKioskWindow() -> BrowserWindow | null`
- Behavior (spec §4.4): kiosk + `screen-saver` always-on-top + all-workspaces on primary display loading `index.html?mode=lock`; blackout window per secondary display; hot-plug covered via `screen` events; Cmd+Q/W/H/M swallowed; app menu emptied; window `close` prevented while active.

- [ ] **Step 1: Create `src/renderer/blackout.html`**

```html
<!DOCTYPE html>
<html lang="zh">
<head>
  <meta charset="UTF-8">
  <title>Locked</title>
  <style>
    html, body { margin: 0; height: 100%; background: #000; color: #333;
      display: flex; align-items: center; justify-content: center;
      font-family: -apple-system, sans-serif; user-select: none; cursor: none; }
  </style>
</head>
<body>🔒 完成今日训练后解锁</body>
</html>
```

- [ ] **Step 2: Create `src/main/kiosk.js`**

```js
// Lock-mode window management (spec §4.4). One kiosk window on the primary
// display, a blackout window on every other display, refreshed on hot-plug.
const { BrowserWindow, globalShortcut, screen, Menu } = require('electron');

const BLOCKED_SHORTCUTS = [
  'CommandOrControl+Q', 'CommandOrControl+W', 'CommandOrControl+H', 'CommandOrControl+M',
];

let kioskWin = null;
let blackouts = new Map(); // displayId -> BrowserWindow
let active = false;
let paths = null;
let previousMenu = null;

function pinToTop(win) {
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
}

function addBlackout(display) {
  if (blackouts.has(display.id)) return;
  const b = new BrowserWindow({
    x: display.bounds.x, y: display.bounds.y,
    width: display.bounds.width, height: display.bounds.height,
    frame: false, fullscreen: true, focusable: false, closable: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  pinToTop(b);
  b.on('close', (e) => { if (active) e.preventDefault(); });
  b.loadFile(paths.blackoutPath);
  blackouts.set(display.id, b);
}

function syncBlackouts() {
  if (!active) return;
  const primaryId = screen.getPrimaryDisplay().id;
  const current = new Set(screen.getAllDisplays().map((d) => d.id));
  for (const d of screen.getAllDisplays()) {
    if (d.id !== primaryId) addBlackout(d);
  }
  for (const [id, win] of blackouts) {
    if (!current.has(id) || id === primaryId) {
      win.destroy();
      blackouts.delete(id);
    }
  }
}

function createKiosk(p) {
  if (active) return;
  active = true;
  paths = p;

  previousMenu = Menu.getApplicationMenu();
  Menu.setApplicationMenu(Menu.buildFromTemplate([])); // drops default Cmd+Q/H/M roles
  BLOCKED_SHORTCUTS.forEach((acc) => globalShortcut.register(acc, () => {}));

  kioskWin = new BrowserWindow({
    kiosk: true, frame: false, closable: false, minimizable: false, resizable: false,
    webPreferences: {
      preload: p.preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  pinToTop(kioskWin);
  kioskWin.on('close', (e) => { if (active) e.preventDefault(); });
  kioskWin.loadFile(p.indexPath, { query: { mode: 'lock' } });

  syncBlackouts();
  screen.on('display-added', syncBlackouts);
  screen.on('display-removed', syncBlackouts);
}

function destroyKiosk() {
  if (!active) return;
  active = false;
  screen.removeListener('display-added', syncBlackouts);
  screen.removeListener('display-removed', syncBlackouts);
  BLOCKED_SHORTCUTS.forEach((acc) => globalShortcut.unregister(acc));
  Menu.setApplicationMenu(previousMenu);
  if (kioskWin && !kioskWin.isDestroyed()) kioskWin.destroy();
  kioskWin = null;
  for (const [, win] of blackouts) win.destroy();
  blackouts.clear();
}

function isKioskActive() { return active; }
function getKioskWindow() { return kioskWin; }

module.exports = { createKiosk, destroyKiosk, isKioskActive, getKioskWindow };
```

- [ ] **Step 3: Syntax check**

```bash
node -e "require('./src/main/kiosk.js')" 2>&1 | head -2
```

Expected: an error mentioning electron/app not ready is acceptable (module needs Electron runtime); a `SyntaxError` is NOT acceptable. Cleaner check: `node --check src/main/kiosk.js` → no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/main/kiosk.js src/renderer/blackout.html
git commit -m "Add kiosk window manager and blackout page for lock mode"
```

---

### Task 6: preload.js + lock-manager.js

**Files:**
- Create: `src/preload.js`
- Create: `src/main/lock-manager.js`

**Interfaces:**
- Consumes: Task 2/3 (`lock-state.js` exports), Task 5 (`kiosk.js` exports), electron `ipcMain`, `powerMonitor`.
- Produces:
  - `window.lockAPI` in every window (renderer contract for Tasks 8–10):
    - `getState() -> Promise<{mode, remainingSeconds, skipsRemaining, idleThresholdSeconds, skipWaitSeconds, skipPhrase}>`
    - `sendHeartbeat({gameRunning, secondsSinceLastInput}) -> void`
    - `requestSkip(phrase) -> Promise<{ok:true, waitSeconds} | {ok:false, error:'wrong-phrase'|'quota-exhausted'|'not-locked'|'skip-pending'}>`
    - `onStateChanged(cb) -> void` with payload `{mode, remainingSeconds, pausedForIdle, unlocked}`
    - `getAgentStatus() -> Promise<{installed}>`, `setAgentEnabled(enabled) -> Promise<{installed}>` (handlers arrive in Tasks 7/10)
  - `class LockManager` (used by Task 7):
    - `new LockManager({ stateDir, configOverrides, paths, isLockEnabled, onUnlocked })`
    - `init()` — record launch, crash-loop check, IPC handlers, powerMonitor hooks, 60s date timer, then `evaluateLock()`
    - `evaluateLock()`, `get mode()` (`'IDLE'|'LOCKED'|'DEGRADED'`), `isLocked()`, `flushState()`

- [ ] **Step 1: Create `src/preload.js`**

```js
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('lockAPI', {
  getState: () => ipcRenderer.invoke('lock:get-state'),
  sendHeartbeat: (payload) => ipcRenderer.send('lock:heartbeat', payload),
  requestSkip: (phrase) => ipcRenderer.invoke('lock:request-skip', { phrase }),
  onStateChanged: (cb) => ipcRenderer.on('lock:state-changed', (_e, s) => cb(s)),
  getAgentStatus: () => ipcRenderer.invoke('agent:get-status'),
  setAgentEnabled: (enabled) => ipcRenderer.invoke('agent:set-enabled', { enabled }),
});
```

- [ ] **Step 2: Create `src/main/lock-manager.js`**

```js
// State machine + timing authority (spec §4.1, §4.2, §6).
const { ipcMain, powerMonitor, BrowserWindow } = require('electron');
const kiosk = require('./kiosk');
const {
  loadState, saveState, ensureToday, isCompletedToday, remainingSeconds,
  accumulateSeconds, skipsRemaining, recordSkip, recordCompletion,
  recordLaunch, isCrashLooping, clampHeartbeatDelta,
} = require('./lock-state');

const DEGRADED_MS = 60 * 60 * 1000;    // spec §6: no kiosk retry for 1 hour
const PERSIST_EVERY_MS = 5 * 1000;     // spec §4.2: flush progress every 5s
const DATE_CHECK_MS = 60 * 1000;       // spec §6: check day rollover every 60s

class LockManager {
  constructor({ stateDir, configOverrides, paths, isLockEnabled, onUnlocked }) {
    this.stateDir = stateDir;
    this.paths = paths;                 // {preloadPath, indexPath, blackoutPath}
    this.isLockEnabled = isLockEnabled; // () => boolean, evaluated live
    this.onUnlocked = onUnlocked;       // () => void, main.js opens normal window
    const { state } = loadState(stateDir);
    this.state = state;
    this.config = { ...state.config, ...(configOverrides || {}) };
    this.mode = 'IDLE';
    this.degradedUntil = 0;
    this.lastHeartbeatMs = null;
    this.lastHeartbeat = null;
    this.dirty = false;
    this.skipTimer = null;
    this.timers = [];
  }

  init() {
    recordLaunch(this.state);
    const wouldLock = this.isLockEnabled() && !isCompletedToday(this.state);
    if (wouldLock && isCrashLooping(this.state)) {
      this.degradedUntil = Date.now() + DEGRADED_MS;   // spec §6 fail-open
    }
    saveState(this.stateDir, this.state);

    ipcMain.handle('lock:get-state', () => this.publicState());
    ipcMain.on('lock:heartbeat', (_e, payload) => this.handleHeartbeat(payload || {}));
    ipcMain.handle('lock:request-skip', (_e, { phrase } = {}) => this.requestSkip(phrase));

    powerMonitor.on('resume', () => this.evaluateLock());
    powerMonitor.on('unlock-screen', () => this.evaluateLock());

    this.timers.push(setInterval(() => this.evaluateLock(), DATE_CHECK_MS));
    this.timers.push(setInterval(() => this.flushState(), PERSIST_EVERY_MS));
    this.timers.push(setInterval(() => this.pushState(), 1000));

    this.evaluateLock();
  }

  publicState() {
    ensureToday(this.state);
    return {
      mode: this.mode,
      remainingSeconds: Math.ceil(remainingSeconds(this.state, this.config)),
      skipsRemaining: skipsRemaining(this.state, new Date(), this.config),
      idleThresholdSeconds: this.config.idleThresholdSeconds,
      skipWaitSeconds: this.config.skipWaitSeconds,
      skipPhrase: this.config.skipPhrase,
    };
  }

  evaluateLock() {
    ensureToday(this.state);
    if (this.degradedUntil && Date.now() < this.degradedUntil) {
      if (this.mode !== 'DEGRADED') {
        this.mode = 'DEGRADED';
        kiosk.destroyKiosk();
        this.onUnlocked(); // surface a normal window so the banner is visible
      }
      return;
    }
    if (!this.isLockEnabled() || isCompletedToday(this.state)) {
      if (this.mode === 'LOCKED') kiosk.destroyKiosk();
      this.mode = 'IDLE';
      return;
    }
    if (this.mode !== 'LOCKED') {
      this.mode = 'LOCKED';
      kiosk.createKiosk(this.paths);
    }
  }

  handleHeartbeat({ gameRunning, secondsSinceLastInput }) {
    const nowMs = Date.now();
    const delta = clampHeartbeatDelta(this.lastHeartbeatMs, nowMs);
    this.lastHeartbeatMs = nowMs;
    this.lastHeartbeat = { gameRunning, secondsSinceLastInput };
    const activelyTraining =
      gameRunning === true &&
      typeof secondsSinceLastInput === 'number' &&
      secondsSinceLastInput < this.config.idleThresholdSeconds;
    if (!activelyTraining) return;
    const done = accumulateSeconds(this.state, delta, new Date(), this.config);
    this.dirty = true;
    if (done && !isCompletedToday(this.state)) this.complete();
  }

  complete() {
    recordCompletion(this.state);
    saveState(this.stateDir, this.state);
    this.pushState(true);
    // Let the "完成" banner breathe for 3s, then tear down and hand back the machine.
    setTimeout(() => {
      kiosk.destroyKiosk();
      this.mode = 'IDLE';
      this.onUnlocked();
    }, 3000);
  }

  requestSkip(phrase) {
    if (this.mode !== 'LOCKED') return { ok: false, error: 'not-locked' };
    if (this.skipTimer) return { ok: false, error: 'skip-pending' };
    if (skipsRemaining(this.state, new Date(), this.config) <= 0) {
      return { ok: false, error: 'quota-exhausted' };
    }
    if (phrase !== this.config.skipPhrase) return { ok: false, error: 'wrong-phrase' };
    // Skip is recorded only when the mandatory wait completes (kill+relaunch
    // during the wait keeps the lock and does not burn quota).
    this.skipTimer = setTimeout(() => {
      this.skipTimer = null;
      recordSkip(this.state);
      saveState(this.stateDir, this.state);
      this.pushState(true);
      setTimeout(() => {
        kiosk.destroyKiosk();
        this.mode = 'IDLE';
        this.onUnlocked();
      }, 1500);
    }, this.config.skipWaitSeconds * 1000);
    return { ok: true, waitSeconds: this.config.skipWaitSeconds };
  }

  pushState(unlocked = false) {
    const payload = {
      mode: this.mode,
      remainingSeconds: Math.ceil(remainingSeconds(this.state, this.config)),
      pausedForIdle: Boolean(
        this.lastHeartbeat &&
        this.lastHeartbeat.gameRunning &&
        this.lastHeartbeat.secondsSinceLastInput >= this.config.idleThresholdSeconds
      ),
      unlocked: unlocked || isCompletedToday(this.state),
    };
    for (const win of BrowserWindow.getAllWindows()) {
      if (!win.isDestroyed()) win.webContents.send('lock:state-changed', payload);
    }
  }

  flushState() {
    if (!this.dirty) return;
    this.dirty = false;
    saveState(this.stateDir, this.state);
  }

  isLocked() { return this.mode === 'LOCKED'; }
}

module.exports = { LockManager };
```

- [ ] **Step 3: Syntax check both files**

```bash
node --check src/preload.js && node --check src/main/lock-manager.js && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add src/preload.js src/main/lock-manager.js
git commit -m "Add lock manager state machine and preload IPC bridge"
```

---

### Task 7: main.js rewrite + first end-to-end smoke test

**Files:**
- Modify: `main.js` (full rewrite below)

**Interfaces:**
- Consumes: `LockManager` (Task 6), `launch-agent.js` (Task 4), kiosk paths (Task 5).
- Produces: CLI contract `--autostart` (silent start) and `--test-lock k=v[,k=v]` (in-memory config overrides, e.g. `dailyMinutes=0.5`); quit policy per Global Constraints; `agent:get-status`/`agent:set-enabled` handlers.

- [ ] **Step 1: Replace `main.js` entirely**

```js
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const { LockManager } = require('./src/main/lock-manager');
const launchAgent = require('./src/main/launch-agent');
const kiosk = require('./src/main/kiosk');

const isAutostart = process.argv.includes('--autostart');

// --test-lock dailyMinutes=0.5,idleThresholdSeconds=10  → numeric config overrides (in-memory only)
function parseTestOverrides(argv) {
  const i = argv.indexOf('--test-lock');
  if (i === -1) return null;
  const spec = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : '';
  const out = {};
  for (const pair of spec.split(',').filter(Boolean)) {
    const [k, v] = pair.split('=');
    if (k && !Number.isNaN(Number(v))) out[k] = Number(v);
  }
  return out;
}
const testOverrides = parseTestOverrides(process.argv);

// Lock semantics are active only when the agent is installed (feature switch)
// or when explicitly testing. Evaluated live so toggling reacts immediately.
function isLockEnabled() {
  return testOverrides !== null || launchAgent.isInstalled();
}

const PATHS = {
  preloadPath: path.join(__dirname, 'src', 'preload.js'),
  indexPath: path.join(__dirname, 'src', 'renderer', 'index.html'),
  blackoutPath: path.join(__dirname, 'src', 'renderer', 'blackout.html'),
};

let manager = null;
let normalWin = null;

function createNormalWindow() {
  if (normalWin && !normalWin.isDestroyed()) {
    normalWin.show();
    normalWin.focus();
    return;
  }
  normalWin = new BrowserWindow({
    width: 1600,
    height: 1200,
    minWidth: 1200,
    minHeight: 800,
    resizable: true,
    webPreferences: {
      preload: PATHS.preloadPath,
      nodeIntegration: false,
      contextIsolation: true,
    },
    titleBarStyle: 'hiddenInset',
    icon: path.join(__dirname, 'icon.png'),
  });
  normalWin.loadFile(PATHS.indexPath);
  normalWin.on('closed', () => { normalWin = null; });
}

const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const kioskWin = kiosk.getKioskWindow();
    if (kioskWin) {
      kioskWin.focus();
    } else {
      createNormalWindow();
    }
  });

  app.whenReady().then(() => {
    manager = new LockManager({
      stateDir: app.getPath('userData'),
      configOverrides: testOverrides || undefined,
      paths: PATHS,
      isLockEnabled,
      onUnlocked: () => createNormalWindow(),
    });

    ipcMain.handle('agent:get-status', () => ({ installed: launchAgent.isInstalled() }));
    ipcMain.handle('agent:set-enabled', (_e, { enabled } = {}) => {
      if (enabled) launchAgent.install();
      else launchAgent.uninstall();
      manager.evaluateLock();
      return { installed: launchAgent.isInstalled() };
    });

    manager.init();

    // Autostart stays silent unless the manager decided to lock;
    // a manual launch always shows a window.
    if (!manager.isLocked() && !isAutostart) createNormalWindow();
  });

  app.on('activate', () => {
    if (!manager) return;
    if (!manager.isLocked()) createNormalWindow();
  });

  // Quit policy (spec §4.5 / §6):
  //   LOCKED            → never quit
  //   lock feature on   → stay resident (hide windows instead of quitting)
  //   DEGRADED or off   → normal quit allowed
  app.on('before-quit', (e) => {
    if (!manager) return;
    if (manager.isLocked()) {
      e.preventDefault();
      return;
    }
    if (manager.mode !== 'DEGRADED' && isLockEnabled()) {
      e.preventDefault();
      for (const win of BrowserWindow.getAllWindows()) win.hide();
      return;
    }
    manager.flushState();
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
```

- [ ] **Step 2: Smoke test — normal mode unaffected**

```bash
npm start
```

Expected: app opens the normal game window; play a few rounds; Cmd+Q quits (agent not installed → feature off → quit allowed).

- [ ] **Step 3: Smoke test — lock skeleton appears**

```bash
npm start -- --test-lock dailyMinutes=0.5
```

Expected: a fullscreen kiosk window covering the screen with the (not yet adapted) game UI; Cmd+Q and Cmd+W do nothing; Cmd+Opt+Esc force-quit kills it (launchd not involved in dev — that part is E2E-tested in Task 11). Quit via `kill <pid>` from another terminal, or complete 30s of training after Task 8 lands.
Note: the renderer is not yet lock-aware, so no banner/heartbeat — the lock will NOT unlock yet. Kill the process from another terminal: `pkill -f "electron ."`.

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "Rewrite main process entry with lock manager, quit policy, and test flags"
```

---

### Task 8: Renderer lock mode — banner, heartbeat, input tracking

**Files:**
- Modify: `src/renderer/index.html`

**Interfaces:**
- Consumes: `window.lockAPI` (Task 6 contract), `?mode=lock` query (Task 5 loads it).
- Produces: heartbeat `{gameRunning, secondsSinceLastInput}` every 1s from BOTH modes (free play counts toward the quota, spec §2); `LOCK` global consumed by Task 9; element ids `lockBanner`, `degradedBanner`, `sessionTimeGroup` consumed by Task 9/10.

- [ ] **Step 1: Add ids to existing HTML**

The session-time control group — change its opening tag only:

```html
            <div class="control-group" id="sessionTimeGroup">
                <label for="sessionTime">Session:</label>
```

- [ ] **Step 2: Add CSS before `</style>`**

```css
        /* ---- Daily lock mode ---- */
        body.lock-mode .records-section,
        body.lock-mode #sessionTimeGroup,
        body.lock-mode #agentGroup { display: none; }

        .lock-banner, .degraded-banner {
            display: none;
            text-align: center;
            font-size: 1.4em;
            font-weight: bold;
            padding: 12px;
            border-radius: 12px;
            margin-bottom: 12px;
        }
        .lock-banner {
            background: rgba(255, 87, 34, 0.25);
            border: 1px solid rgba(255, 87, 34, 0.55);
        }
        .lock-banner.completed {
            background: rgba(76, 175, 80, 0.35);
            border-color: #4CAF50;
        }
        .degraded-banner {
            background: rgba(255, 193, 7, 0.25);
            border: 1px solid rgba(255, 193, 7, 0.55);
            font-size: 1.0em;
        }
        body.lock-mode .lock-banner { display: block; }
        body.degraded .degraded-banner { display: block; }
```

- [ ] **Step 3: Add banners after `<h1>Dual N-Back Training</h1>`**

```html
        <div class="lock-banner" id="lockBanner">🔒 完成训练解锁电脑 · 今日剩余 --:--</div>
        <div class="degraded-banner" id="degradedBanner">⚠️ 锁屏因连续异常暂停一小时,请自觉完成今日训练</div>
```

- [ ] **Step 4: Add the lock integration script**

At the bottom of the `<script>` block, REPLACE the existing initializer:

```js
        // Initialize the game when the page loads
        document.addEventListener('DOMContentLoaded', () => {
            new DualNBack();
        });
```

with:

```js
        // ---- Daily lock integration (spec §4.2, §4.4) ----
        const LOCK = {
            isLockMode: new URLSearchParams(location.search).get('mode') === 'lock',
            lastInputAt: Date.now(),
            idleThresholdSeconds: 90,
            skipWaitSeconds: 60,
            skipPhrase: '',
            game: null,
        };

        function markInput() {
            LOCK.lastInputAt = Date.now();
            if (LOCK.game && LOCK.game.idlePaused) LOCK.game.resumeFromIdle();
        }

        function formatMMSS(totalSeconds) {
            const s = Math.max(0, Math.round(totalSeconds));
            return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
        }

        function updateLockBanner(state) {
            const banner = document.getElementById('lockBanner');
            if (state.unlocked) {
                banner.textContent = '✅ 今日训练完成!电脑已解锁';
                banner.classList.add('completed');
            } else if (state.pausedForIdle) {
                banner.textContent = `⏸ 已暂停(90 秒无操作)· 今日剩余 ${formatMMSS(state.remainingSeconds)}`;
            } else {
                banner.textContent = `🔒 完成训练解锁电脑 · 今日剩余 ${formatMMSS(state.remainingSeconds)}`;
            }
        }

        document.addEventListener('DOMContentLoaded', async () => {
            LOCK.game = new DualNBack();

            if (LOCK.isLockMode) document.body.classList.add('lock-mode');

            // Valid inputs (spec §4.2): A / L / Space keys and the response/start buttons.
            document.addEventListener('keydown', (e) => {
                const k = e.key.toLowerCase();
                if (k === 'a' || k === 'l' || e.key === ' ') markInput();
            });
            for (const id of ['visualBtn', 'audioBtn', 'startBtn']) {
                document.getElementById(id).addEventListener('click', markInput);
            }

            if (!window.lockAPI) return; // opened directly in a browser: degrade gracefully

            const state = await window.lockAPI.getState();
            LOCK.idleThresholdSeconds = state.idleThresholdSeconds;
            LOCK.skipWaitSeconds = state.skipWaitSeconds;
            LOCK.skipPhrase = state.skipPhrase;
            if (state.mode === 'DEGRADED') document.body.classList.add('degraded');
            if (LOCK.isLockMode) updateLockBanner({ ...state, unlocked: false, pausedForIdle: false });

            // Heartbeat every second — in both modes, so free play counts (spec §2).
            setInterval(() => {
                window.lockAPI.sendHeartbeat({
                    gameRunning: Boolean(LOCK.game.isRunning) && !LOCK.game.idlePaused,
                    secondsSinceLastInput: (Date.now() - LOCK.lastInputAt) / 1000,
                });
            }, 1000);

            window.lockAPI.onStateChanged((s) => {
                if (LOCK.isLockMode) updateLockBanner(s);
            });
        });
```

- [ ] **Step 5: Manual verification**

```bash
npm start -- --test-lock dailyMinutes=0.5
```

Expected: kiosk appears WITH the orange banner "今日剩余 0:30"; records section and Session dropdown hidden; press Start, play ~30 seconds → banner flips to "✅ 今日训练完成!" → 3 seconds later kiosk closes and the normal window opens. Delete the state to re-test: `rm "$HOME/Library/Application Support/dualnbackapp/lock-state.json"`.

Also verify free play counts: `npm start` (normal mode), play 10s, quit is blocked? No — feature off without agent/test flag, quit allowed; state accumulation still visible in the JSON file.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/index.html
git commit -m "Add lock mode banner and heartbeat reporting to renderer"
```

---

### Task 9: Renderer — idle pause overlay + emergency skip modal

**Files:**
- Modify: `src/renderer/index.html`

**Interfaces:**
- Consumes: `LOCK` global, `markInput`, `formatMMSS` (Task 8); `DualNBack` class internals (`isRunning`, `currentTimeout`, `timerInterval`, `sessionStartTime`, `startTimer()`, `nextRound()`, `toggleGame()`, `recordResponse()`); `lockAPI.requestSkip` (Task 6).
- Produces: `DualNBack.pauseForIdle()` / `resumeFromIdle()` and `idlePaused` flag (already referenced defensively by Task 8's heartbeat/markInput).

- [ ] **Step 1: Add CSS before `</style>`**

```css
        /* ---- Idle overlay + skip modal ---- */
        .modal-overlay {
            position: fixed; inset: 0; z-index: 2000;
            background: rgba(0, 0, 0, 0.75);
            display: none; align-items: center; justify-content: center;
        }
        .modal-overlay.show { display: flex; }
        .modal-card {
            background: rgba(30, 30, 40, 0.95);
            border: 1px solid rgba(255, 255, 255, 0.25);
            border-radius: 16px; padding: 30px; max-width: 520px;
            text-align: center; font-size: 1.1em;
        }
        .modal-card h2 { margin-bottom: 15px; font-weight: 400; }
        .modal-card textarea {
            width: 100%; min-height: 60px; margin: 12px 0; padding: 10px;
            border-radius: 8px; border: 1px solid rgba(255,255,255,0.3);
            background: rgba(255,255,255,0.1); color: white; font-size: 14px;
        }
        .modal-card .skip-phrase-hint {
            font-size: 0.85em; opacity: 0.75; user-select: text; margin-bottom: 5px;
        }
        .modal-card .modal-buttons { display: flex; gap: 12px; justify-content: center; margin-top: 10px; }
        .skip-btn {
            background: rgba(244, 67, 54, 0.25);
            border: 1px solid rgba(244, 67, 54, 0.5);
            display: none;
        }
        body.lock-mode .skip-btn { display: inline-block; }
```

- [ ] **Step 2: Add HTML before `</div>` of `.container` (right after the level-change notification div)**

```html
        <!-- Idle overlay (lock anti-AFK, spec §4.2) -->
        <div class="modal-overlay" id="idleOverlay">
            <div class="modal-card">
                <h2>⏸ 还在吗?</h2>
                <p>超过 90 秒没有操作,计时已暂停。</p>
                <p>按 A / L / 空格 继续训练</p>
            </div>
        </div>

        <!-- Emergency skip modal (spec §2 应急出口) -->
        <div class="modal-overlay" id="skipModal">
            <div class="modal-card">
                <h2>紧急跳过</h2>
                <p id="skipModalInfo">如需跳过今日训练,请一字不差输入以下句子:</p>
                <p class="skip-phrase-hint" id="skipPhraseHint"></p>
                <textarea id="skipInput" placeholder="在此输入…"></textarea>
                <p id="skipError" style="color:#FF8A80; min-height:1.2em;"></p>
                <div class="modal-buttons">
                    <button id="skipCancelBtn">取消</button>
                    <button id="skipConfirmBtn">确认跳过</button>
                </div>
            </div>
        </div>
```

And add the skip button inside the lock banner — replace the Task 8 banner line:

```html
        <div class="lock-banner" id="lockBanner">🔒 完成训练解锁电脑 · 今日剩余 --:--</div>
```

with:

```html
        <div class="lock-banner">
            <span id="lockBanner">🔒 完成训练解锁电脑 · 今日剩余 --:--</span>
            <button class="skip-btn" id="skipOpenBtn">紧急跳过</button>
        </div>
```

(Keep `updateLockBanner` from Task 8 working: it targets `#lockBanner`, now the inner span. Change its two `banner.classList` calls to `banner.parentElement.classList`.)

- [ ] **Step 3: Add pause/resume to `DualNBack`**

In the constructor, after `this.isRunning = false;` add:

```js
                this.idlePaused = false;
                this.idlePausedAt = null;
```

Add two methods after `stopGame()`:

```js
            pauseForIdle() {
                if (!this.isRunning || this.idlePaused) return;
                this.idlePaused = true;
                this.idlePausedAt = Date.now();
                clearTimeout(this.currentTimeout);
                clearInterval(this.timerInterval);
                document.getElementById('idleOverlay').classList.add('show');
            }

            resumeFromIdle() {
                if (!this.idlePaused) return;
                this.idlePaused = false;
                document.getElementById('idleOverlay').classList.remove('show');
                // Shift the free-play session clock so paused time doesn't count against it
                this.sessionStartTime += Date.now() - this.idlePausedAt;
                this.idlePausedAt = null;
                this.startTimer();
                this.nextRound();
            }
```

Guard the existing keyboard handler in `setupEventListeners()` — replace:

```js
                document.addEventListener('keydown', (e) => {
                    if (e.key.toLowerCase() === 'a') this.recordResponse('visual');
                    if (e.key.toLowerCase() === 'l') this.recordResponse('audio');
                    if (e.key === ' ') {
                        e.preventDefault();
                        this.toggleGame();
                    }
                });
```

with:

```js
                document.addEventListener('keydown', (e) => {
                    if (e.repeat) return;               // ignore key auto-repeat
                    if (this.idlePaused) return;        // resume is handled by markInput()
                    if (e.key.toLowerCase() === 'a') this.recordResponse('visual');
                    if (e.key.toLowerCase() === 'l') this.recordResponse('audio');
                    if (e.key === ' ') {
                        e.preventDefault();
                        this.toggleGame();
                    }
                });
```

NOTE: the class's `keydown` listener is registered in the constructor, BEFORE the lock integration's `markInput` listener (Task 8), so on a resume keypress the class handler sees `idlePaused === true` and returns; `markInput` then resumes. The keypress is consumed by the resume — by design it does not also fire a response.

- [ ] **Step 4: Add idle detection + skip flow to the lock integration block (Task 8's DOMContentLoaded, after the heartbeat `setInterval`)**

```js
            // Anti-AFK: renderer self-pauses; main independently stops counting (spec §4.2).
            setInterval(() => {
                if (!LOCK.isLockMode) return;
                const idleFor = (Date.now() - LOCK.lastInputAt) / 1000;
                if (LOCK.game.isRunning && !LOCK.game.idlePaused && idleFor >= LOCK.idleThresholdSeconds) {
                    LOCK.game.pauseForIdle();
                }
            }, 1000);

            // Emergency skip
            const skipModal = document.getElementById('skipModal');
            const skipError = document.getElementById('skipError');
            const skipConfirmBtn = document.getElementById('skipConfirmBtn');
            document.getElementById('skipPhraseHint').textContent = LOCK.skipPhrase;

            document.getElementById('skipOpenBtn').addEventListener('click', async () => {
                const s = await window.lockAPI.getState();
                document.getElementById('skipModalInfo').textContent =
                    `本周剩余 ${s.skipsRemaining} 次。如需跳过今日训练,请一字不差输入以下句子:`;
                skipError.textContent = '';
                document.getElementById('skipInput').value = '';
                skipModal.classList.add('show');
            });
            document.getElementById('skipCancelBtn').addEventListener('click', () => {
                skipModal.classList.remove('show');
            });
            skipConfirmBtn.addEventListener('click', async () => {
                const phrase = document.getElementById('skipInput').value.trim();
                const res = await window.lockAPI.requestSkip(phrase);
                if (!res.ok) {
                    skipError.textContent = {
                        'wrong-phrase': '句子不一致,请一字不差地输入',
                        'quota-exhausted': '本周跳过次数已用完',
                        'not-locked': '当前未锁定',
                        'skip-pending': '跳过正在等待中',
                    }[res.error] || res.error;
                    return;
                }
                skipConfirmBtn.disabled = true;
                let left = res.waitSeconds;
                skipError.textContent = '';
                const tick = setInterval(() => {
                    document.getElementById('skipModalInfo').textContent =
                        `强制等待中… ${left} 秒后解锁`;
                    if (left-- <= 0) clearInterval(tick);
                }, 1000);
            });
```

- [ ] **Step 5: Manual verification**

```bash
rm -f "$HOME/Library/Application Support/dualnbackapp/lock-state.json"
npm start -- --test-lock dailyMinutes=5,idleThresholdSeconds=10
```

Expected: ① start training, stop touching keys for 10s → idle overlay appears, banner shows ⏸, remaining time freezes; press A → overlay gone, training resumes, no response scored from that keypress. ② click 紧急跳过 → wrong phrase shows error; correct phrase → confirm disabled, countdown, unlock after 60s and normal window opens; `cat` the state JSON → one entry in `skips`.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/index.html
git commit -m "Add idle pause overlay and high-friction emergency skip"
```

---

### Task 10: LaunchAgent settings toggle in normal mode

**Files:**
- Modify: `src/renderer/index.html`

**Interfaces:**
- Consumes: `agent:get-status` / `agent:set-enabled` handlers (Task 7), `#agentGroup` CSS hide rule (Task 8).
- Produces: user-facing feature switch (spec §5).

- [ ] **Step 1: Add the control group in the controls div, right before the Test Audio button**

```html
            <div class="control-group" id="agentGroup">
                <label for="agentToggle">开机锁:</label>
                <select id="agentToggle">
                    <option value="off" selected>Off</option>
                    <option value="on">On</option>
                </select>
                <span id="agentStatusDot" style="opacity:0.85;">○</span>
            </div>
```

- [ ] **Step 2: Wire it in the lock integration block (inside the `if (!window.lockAPI) return;`-guarded section, after `getState`)**

```js
            // LaunchAgent feature toggle (normal mode only; hidden by CSS in lock mode)
            const agentToggle = document.getElementById('agentToggle');
            const agentDot = document.getElementById('agentStatusDot');
            function renderAgentStatus(installed) {
                agentToggle.value = installed ? 'on' : 'off';
                agentDot.textContent = installed ? '●' : '○';
                agentDot.style.color = installed ? '#4CAF50' : '';
                agentDot.title = installed ? '开机锁已启用' : '开机锁未启用';
            }
            renderAgentStatus((await window.lockAPI.getAgentStatus()).installed);
            agentToggle.addEventListener('change', async () => {
                const enable = agentToggle.value === 'on';
                if (enable && !confirm(
                    '启用后:每天首次使用电脑将全屏锁定,完成 20 分钟训练才能解锁;强退会被自动拉起。确定启用?')) {
                    renderAgentStatus(false);
                    return;
                }
                if (!enable && !confirm('确定关闭开机锁?')) {
                    renderAgentStatus(true);
                    return;
                }
                const res = await window.lockAPI.setAgentEnabled(enable);
                renderAgentStatus(res.installed);
            });
```

- [ ] **Step 3: Manual verification**

```bash
npm start
```

Expected: toggle shows Off/○. Switch to On → confirm dialog → `cat ~/Library/LaunchAgents/com.dualnback.lock.plist` shows the plist with the dev Electron binary + app path + `--autostart`; `launchctl print gui/$(id -u)/com.dualnback.lock | head -3` shows the job. Cmd+Q now hides the window instead of quitting (feature on → resident). Switch back to Off → plist gone, job booted out, Cmd+Q quits again.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/index.html
git commit -m "Add LaunchAgent on/off toggle with status indicator"
```

---

### Task 11: Docs + full E2E checklist

**Files:**
- Create: `docs/RECOVERY.md`
- Modify: `README.md` (new section)

**Interfaces:**
- Consumes: everything.
- Produces: recovery ladder (spec §7), honest-boundary documentation (spec §4.4), verified feature.

- [ ] **Step 1: Create `docs/RECOVERY.md`**

```markdown
# 恢复手册(锁屏出问题时按顺序尝试)

1. **锁屏内"紧急跳过"**:输入指定长句 + 等待 60 秒(滚动 7 天限 2 次)。
2. **另开终端 / SSH**:
   `launchctl bootout gui/$(id -u)/com.dualnback.lock`
   然后 `rm ~/Library/LaunchAgents/com.dualnback.lock.plist`
3. **安全模式**:开机长按电源键(Apple Silicon)进入安全模式,LaunchAgent 不会加载;
   删除上述 plist 后正常重启。
4. **Recovery 模式终端**:`rm /Users/<用户名>/Library/LaunchAgents/com.dualnback.lock.plist`

重置训练进度/跳过配额:删除
`~/Library/Application Support/dualnbackapp/lock-state.json`(app 未运行时)。

## 已知边界(设计如此)

- Cmd+Opt+Esc 强退无法禁止,但 launchd 会在数秒内重新拉起锁屏
  (短时间反复强退会触发约 10 秒的 launchd 节流)。
- Cmd+Tab 可以切换,但锁窗覆盖所有工作区,切走也无法操作其他应用。
- 连续异常保护:锁定态下 5 分钟内启动 ≥5 次,锁屏自动降级为普通窗口 1 小时,防止 bug 导致死循环。
- 修改系统时钟可以骗过"今天"判定 —— 自律工具,不设防。
```

- [ ] **Step 2: Add a README section** (after the existing "Features" section)

```markdown
## Daily Boot Training Lock (macOS)

Turn on the **开机锁** toggle in the app to install a per-user LaunchAgent
(`~/Library/LaunchAgents/com.dualnback.lock.plist`). From then on, the first time
you use the Mac each day, a fullscreen kiosk locks the machine until you
accumulate 20 minutes of dual n-back training (idle >90s pauses the clock).
Interrupted sessions resume from the remaining time; free play earlier in the
day counts toward the quota. A high-friction emergency skip (type a pledge
sentence + 60s wait, 2 per rolling week) is available on the lock screen.

Honest boundary: force-quit (Cmd+Opt+Esc) cannot be blocked from user space,
but launchd revives the lock within seconds; Cmd+Tab switches away but the lock
window covers every workspace. See `docs/RECOVERY.md` before enabling.

Dev testing: `npm start -- --test-lock dailyMinutes=0.5,idleThresholdSeconds=10`.
```

- [ ] **Step 3: Run the full E2E checklist (spec §8)** — reset state between items with `rm -f "$HOME/Library/Application Support/dualnbackapp/lock-state.json"`:

1. `npm start -- --test-lock dailyMinutes=0.5` → lock → train 30s → unlock, normal window opens. ☐
2. While locked, `kill -9 $(pgrep -f "electron . --test-lock" | head -1)`; relaunch manually (dev has no launchd) → lock reappears with progress preserved (check `progressSecondsToday` in JSON). ☐
3. `idleThresholdSeconds=10`: idle 10s → overlay + frozen clock; A resumes. ☐
4. Use skip twice (delete only `lastCompletedDate` between runs, keep `skips`), third attempt → "本周跳过次数已用完". ☐
5. Close laptop lid mid-lock, reopen → lock still on top, clock intact. ☐
6. Set `progressDate` to yesterday + some progress in the JSON (app not running), launch → progress reset to 0. ☐
7. Second display connected while locked → blackout covers it; unplug → no stray window. ☐
8. Toggle 开机锁 On → log out, log back in → app autostarts silently (agent job runs); with an incomplete day it locks. Force-quit → launchd revives within ~10s. Toggle Off → plist removed, no autostart on next login. ☐

Record any failures, fix before proceeding (systematic-debugging skill), re-run the failed item.

- [ ] **Step 4: Final commit**

```bash
git add docs/RECOVERY.md README.md
git commit -m "Document daily lock recovery ladder and honest boundaries"
```
