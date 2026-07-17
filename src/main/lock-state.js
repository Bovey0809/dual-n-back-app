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

module.exports = {
  DEFAULT_CONFIG, STATE_FILENAME,
  localDateString, defaultState, loadState, saveState,
  ensureToday, isCompletedToday, remainingSeconds, accumulateSeconds,
  skipsRemaining, recordSkip, recordCompletion,
  recordLaunch, isCrashLooping, clampHeartbeatDelta,
};
