const { app, BrowserWindow } = require('electron');
const path = require('path');

// Handle sandbox issues in certain environments - must be called before app ready
if (process.env.NODE_ENV === 'development' || process.env.CI || process.platform === 'linux') {
  app.commandLine.appendSwitch('--no-sandbox');
  app.commandLine.appendSwitch('--disable-setuid-sandbox');
  app.commandLine.appendSwitch('--disable-dev-shm-usage');
}

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
      width: 900,
      height: 700,
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true
      },
      show: false, // Don't show window in headless environments
      titleBarStyle: 'hiddenInset', // Mac-style title bar
      icon: path.join(__dirname, 'icon.png') // Optional app icon
    });

    win.loadFile('index.html');
    
    // Only show window if we have a display
    if (process.env.DISPLAY || process.platform === 'win32' || process.platform === 'darwin') {
      win.show();
    }
    
    return win;
  }

  app.whenReady().then(() => {
    try {
      createWindow();
    } catch (error) {
      console.error('Failed to create window:', error);
      app.quit();
    }
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}