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
