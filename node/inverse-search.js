#!/usr/bin/env node
'use strict';

// Invoked by SumatraPDF's "InverseSearchCmdLine" setting on double-click:
//   node "<plugin>/node/inverse-search.js" "%f" %l
// %f = absolute path to the .tex source, %l = 1-indexed line number.
//
// Reaches the already-running Neovim instance via `nvim --server <addr>
// --remote-expr`, using the address the plugin published to
// stdpath('data')/overleaf-nvim-server.txt (see lua/overleaf/synctex.lua).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const [, , file, lineArg] = process.argv;
const line = parseInt(lineArg, 10) || 1;

if (!file) {
  console.error('[overleaf inverse-search] missing source file argument');
  process.exit(1);
}

// Same path Neovim's stdpath('data') resolves to on each OS.
function nvimDataDir() {
  if (process.platform === 'win32') {
    return path.join(process.env.LOCALAPPDATA || os.homedir(), 'nvim-data');
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'nvim');
  }
  return path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'nvim');
}

const serverFile = path.join(nvimDataDir(), 'overleaf-nvim-server.txt');

let addr;
try {
  addr = fs.readFileSync(serverFile, 'utf8').trim();
} catch (e) {
  console.error(`[overleaf inverse-search] no running Neovim found (${serverFile} not readable)`);
  process.exit(1);
}

if (!addr) {
  console.error('[overleaf inverse-search] empty server address');
  process.exit(1);
}

const luaCall = 'require("overleaf.synctex").inverse_goto(_A[1], _A[2])';
const expr = `luaeval('${luaCall}', [${JSON.stringify(file)}, ${line}])`;

const nvimBin = process.env.OVERLEAF_NVIM_PATH || 'nvim';

try {
  // --headless: without it, a client spawned with non-console stdio (as we
  // are here) can fall back to initializing its own TUI instead of acting
  // as a pure --remote-expr client.
  execFileSync(nvimBin, ['--headless', '--server', addr, '--remote-expr', expr], { stdio: 'inherit' });
} catch (e) {
  console.error(`[overleaf inverse-search] failed to reach Neovim at ${addr}: ${e.message}`);
  process.exit(1);
}
