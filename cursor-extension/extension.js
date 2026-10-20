// Agent Board opens cursor://agentboard.agent-board-jump/focus?pids=<pid,pid,...> with the process chain of
// the agent session it wants. Show the terminal whose shell is one of those processes.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

function log(line) {
  try { fs.appendFileSync(path.join(os.homedir(), '.agent-board', 'jump.log'), new Date().toISOString() + ' ' + line + '\n'); } catch (e) {}
}

function activate(context) {
  context.subscriptions.push(vscode.window.registerUriHandler({
    async handleUri(uri) {
      const pids = new URLSearchParams(uri.query).get('pids') || '';
      const wanted = new Set(pids.split(',').map(Number).filter(Boolean));
      const seen = [];
      for (const terminal of vscode.window.terminals) {
        const pid = await terminal.processId;
        seen.push(pid);
        if (wanted.has(pid)) {
          terminal.show(false);
          await vscode.commands.executeCommand('workbench.action.terminal.focus');
          log(`focused "${terminal.name}" (pid ${pid})`);
          return;
        }
      }
      log(`no terminal in this window matched ${[...wanted]} (window has ${seen})`);
    }
  }));
}

module.exports = { activate };
