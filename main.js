const { app, BrowserWindow } = require('electron');
const path = require('path');

// Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  console.log('Another instance is already running, quitting...');
  app.quit();
} else {
  app.on('second-instance', (event, commandLine, workingDirectory) => {
    // Someone tried to run a second instance, we should focus our window instead.
    const windows = BrowserWindow.getAllWindows();
    if (windows.length) {
      if (windows[0].isMinimized()) windows[0].restore();
      windows[0].focus();
    }
  });

  function createWindow() {
    const win = new BrowserWindow({
      width: 1600,
      height: 1200,
      minWidth: 1200,
      minHeight: 800,
      resizable: true,
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true
      },
      titleBarStyle: 'hiddenInset', // Mac-style title bar
      icon: path.join(__dirname, 'icon.png') // Optional app icon
    });

    win.loadFile('index.html');
  }

  app.whenReady().then(createWindow);

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}