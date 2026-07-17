// State machine + timing authority (spec §4.1, §4.2, §6).
const { ipcMain, powerMonitor, BrowserWindow } = require('electron');
const kiosk = require('./kiosk');
const {
  loadState, saveState, ensureToday, isCompletedToday, remainingSeconds,
  accumulateSeconds, skipsRemaining, recordSkip, recordCompletion,
  recordLaunch, isCrashLooping, clampHeartbeatDelta, localDateString,
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
    if (this.skipTimer) {
      clearTimeout(this.skipTimer);
      this.skipTimer = null;
    }
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
    const skipNow = new Date();
    if (localDateString(skipNow) !==
        localDateString(new Date(skipNow.getTime() + this.config.skipWaitSeconds * 1000))) {
      return { ok: false, error: 'day-boundary' };
    }
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
