#!/usr/bin/env node
/* Compiles every .lua file in the repo with fengari (a Lua VM in JS) and fails
   on a syntax error. It does not run the code — the tests do that — it only
   catches the typo that would otherwise blow up when the resource restarts on
   the live server.

   Run with: npm run lint   (or npm run check for lint + tests) */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const ROOT = path.join(__dirname, '..');
const SKIP = new Set(['node_modules', '.git', 'data', 'html', 'preview']);

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue;

    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith('.lua')) out.push(full);
  }

  return out;
}

const files = walk(ROOT).sort();
const failures = [];

for (const file of files) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const source = fs.readFileSync(file, 'utf8');
  const status = lauxlib.luaL_loadbuffer(
    L,
    to_luastring(source),
    source.length,
    to_luastring(path.relative(ROOT, file)),
  );

  if (status !== lua.LUA_OK) {
    failures.push({ file: path.relative(ROOT, file), message: to_jsstring(lua.lua_tostring(L, -1)) });
  }
}

for (const failure of failures) {
  console.log(`SYNTAX  ${failure.file}\n        ${failure.message}`);
}

console.log(`\n${files.length - failures.length}/${files.length} Lua files parse`);
process.exit(failures.length ? 1 : 0);
