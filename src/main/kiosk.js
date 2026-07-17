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
