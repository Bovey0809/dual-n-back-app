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
