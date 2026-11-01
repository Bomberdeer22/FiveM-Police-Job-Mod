/* Loads the fk_spawn resource inside fengari (a Lua VM in JS) with mocked
   FiveM natives, then exercises spawn parsing, validation, lookup, the saved
   override file, the staff gate and the commands.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const ROOT = path.join(__dirname, '..', 'fk_spawn');
const FILES = ['config.lua', 'shared/spawns.lua', 'server/main.lua'];

let pass = 0;
const failures = [];

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
    return;
  }
  failures.push({ name, detail });
}

function createHarness(options = {}) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const captured = { client: [], server: [], logs: [], chat: [], timers: [], threads: [] };
  const filesystem = options.files || {};
  const staffIds = new Set(options.staff || []);
  const handlers = {};
  const events = {};
  const commands = {};
  const exportsMap = {};
  const playerStateRefs = {};

  const abs = (idx) => (idx > 0 || idx <= lua.LUA_REGISTRYINDEX ? idx : lua.lua_gettop(L) + idx + 1);

  function luaToJs(idx) {
    idx = abs(idx);
    const t = lua.lua_type(L, idx);
    if (t === lua.LUA_TNIL || t === lua.LUA_TNONE) return null;
    if (t === lua.LUA_TBOOLEAN) return lua.lua_toboolean(L, idx);
    if (t === lua.LUA_TNUMBER) return lua.lua_tonumber(L, idx);
    if (t === lua.LUA_TSTRING) return to_jsstring(lua.lua_tostring(L, idx));
    if (t === lua.LUA_TTABLE) {
      const obj = {};
      let count = 0;
      lua.lua_pushnil(L);
      while (lua.lua_next(L, idx) !== 0) {
        obj[luaToJs(-2)] = luaToJs(-1);
        count += 1;
        lua.lua_pop(L, 1);
      }
      const keys = Object.keys(obj);
      const isArray =
        count > 0 &&
        keys.length === count &&
        keys.every((k) => /^\d+$/.test(k)) &&
        Math.max(...keys.map(Number)) === count;
      if (isArray) {
        const arr = [];
        for (let i = 1; i <= count; i += 1) arr.push(obj[i]);
        return arr;
      }
      return obj;
    }
    return null;
  }

  function pushJs(value) {
    if (value === null || value === undefined) {
      lua.lua_pushnil(L);
    } else if (typeof value === 'boolean') {
      lua.lua_pushboolean(L, value);
    } else if (typeof value === 'number') {
      lua.lua_pushnumber(L, value);
    } else if (typeof value === 'string') {
      lua.lua_pushstring(L, to_luastring(value));
    } else if (Array.isArray(value)) {
      lua.lua_createtable(L, value.length, 0);
      value.forEach((item, index) => {
        pushJs(item);
        lua.lua_rawseti(L, -2, index + 1);
      });
    } else {
      lua.lua_createtable(L, 0, Object.keys(value).length);
      Object.entries(value).forEach(([key, item]) => {
        pushJs(item);
        lua.lua_setfield(L, -2, to_luastring(key));
      });
    }
  }

  function reg() {
    lua.lua_pushvalue(L, -1);
    return lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
  }

  function callRef(ref, args = []) {
    lua.lua_getglobal(L, to_luastring('debug'));
    lua.lua_getfield(L, -1, to_luastring('traceback'));
    lua.lua_remove(L, -2);
    const msgh = lua.lua_gettop(L);

    const base = lua.lua_gettop(L);
    lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, ref);
    args.forEach((arg) => pushJs(arg));

    const status = lua.lua_pcall(L, args.length, lua.LUA_MULTRET, msgh);
    if (status !== lua.LUA_OK) {
      const raw = lua.lua_tostring(L, -1);
      const message = raw ? to_jsstring(raw) : 'unknown error';
      lua.lua_settop(L, base - 1);
      throw new Error('Lua error: ' + message);
    }
    const top = lua.lua_gettop(L);
    const results = [];
    for (let index = base + 1; index <= top; index += 1) results.push(luaToJs(index));
    lua.lua_settop(L, base - 1);
    return results;
  }

  function setGlobal(name, fn) {
    lua.lua_pushcfunction(L, fn);
    lua.lua_setglobal(L, to_luastring(name));
  }

  // -------------------------------------------------------------------------
  // natives
  // -------------------------------------------------------------------------
  setGlobal('GetCurrentResourceName', () => {
    lua.lua_pushstring(L, to_luastring('fk_spawn'));
    return 1;
  });

  setGlobal('LoadResourceFile', () => {
    const file = to_jsstring(lua.lua_tostring(L, 2));
    lua.lua_pushstring(L, to_luastring(filesystem[file] || ''));
    return 1;
  });

  setGlobal('SaveResourceFile', () => {
    const file = to_jsstring(lua.lua_tostring(L, 2));
    filesystem[file] = to_jsstring(lua.lua_tostring(L, 3));
    lua.lua_pushboolean(L, true);
    return 1;
  });

  setGlobal('print', () => {
    const parts = [];
    const top = lua.lua_gettop(L);
    for (let i = 1; i <= top; i += 1) parts.push(String(luaToJs(i)));
    captured.logs.push(parts.join('\t'));
    return 0;
  });

  // json bridge
  lua.lua_createtable(L, 0, 2);
  lua.lua_pushcfunction(L, () => {
    lua.lua_pushstring(L, to_luastring(JSON.stringify(luaToJs(1))));
    return 1;
  });
  lua.lua_setfield(L, -2, to_luastring('encode'));
  lua.lua_pushcfunction(L, () => {
    const raw = to_jsstring(lua.lua_tostring(L, 1));
    try {
      pushJs(JSON.parse(raw));
    } catch (error) {
      lua.lua_pushnil(L);
    }
    return 1;
  });
  lua.lua_setfield(L, -2, to_luastring('decode'));
  lua.lua_setglobal(L, to_luastring('json'));

  // deterministic timestamps
  lua.lua_getglobal(L, to_luastring('os'));
  lua.lua_pushcfunction(L, () => {
    lua.lua_pushstring(L, to_luastring('2026-01-01T00:00:00Z'));
    return 1;
  });
  lua.lua_setfield(L, -2, to_luastring('date'));
  lua.lua_pop(L, 1);

  // Short timers (save debounce) run inline; long ones (join fallback) are
  // queued so the tests decide when they fire.
  setGlobal('SetTimeout', () => {
    const ms = lua.lua_tonumber(L, 1) || 0;
    lua.lua_pushvalue(L, 2);
    const fnRef = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);

    if (ms < 5000) callRef(fnRef);
    else captured.timers.push({ ms, fnRef });

    return 0;
  });

  setGlobal('GetPlayers', () => {
    lua.lua_createtable(L, 0, 2);
    lua.lua_pushstring(L, to_luastring('1'));
    lua.lua_rawseti(L, -2, 1);
    lua.lua_pushstring(L, to_luastring('2'));
    lua.lua_rawseti(L, -2, 2);
    return 1;
  });

  setGlobal('GetResourceMetadata', () => {
    lua.lua_pushstring(L, to_luastring('0.1.1'));
    return 1;
  });

  setGlobal('GetPlayerName', (id) => {
    lua.lua_pushstring(L, to_luastring('Player' + Math.trunc(lua.lua_tonumber(L, 1))));
    return 1;
  });

  setGlobal('TriggerClientEvent', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    const target = luaToJs(2);
    const args = [];
    const top = lua.lua_gettop(L);
    for (let i = 3; i <= top; i += 1) args.push(luaToJs(i));
    captured.client.push({ name, target, args });
    return 0;
  });

  setGlobal('TriggerEvent', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    const args = [];
    const top = lua.lua_gettop(L);
    for (let i = 2; i <= top; i += 1) args.push(luaToJs(i));
    captured.server.push({ name, args });
    return 0;
  });

  setGlobal('RegisterNetEvent', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    lua.lua_pushvalue(L, 2);
    handlers[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('AddEventHandler', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    lua.lua_pushvalue(L, 2);
    events[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('RegisterCommand', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    lua.lua_pushvalue(L, 2);
    commands[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('exports', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    lua.lua_pushvalue(L, 2);
    exportsMap[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('Player', () => {
    const id = Math.trunc(lua.lua_tonumber(L, 1));
    lua.lua_createtable(L, 0, 1);
    lua.lua_newtable(L);
    lua.lua_pushvalue(L, -1);
    playerStateRefs[id] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    lua.lua_setfield(L, -2, to_luastring('state'));
    return 1;
  });

  setGlobal('GetResourceState', () => {
    lua.lua_pushstring(L, to_luastring('missing'));
    return 1;
  });

  setGlobal('IsPlayerAceAllowed', () => {
    const id = Math.trunc(lua.lua_tonumber(L, 1));
    const ace = to_jsstring(lua.lua_tostring(L, 2));
    lua.lua_pushboolean(L, staffIds.has(id) && ace === 'fk_spawn.staff');
    return 1;
  });

  // Threads are queued: the push loop must not run before the tests look at it.
  setGlobal('CreateThread', () => {
    lua.lua_pushvalue(L, 1);
    captured.threads.push(lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX));
    return 0;
  });
  setGlobal('Wait', () => 0);

  // -------------------------------------------------------------------------
  // load the resource
  // -------------------------------------------------------------------------
  FILES.forEach((file) => {
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const buffer = Buffer.from(source, 'utf8');
    const status = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring('@' + file));
    if (status !== lua.LUA_OK) {
      throw new Error(`${file} failed to load: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    }
    const call = lua.lua_pcall(L, 0, 0, 0);
    if (call !== lua.LUA_OK) {
      throw new Error(`${file} failed to run: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    }
  });

  function setGlobalValue(name, value) {
    pushJs(value);
    lua.lua_setglobal(L, to_luastring(name));
  }

  return {
    captured,
    filesystem,
    lua,
    state: L,
    call(fnName, args = []) {
      const ref = exportsMap[fnName] || handlers[fnName] || commands[fnName] || events[fnName];
      if (ref === undefined) throw new Error(`no export/event/command "${fnName}"`);
      return callRef(ref, args);
    },
    callExport(name, args = []) {
      if (exportsMap[name] === undefined) throw new Error(`no export "${name}"`);
      return callRef(exportsMap[name], Array.isArray(args) ? args : [args]);
    },
    fireNet(name, source, args = []) {
      if (handlers[name] === undefined) throw new Error(`no net event "${name}"`);
      setGlobalValue('source', source);
      return callRef(handlers[name], args);
    },
    runCommand(name, source, args = []) {
      if (commands[name] === undefined) throw new Error(`no command "${name}"`);
      setGlobalValue('source', source);
      return callRef(commands[name], [source, args]);
    },
    fireEvent(name, source, args = []) {
      if (events[name] === undefined) throw new Error(`no event "${name}"`);
      setGlobalValue('source', source);
      return callRef(events[name], args);
    },
    runThreads() {
      const threads = captured.threads.splice(0, captured.threads.length);
      threads.forEach((ref) => callRef(ref));
    },
    runTimers() {
      const timers = captured.timers.splice(0, captured.timers.length);
      timers.forEach((timer) => callRef(timer.fnRef));
    },
    playerState(id, key) {
      const ref = playerStateRefs[id];
      if (ref === undefined) return undefined;
      lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, ref);
      lua.lua_getfield(L, -1, to_luastring(key));
      const value = luaToJs(-1);
      lua.lua_pop(L, 2);
      return value;
    },
  };
}

// ---------------------------------------------------------------------------
// helpers for calling pure shared functions
// ---------------------------------------------------------------------------

function luaValue(vm, idx) {
  const T = vm.lua;
  const S = vm.state;
  const t = T.lua_type(S, idx);
  if (t === T.LUA_TBOOLEAN) return T.lua_toboolean(S, idx);
  if (t === T.LUA_TNUMBER) return T.lua_tonumber(S, idx);
  if (t === T.LUA_TSTRING) return to_jsstring(T.lua_tostring(S, idx));
  if (t === T.LUA_TTABLE) {
    const obj = {};
    const arr = [];
    let count = 0;
    T.lua_pushnil(S);
    while (T.lua_next(S, idx) !== 0) {
      const key = luaValue(vm, -2);
      const value = luaValue(vm, -1);
      obj[key] = value;
      count += 1;
      T.lua_pop(S, 1);
    }
    const keys = Object.keys(obj);
    const isArray = count > 0
      && keys.length === count
      && keys.every((k) => /^\d+$/.test(k))
      && Math.max(...keys.map(Number)) === count;
    if (isArray) {
      for (let i = 1; i <= count; i += 1) arr.push(obj[i]);
      return arr;
    }
    return obj;
  }
  return null;
}

function pushValue(T, S, value) {
  if (value === null || value === undefined) T.lua_pushnil(S);
  else if (typeof value === 'number') T.lua_pushnumber(S, value);
  else if (typeof value === 'string') T.lua_pushstring(S, to_luastring(value));
  else if (typeof value === 'boolean') T.lua_pushboolean(S, value);
  else if (Array.isArray(value)) {
    T.lua_createtable(S, value.length, 0);
    value.forEach((item, index) => {
      pushValue(T, S, item);
      T.lua_rawseti(S, -2, index + 1);
    });
  } else {
    T.lua_createtable(S, 0, Object.keys(value).length);
    Object.entries(value).forEach(([key, item]) => {
      pushValue(T, S, item);
      T.lua_setfield(S, -2, to_luastring(key));
    });
  }
}

function luaCallGlobal(path, args = []) {
  const vm = createHarness();
  const T = vm.lua;
  const S = vm.state;

  const base = T.lua_gettop(S);
  const parts = path.split('.');
  T.lua_getglobal(S, to_luastring(parts[0]));
  for (let i = 1; i < parts.length; i += 1) T.lua_getfield(S, -1, to_luastring(parts[i]));

  // keep only the resolved function on the stack
  T.lua_replace(S, base + 1);
  T.lua_settop(S, base + 1);

  args.forEach((arg) => {
    if (arg === null || arg === undefined) T.lua_pushnil(S);
    else if (typeof arg === 'number') T.lua_pushnumber(S, arg);
    else if (typeof arg === 'string') T.lua_pushstring(S, to_luastring(arg));
    else if (typeof arg === 'boolean') T.lua_pushboolean(S, arg);
    else {
      pushValue(T, S, arg);
    }
  });

  const status = T.lua_pcall(S, args.length, T.LUA_MULTRET, 0);
  if (status !== T.LUA_OK) throw new Error(to_jsstring(T.lua_tostring(S, -1)));

  const results = [];
  for (let i = base + 1; i <= T.lua_gettop(S); i += 1) results.push(luaValue(vm, i));
  return results;
}

// ---------------------------------------------------------------------------
// config + shared helpers
// ---------------------------------------------------------------------------

const h = createHarness();

check("default spawn is Michael's bedroom",
  h.callExport('GetDefaultSpawnName')[0] === 'michael_bedroom',
  h.callExport('GetDefaultSpawnName'));

const [bedroom] = h.callExport('GetSpawnPoint', 'michael_bedroom');
check('bedroom is upstairs in the mansion',
  !!bedroom && bedroom.z > 76 && bedroom.z < 78 && bedroom.x < -800, bedroom);
check('bedroom uses the interior coordinates',
  !!bedroom && bedroom.x === -812.56 && bedroom.y === 174.85 && bedroom.z === 76.74, bedroom);
check('bedroom carries a heading', !!bedroom && typeof bedroom.w === 'number', bedroom && bedroom.w);
check('bedroom loads the mansion interior',
  !!bedroom && bedroom.interior === 'michael_house', bedroom && bedroom.interior);

check('spawn names are case and space insensitive',
  (() => {
    const [point] = h.callExport('GetSpawnPoint', '  Michael Bedroom ');
    return point && point.name === 'michael_bedroom';
  })(),
  h.callExport('GetSpawnPoint', '  Michael Bedroom '));

check('unknown spawn names resolve to nil', h.callExport('GetSpawnPoint', 'nope')[0] === null);
check('no argument resolves to the default point',
  (() => {
    const [point] = h.callExport('GetSpawnPoint', null);
    return point && point.name === 'michael_bedroom';
  })());

check('every configured point is valid',
  h.callExport('GetSpawnPoints')[0].length === 1, h.callExport('GetSpawnPoints'));

// ---------------------------------------------------------------------------
// console commands
// ---------------------------------------------------------------------------

h.runCommand('spawnlist', 0);
check('spawn_list prints the points',
  h.captured.logs.some((line) => line.includes('michael_bedroom')),
  h.captured.logs.slice(-3));

h.runCommand('spawn_set', 0, ['michael_bedroom', '-812.5', '175.5', '76.9', '180']);
let [moved] = h.callExport('GetSpawnPoint', 'michael_bedroom');
check('console can move a spawn point', !!moved && moved.y === 175.5 && moved.z === 76.9, moved);
check('heading is saved', !!moved && moved.w === 180, moved && moved.w);

const savedRaw = h.filesystem['data/spawns.json'];
check('spawns.json is written', !!savedRaw, Object.keys(h.filesystem));

let saved = null;
try { saved = JSON.parse(savedRaw); } catch (error) { /* ignore */ }
check('spawns.json is valid JSON', !!saved && typeof saved.spawns === 'object', savedRaw && savedRaw.slice(0, 160));
check('spawns.json stores the new coordinates',
  !!saved && saved.spawns.michael_bedroom.y === 175.5, saved && saved.spawns.michael_bedroom);

h.runCommand('spawn_set', 0, ['outofbounds', '999999', '0', '0']);
check('out of bounds coordinates are refused',
  h.captured.logs.some((line) => line.includes('out_of_bounds')),
  h.captured.logs.slice(-2));

h.runCommand('spawn_set', 0, ['bad']);
check('spawn_set explains its usage',
  h.captured.logs.some((line) => line.includes('Usage: spawn_set')), h.captured.logs.slice(-2));

// ---------------------------------------------------------------------------
// staff gate
// ---------------------------------------------------------------------------

h.captured.client.length = 0;
h.fireNet('fk_spawn:server:setSpawn', 2, ['michael_bedroom', 1, 2, 3, 0]);
const denied = h.captured.client.filter((e) => e.name === 'fk_spawn:client:notify').pop();
check('non-staff cannot move a spawn point',
  !!denied && /staff access/i.test(denied.args[0]), denied && denied.args[0]);

const staffHarness = createHarness({ staff: [2] });
staffHarness.fireNet('fk_spawn:server:setSpawn', 2, ['michael_bedroom', -810, 176, 76.8, 90]);
const [staffMoved] = staffHarness.callExport('GetSpawnPoint', 'michael_bedroom');
check('staff can move a spawn point', !!staffMoved && staffMoved.x === -810, staffMoved);
check('staff changes are saved',
  !!staffHarness.filesystem['data/spawns.json']
  && JSON.parse(staffHarness.filesystem['data/spawns.json']).spawns.michael_bedroom.x === -810);

// ---------------------------------------------------------------------------
// spawning permissions
// ---------------------------------------------------------------------------

h.captured.client.length = 0;
h.fireNet('fk_spawn:server:requestSpawn', 1, [null]);
const spawnMsg = h.captured.client.filter((e) => e.name === 'fk_spawn:client:doSpawn').pop();
check('players can spawn by default',
  !!spawnMsg && spawnMsg.args[0].name === 'michael_bedroom', spawnMsg && spawnMsg.args[0]);
check('the spawn goes to the requesting player', !!spawnMsg && spawnMsg.target === 1, spawnMsg && spawnMsg.target);

h.captured.client.length = 0;
h.fireNet('fk_spawn:server:requestSpawn', 1, ['does_not_exist']);
const unknown = h.captured.client.filter((e) => e.name === 'fk_spawn:client:notify').pop();
check('unknown spawn name is reported',
  !!unknown && /No spawn point/i.test(unknown.args[0]), unknown && unknown.args[0]);

h.captured.client.length = 0;
h.fireNet('fk_spawn:server:requestSpawn', 1, ['michael_bedroom']);
const named = h.captured.client.filter((e) => e.name === 'fk_spawn:client:doSpawn').pop();
check('spawning by name works', !!named && named.args[0].name === 'michael_bedroom', named && named.args[0]);

// ---------------------------------------------------------------------------
// persistence
// ---------------------------------------------------------------------------

const restarted = createHarness({ files: { 'data/spawns.json': savedRaw } });
const [afterRestart] = restarted.callExport('GetSpawnPoint', 'michael_bedroom');
check('moved spawn point survives a restart',
  !!afterRestart && afterRestart.y === 175.5 && afterRestart.z === 76.9, afterRestart);

restarted.runCommand('spawn_reset', 0, ['michael_bedroom']);
const [afterReset] = restarted.callExport('GetSpawnPoint', 'michael_bedroom');
check('spawn_reset restores config.lua values',
  !!afterReset && afterReset.y === 174.85 && afterReset.z === 76.74, afterReset);

restarted.runCommand('spawn_reset', 0, ['michael_bedroom']);
check('resetting twice is refused politely',
  restarted.captured.logs.some((line) => line.includes('already uses the values')),
  restarted.captured.logs.slice(-2));

// ---------------------------------------------------------------------------
// join flag + broadcast
// ---------------------------------------------------------------------------

const joiner = createHarness();
joiner.runThreads(); // boot thread

check('boot reports the version and the default point',
  joiner.captured.logs.some((line) => /Ready \(v[\d.]+\)\. Default spawn: Michael's bedroom/.test(line)),
  joiner.captured.logs);

joiner.fireEvent('playerJoining', 3);
check('a joining player is flagged for a spawn',
  joiner.playerState(3, 'fkSpawnPending') === true, joiner.playerState(3, 'fkSpawnPending'));

joiner.fireNet('fk_spawn:server:isSpawnPending', 3);
let pendingReply = joiner.captured.client.filter((e) => e.name === 'fk_spawn:client:spawnPending').pop();
check('the client is told it should spawn', !!pendingReply && pendingReply.args[0] === true, pendingReply && pendingReply.args);

check('the join schedules a server-side push',
  joiner.captured.threads.length === 1, joiner.captured.threads.length);

joiner.runThreads();
const pushes = joiner.captured.client.filter(
  (e) => e.name === 'fk_spawn:client:doSpawn' && e.args[1] === true,
);
check('the server keeps offering the spawn until the client confirms',
  pushes.length >= 2, pushes.length);
check('the pushed spawn is the bedroom',
  pushes.length > 0 && pushes[0].args[0].name === 'michael_bedroom',
  pushes.length > 0 && pushes[0].args[0]);

joiner.fireNet('fk_spawn:server:spawned', 3, ['michael_bedroom', -812.56, 174.85, 76.74]);
check('other resources are told about the spawn',
  joiner.captured.server.some((e) => e.name === 'fk_spawn:server:playerSpawned'),
  joiner.captured.server);

joiner.captured.client.length = 0;
joiner.fireNet('fk_spawn:server:isSpawnPending', 3);
pendingReply = joiner.captured.client.filter((e) => e.name === 'fk_spawn:client:spawnPending').pop();
check('the flag clears once the player has spawned',
  !!pendingReply && pendingReply.args[0] === false, pendingReply && pendingReply.args);

joiner.fireNet('fk_spawn:server:isSpawnPending', 99);
const strangerReply = joiner.captured.client.filter((e) => e.name === 'fk_spawn:client:spawnPending').pop();
check('players already on the server are not teleported',
  !!strangerReply && strangerReply.args[0] === false, strangerReply && strangerReply.args);

h.captured.client.length = 0;
h.runCommand('spawn_set', 0, ['michael_bedroom', -812.56, 174.85, 76.74, 200]);
const broadcasts = h.captured.client.filter((e) => e.name === 'fk_spawn:client:spawns');
check('moving a point re-syncs every client', broadcasts.length >= 2, broadcasts.length);

// ---------------------------------------------------------------------------
// shared validation helpers
// ---------------------------------------------------------------------------

check('sanitizeName strips apostrophes and spaces',
  luaCallGlobal('Spawn.sanitizeName', ["Michael's Bedroom!"])[0] === 'michaels_bedroom',
  luaCallGlobal('Spawn.sanitizeName', ["Michael's Bedroom!"]));

check('parseCoords reads a coordinate string',
  (() => {
    const [coords] = luaCallGlobal('Spawn.parseCoords', ['-812.56, 174.85, 76.74, 200']);
    return coords && coords.x === -812.56 && coords.w === 200;
  })());

check('parseCoords accepts vector-style tables',
  (() => {
    const [coords] = luaCallGlobal('Spawn.parseCoords', [{ x: 1.5, y: 2.5, z: 3.5 }]);
    return coords && coords.x === 1.5 && coords.y === 2.5 && coords.z === 3.5
      && (coords.w === undefined || coords.w === null);
  })());

check('validateCoords accepts a real position',
  luaCallGlobal('Spawn.validateCoords', [{ x: -812.56, y: 174.85, z: 76.74 }])[0] === true);

check('validateCoords rejects nonsense heights',
  luaCallGlobal('Spawn.validateCoords', [{ x: 0, y: 0, z: 99999 }])[1] === 'out_of_bounds',
  luaCallGlobal('Spawn.validateCoords', [{ x: 0, y: 0, z: 99999 }]));

check('validateCoords rejects NaN',
  luaCallGlobal('Spawn.validateCoords', [{ x: 0, y: 0 }])[1] === 'invalid_coords',
  luaCallGlobal('Spawn.validateCoords', [{ x: 0, y: 0 }]));

check('normalize rejects a point without a name',
  luaCallGlobal('Spawn.normalize', [{ coords: { x: 1, y: 2, z: 3 } }])[1] === 'missing_name',
  luaCallGlobal('Spawn.normalize', [{ coords: { x: 1, y: 2, z: 3 } }]));

check('normalize defaults the heading to 0',
  (() => {
    const [point] = luaCallGlobal('Spawn.normalize', [{ name: 'x', coords: { x: 1, y: 2, z: 3 } }]);
    return point && point.w === 0;
  })());

const [described] = luaCallGlobal('Spawn.describe', [
  { name: 'michael_bedroom', label: "Michael's bedroom", x: -812.56, y: 174.85, z: 76.74 },
]);
check('describe reads like a sentence',
  typeof described === 'string' && described.includes("Michael's bedroom") && described.includes('-812.56'),
  described);

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

if (failures.length) {
  console.log('');
  for (const failure of failures) {
    console.log(`FAIL  ${failure.name}`);
    if (failure.detail !== undefined) console.log(`      got: ${JSON.stringify(failure.detail)}`);
  }
}

const total = pass + failures.length;
console.log(`\n${pass}/${total} spawn checks passed`);
process.exit(failures.length ? 1 : 0);
