/* Loads the fk_house resource inside fengari with mocked FiveM natives, then
   drives the real NUI card in jsdom.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..', 'fk_house');
const FILES = ['config.lua', 'shared/house.lua', 'server/main.lua'];

let pass = 0;
const failures = [];

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
    return;
  }
  failures.push({ name, detail });
}

// ---------------------------------------------------------------------------
// Lua harness
// ---------------------------------------------------------------------------

function createHarness(options = {}) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const captured = { client: [], server: [], logs: [], threads: [] };
  const filesystem = options.files || {};
  const staffIds = new Set(options.staff || []);
  const handlers = {};
  const commands = {};
  const events = {};
  const exportsMap = {};

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
      const isArray = count > 0
        && keys.length === count
        && keys.every((k) => /^\d+$/.test(k))
        && Math.max(...keys.map(Number)) === count;
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
    if (value === null || value === undefined) lua.lua_pushnil(L);
    else if (typeof value === 'boolean') lua.lua_pushboolean(L, value);
    else if (typeof value === 'number') lua.lua_pushnumber(L, value);
    else if (typeof value === 'string') lua.lua_pushstring(L, to_luastring(value));
    else if (Array.isArray(value)) {
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

  setGlobal('GetCurrentResourceName', () => {
    lua.lua_pushstring(L, to_luastring('fk_house'));
    return 1;
  });

  setGlobal('GetResourceMetadata', () => {
    lua.lua_pushstring(L, to_luastring('0.1.0'));
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

  lua.lua_getglobal(L, to_luastring('os'));
  lua.lua_pushcfunction(L, () => {
    lua.lua_pushstring(L, to_luastring('2026-01-01T00:00:00Z'));
    return 1;
  });
  lua.lua_setfield(L, -2, to_luastring('date'));
  lua.lua_pop(L, 1);

  setGlobal('SetTimeout', () => {
    lua.lua_pushvalue(L, 2);
    const ref = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    callRef(ref);
    return 0;
  });

  setGlobal('CreateThread', () => {
    lua.lua_pushvalue(L, 1);
    captured.threads.push(lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX));
    return 0;
  });

  setGlobal('Wait', () => 0);

  setGlobal('GetPlayers', () => {
    lua.lua_createtable(L, 0, 2);
    lua.lua_pushstring(L, to_luastring('1'));
    lua.lua_rawseti(L, -2, 1);
    lua.lua_pushstring(L, to_luastring('2'));
    lua.lua_rawseti(L, -2, 2);
    return 1;
  });

  setGlobal('GetPlayerName', (id) => {
    lua.lua_pushstring(L, to_luastring('Player' + Math.trunc(lua.lua_tonumber(L, 1))));
    return 1;
  });

  setGlobal('GetPlayerIdentifiers', (id) => {
    const source = Math.trunc(lua.lua_tonumber(L, 1));
    lua.lua_createtable(L, 0, 2);
    lua.lua_pushstring(L, to_luastring('license:test' + source));
    lua.lua_rawseti(L, -2, 1);
    lua.lua_pushstring(L, to_luastring('steam:test' + source));
    lua.lua_rawseti(L, -2, 2);
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

  // exports is a table: exports('Name', fn) registers (via __call) and
  // exports.fk_economy:Fn(...) calls another resource.
  lua.lua_newtable(L);
  lua.lua_newtable(L);
  lua.lua_pushcfunction(L, () => {
    const name = to_jsstring(lua.lua_tostring(L, 2));
    lua.lua_pushvalue(L, 3);
    exportsMap[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });
  lua.lua_setfield(L, -2, to_luastring('__call'));
  lua.lua_setmetatable(L, -2);
  lua.lua_setglobal(L, to_luastring('exports'));

  setGlobal('GetResourceState', () => {
    lua.lua_pushstring(L, to_luastring(options.economy ? 'started' : 'missing'));
    return 1;
  });

  setGlobal('IsPlayerAceAllowed', () => {
    const id = Math.trunc(lua.lua_tonumber(L, 1));
    lua.lua_pushboolean(L, staffIds.has(id));
    return 1;
  });

  const economy = options.economyMock;
  if (economy) {
    // FiveM drops the implicit self from exports.resource:Fn(...) calls
    const argOffset = () => (lua.lua_type(L, 1) === lua.LUA_TTABLE ? 1 : 0);

    lua.lua_getglobal(L, to_luastring('exports'));
    lua.lua_createtable(L, 0, 2);

    lua.lua_pushcfunction(L, () => {
      const offset = argOffset();
      const src = Math.trunc(lua.lua_tonumber(L, 1 + offset));
      const item = to_jsstring(lua.lua_tostring(L, 2 + offset));
      const result = economy.purchase(src, item);
      lua.lua_pushboolean(L, result.ok);
      if (result.ok) lua.lua_pushnumber(L, result.balance || 0);
      else lua.lua_pushstring(L, to_luastring(result.error || 'error'));
      return 2;
    });
    lua.lua_setfield(L, -2, to_luastring('TryPurchase'));

    lua.lua_pushcfunction(L, () => {
      const offset = argOffset();
      const item = to_jsstring(lua.lua_tostring(L, 1 + offset));
      lua.lua_pushnumber(L, economy.price(item));
      return 1;
    });
    lua.lua_setfield(L, -2, to_luastring('GetPrice'));

    lua.lua_setfield(L, -2, to_luastring('fk_economy'));
    lua.lua_pop(L, 1);
  }

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
    runThreads() {
      const threads = captured.threads.splice(0, captured.threads.length);
      threads.forEach((ref) => callRef(ref));
    },
  };
}

// ---------------------------------------------------------------------------
// shared/house.lua
// ---------------------------------------------------------------------------

function absIndex(vm, idx) {
  return idx > 0 || idx <= vm.lua.LUA_REGISTRYINDEX ? idx : vm.lua.lua_gettop(vm.state) + idx + 1;
}

function luaValue(vm, relativeIdx) {
  const T = vm.lua;
  const S = vm.state;
  const idx = absIndex(vm, relativeIdx);
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
      obj[luaValue(vm, -2)] = luaValue(vm, -1);
      count += 1;
      T.lua_pop(S, 1);
    }
    const keys = Object.keys(obj);
    const isArray = count > 0
      && keys.length === count
      && keys.every((key) => /^\d+$/.test(key))
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

function luaCallGlobal(pathName, args = []) {
  const vm = createHarness();
  const T = vm.lua;
  const S = vm.state;

  const base = T.lua_gettop(S);
  const parts = pathName.split('.');
  T.lua_getglobal(S, to_luastring(parts[0]));
  for (let i = 1; i < parts.length; i += 1) T.lua_getfield(S, -1, to_luastring(parts[i]));

  T.lua_replace(S, base + 1);
  T.lua_settop(S, base + 1);

  args.forEach((arg) => pushValue(T, S, arg));

  const status = T.lua_pcall(S, args.length, T.LUA_MULTRET, 0);
  if (status !== T.LUA_OK) throw new Error(to_jsstring(T.lua_tostring(S, -1)));

  const results = [];
  for (let i = base + 1; i <= T.lua_gettop(S); i += 1) results.push(luaValue(vm, i));
  return results;
}

const h = createHarness();
h.runThreads(); // boot thread

const [spots] = h.callExport('GetSpots');
check('five interaction spots are configured', Array.isArray(spots) && spots.length === 5, spots && spots.length);

const names = (spots || []).map((spot) => spot.name);
check('spots cover wardrobe, bed, shower, kitchen and living room',
  ['wardrobe', 'bed', 'shower', 'kitchen', 'livingroom'].every((name) => names.includes(name)),
  names);

check('every spot has a sensible radius',
  (spots || []).every((spot) => spot.radius >= 0.5 && spot.radius <= 20),
  (spots || []).map((spot) => spot.radius));

check('boot reports the version and spot count',
  h.captured.logs.some((line) => /Ready \(v[\d.]+\)\. 5 spot\(s\)/.test(line)),
  h.captured.logs);

check('distance is computed in 3D',
  luaCallGlobal('House.distance', [{ x: 0, y: 0, z: 0 }, { x: 3, y: 4, z: 0 }])[0] === 5);

check('nearest spot is found inside its radius',
  (() => {
    const [spot] = luaCallGlobal('House.nearest', [spots, { x: -812.56, y: 174.85, z: 76.74 }]);
    return spot && spot.name === 'bed';
  })());

check('nothing is returned outside every radius',
  luaCallGlobal('House.nearest', [spots, { x: 0, y: 0, z: 0 }])[0] === null);

check('names are sanitised',
  luaCallGlobal('House.sanitizeName', ["Michael's Kitchen!"])[0] === 'michaels_kitchen');

check('a spot without a type is rejected',
  luaCallGlobal('House.normalizeSpot', [{ name: 'x', coords: { x: 1, y: 2, z: 3 } }])[1] === 'missing_type');

check('a spot with a silly radius is rejected',
  luaCallGlobal('House.normalizeSpot', [{ name: 'x', type: 'bed', radius: 99, coords: { x: 1, y: 2, z: 3 } }])[1] === 'invalid_radius');

check('outfits with a bad component are rejected',
  (() => {
    const [ok, reason] = luaCallGlobal('House.normalizeOutfit', [
      { comps: [{ i: 12, d: 1, t: 0 }], props: [] },
    ]);
    return ok === false && reason === 'invalid_component';
  })());

check('outfits with no components are rejected',
  luaCallGlobal('House.normalizeOutfit', [{ comps: [], props: [] }])[1] === 'empty_outfit');

check('a valid outfit is accepted and clamped',
  (() => {
    const [ok, , clean] = luaCallGlobal('House.normalizeOutfit', [
      { comps: [{ i: 3, d: 1, t: 0 }, { i: 11, d: 2, t: 1 }], props: [{ i: 0, d: -1, t: -1 }] },
    ]);
    return ok === true && clean.comps.length === 2 && clean.props[0].d === -1;
  })());

// ---------------------------------------------------------------------------
// server: spots
// ---------------------------------------------------------------------------

h.runCommand('housespots', 0);
check('housespots lists every spot',
  h.captured.logs.filter((line) => line.includes('michael') || line.includes('kitchen')).length >= 0,
  h.captured.logs.slice(-6));

h.runCommand('house_spot', 0, ['kitchen', '-806.25', '173.5', '72.84']);
const [movedSpots] = h.callExport('GetSpots');
const kitchen = (movedSpots || []).find((spot) => spot.name === 'kitchen');
check('console can move a spot', !!kitchen && kitchen.x === -806.25 && kitchen.y === 173.5, kitchen);
check('moved spots are marked', !!kitchen && kitchen.fromOverride === true, kitchen && kitchen.fromOverride);

const spotsRaw = h.filesystem['data/spots.json'];
check('spots.json is written', !!spotsRaw, Object.keys(h.filesystem));

let spotsJson = null;
try { spotsJson = JSON.parse(spotsRaw); } catch (error) { /* ignore */ }
check('spots.json stores the position',
  !!spotsJson && spotsJson.spots.kitchen.x === -806.25, spotsJson && spotsJson.spots.kitchen);

check('every client is re-synced after a move',
  h.captured.client.filter((event) => event.name === 'fk_house:client:spots').length >= 2,
  h.captured.client.length);

h.runCommand('house_spot', 0, ['nope', '1', '2', '3']);
check('unknown spots are refused',
  h.captured.logs.some((line) => line.includes('unknown_spot')), h.captured.logs.slice(-2));

h.runCommand('house_spot', 0, ['kitchen', '999999', '0', '0']);
check('out of bounds positions are refused',
  h.captured.logs.some((line) => line.includes('out_of_bounds')), h.captured.logs.slice(-2));

h.runCommand('house_spot', 0, []);
check('house_spot explains its usage',
  h.captured.logs.some((line) => line.includes('Usage: house_spot')), h.captured.logs.slice(-2));

// staff gate
h.captured.client.length = 0;
h.fireNet('fk_house:server:setSpot', 2, ['kitchen', 1, 2, 3]);
const denied = h.captured.client.filter((event) => event.name === 'fk_house:client:notify').pop();
check('non-staff cannot move a spot', !!denied && /staff access/i.test(denied.args[0]), denied && denied.args[0]);

const staffHarness = createHarness({ staff: [2] });
staffHarness.fireNet('fk_house:server:setSpot', 2, ['shower', -804.5, 171.5, 76.89]);
const [staffSpots] = staffHarness.callExport('GetSpots');
const shower = (staffSpots || []).find((spot) => spot.name === 'shower');
check('staff can move a spot from chat', !!shower && shower.x === -804.5, shower);

// persistence across a restart
const restarted = createHarness({ files: { 'data/spots.json': spotsRaw } });
const [restoredSpots] = restarted.callExport('GetSpots');
const restoredKitchen = (restoredSpots || []).find((spot) => spot.name === 'kitchen');
check('moved spots survive a restart',
  !!restoredKitchen && restoredKitchen.x === -806.25, restoredKitchen);

restarted.runCommand('house_reset', 0, ['kitchen']);
const [resetSpots] = restarted.callExport('GetSpots');
const resetKitchen = (resetSpots || []).find((spot) => spot.name === 'kitchen');
check('house_reset restores config.lua values',
  !!resetKitchen && resetKitchen.x === -802.31, resetKitchen);

// ---------------------------------------------------------------------------
// server: outfits
// ---------------------------------------------------------------------------

const outfit = {
  comps: [{ i: 3, d: 15, t: 0 }, { i: 11, d: 4, t: 1 }],
  props: [{ i: 0, d: -1, t: -1 }],
};

h.fireNet('fk_house:server:saveOutfit', 1, [2, outfit]);
const outfitsRaw = h.filesystem['data/outfits.json'];
check('outfits.json is written', !!outfitsRaw, Object.keys(h.filesystem));

let outfitsJson = null;
try { outfitsJson = JSON.parse(outfitsRaw); } catch (error) { /* ignore */ }
check('outfits are stored per licence',
  !!outfitsJson && !!outfitsJson.players['license:test1'], outfitsJson && Object.keys(outfitsJson.players || {}));
check('the outfit keeps its components',
  !!outfitsJson && outfitsJson.players['license:test1']['2'].comps.length === 2,
  outfitsJson && outfitsJson.players['license:test1']);

h.captured.client.length = 0;
h.fireNet('fk_house:server:requestOutfits', 1);
const outfitReply = h.captured.client.filter((event) => event.name === 'fk_house:client:outfits').pop();
check('the player gets their outfits back',
  !!outfitReply && !!outfitReply.args[0][2], outfitReply && outfitReply.args[0]);

h.fireNet('fk_house:server:saveOutfit', 1, [9, outfit]);
const rejectedSlot = h.captured.client.filter((event) => event.name === 'fk_house:client:notify').pop();
check('out of range slots are refused',
  !!rejectedSlot && /slot does not exist/i.test(rejectedSlot.args[0]), rejectedSlot && rejectedSlot.args[0]);

h.fireNet('fk_house:server:saveOutfit', 1, [1, { comps: [{ i: 99, d: 1, t: 0 }] }]);
const rejectedOutfit = h.captured.client.filter((event) => event.name === 'fk_house:client:notify').pop();
check('invalid outfits are refused',
  !!rejectedOutfit && /could not be saved/i.test(rejectedOutfit.args[0]), rejectedOutfit && rejectedOutfit.args[0]);

const outfitReload = createHarness({ files: { 'data/outfits.json': outfitsRaw } });
outfitReload.captured.client.length = 0;
outfitReload.fireNet('fk_house:server:requestOutfits', 1);
const reloaded = outfitReload.captured.client.filter((event) => event.name === 'fk_house:client:outfits').pop();
check('outfits survive a restart',
  !!reloaded && !!reloaded.args[0][2], reloaded && reloaded.args[0]);

// ---------------------------------------------------------------------------
// server: food purchases
// ---------------------------------------------------------------------------

const economy = createHarness({
  economy: true,
  economyMock: {
    purchase: (src, item) => (item === 'coffee' ? { ok: true, balance: 500 } : { ok: false, error: 'insufficient_funds' }),
    price: (item) => (item === 'coffee' ? 5 : 0),
  },
});

economy.captured.client.length = 0;
economy.fireNet('fk_house:server:buy', 1, ['coffee']);
let buyResult = economy.captured.client.filter((event) => event.name === 'fk_house:client:buyResult').pop();
check('a kitchen item is charged through the economy',
  !!buyResult && buyResult.args[0] === true, buyResult && buyResult.args);

economy.captured.client.length = 0;
economy.fireNet('fk_house:server:buy', 1, ['donut']);
buyResult = economy.captured.client.filter((event) => event.name === 'fk_house:client:buyResult').pop();
check('a failed purchase is reported',
  !!buyResult && buyResult.args[0] === false && buyResult.args[1] === 'insufficient_funds',
  buyResult && buyResult.args);

economy.captured.client.length = 0;
economy.fireNet('fk_house:server:buy', 1, ['bodycam']);
check('items that are not on a menu are ignored',
  economy.captured.client.filter((event) => event.name === 'fk_house:client:buyResult').length === 0,
  economy.captured.client);

const freeFood = createHarness();
freeFood.captured.client.length = 0;
freeFood.fireNet('fk_house:server:buy', 1, ['coffee']);
const freeResult = freeFood.captured.client.filter((event) => event.name === 'fk_house:client:buyResult').pop();
check('food is free when the economy is not running',
  !!freeResult && freeResult.args[0] === true, freeResult && freeResult.args);

// ---------------------------------------------------------------------------
// NUI card (jsdom)
// ---------------------------------------------------------------------------

const HTML = path.join(ROOT, 'html', 'index.html');

JSDOM.fromFile(HTML, { runScripts: 'dangerously', resources: 'usable', pretendToBeVisual: true })
  .then((dom) => new Promise((resolve) => {
    if (dom.window.document.readyState === 'complete') resolve(dom);
    else dom.window.addEventListener('load', () => resolve(dom));
  }))
  .then((dom) => {
    const win = dom.window;
    const doc = win.document;
    const card = doc.getElementById('card');

    check('the NUI page exposes houseUI', typeof win.houseUI === 'object', typeof win.houseUI);

    check('the card starts hidden', card.classList.contains('is-hidden'));

    const count = win.houseUI.show({
      title: 'Wardrobe',
      subtitle: 'Personal wardrobe',
      footer: 'Press the number to choose',
      options: [
        { index: 1, label: 'Wear outfit 1', hint: '11 pieces' },
        { index: 2, label: 'Save this look to slot 2', hint: 'Empty' },
        { index: 3, label: 'Put my clothes back on', hint: 'What you arrived in' },
      ],
    });

    check('show renders every option', count === 3, count);
    check('the card becomes visible', !card.classList.contains('is-hidden'));

    const rows = doc.querySelectorAll('#options .option');
    check('three rows are rendered', rows.length === 3, rows.length);
    check('the first row keeps its label',
      rows[0].querySelector('.option__label').textContent === 'Wear outfit 1',
      rows[0] && rows[0].textContent);
    check('the hint is rendered',
      rows[0].querySelector('.option__hint').textContent === '11 pieces');
    check('the key number is rendered', rows[1].querySelector('.option__key').textContent === '2');
    check('the title is shown', doc.getElementById('title').textContent === 'Wardrobe');
    check('the footer is shown', doc.getElementById('footer').textContent === 'Press the number to choose');

    win.houseUI.hide();
    check('hide clears the rows', doc.querySelectorAll('#options .option').length === 0);
    check('hide hides the card', card.classList.contains('is-hidden'));

    // messages from Lua
    win.postMessage({ action: 'show', data: { title: 'Kitchen', options: [{ index: 1, label: 'Make a sandwich' }] } }, '*');
    setTimeout(() => {
      check('the Lua message shows the card',
        !card.classList.contains('is-hidden') && doc.querySelectorAll('#options .option').length === 1);

      win.postMessage({ action: 'hide' }, '*');
      setTimeout(() => {
        check('the Lua hide message hides the card', card.classList.contains('is-hidden'));

        report();
      }, 20);
    }, 20);
  })
  .catch((error) => {
    check('the NUI page loads', false, error && error.message);
    report();
  });

function report() {
  if (failures.length) {
    console.log('');
    for (const failure of failures) {
      console.log(`FAIL  ${failure.name}`);
      if (failure.detail !== undefined) console.log(`      got: ${JSON.stringify(failure.detail)}`);
    }
  }

  const total = pass + failures.length;
  console.log(`\n${pass}/${total} house checks passed`);
  process.exit(failures.length ? 1 : 0);
}
