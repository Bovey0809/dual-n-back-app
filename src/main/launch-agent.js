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
