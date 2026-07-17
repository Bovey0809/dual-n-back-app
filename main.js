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
