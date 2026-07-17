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
