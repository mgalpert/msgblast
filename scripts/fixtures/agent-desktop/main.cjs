const { app, BrowserWindow, session } = require('electron');
const path = require('node:path');
app.setName('Grok Transport Fixture');
app.setPath('userData', path.join(app.getPath('temp'), `msgblast-grok-transport-fixture-${process.pid}`));
app.whenReady().then(() => {
  app.setAccessibilitySupportEnabled(true);
  session.defaultSession.webRequest.onBeforeRequest((details, callback) => callback({cancel: !details.url.startsWith('file:')}));
  const window = new BrowserWindow({width: 1000, height: 750, title: 'Grok Transport Fixture', webPreferences: {nodeIntegration: false, contextIsolation: true, sandbox: true}});
  window.loadFile(path.join(__dirname, 'fixture.html'));
});
app.on('window-all-closed', () => app.quit());
