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
