/* Loads the fk_house resource inside fengari with mocked FiveM natives, then
   drives the real NUI card in jsdom.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..', 'fk_house');
const FILES = ['config.lua', 'shared/core.lua', 'shared/house.lua', 'shared/garage.lua', 'server/main.lua', 'server/garage.lua'];

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
  let waitCalls = 0;

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

  // A real Wait yields the thread. Here it just counts, so that a `while true`
  // thread (the garage watchdog) is stopped instead of hanging the test run.
  setGlobal('Wait', () => {
    waitCalls += 1;

    if (waitCalls > 400) {
      lua.lua_pushstring(L, to_luastring('thread stopped by the test harness'));
      lua.lua_error(L);
    }

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


  // -------------------------------------------------------------------------
  // Vehicle world (garage)
  // -------------------------------------------------------------------------
  // fengari has no vector3, so GetEntityCoords returns a { x, y, z } table -
  // which is exactly what House.readCoords() accepts.
  const joaat = (value) => {
    let h = 0;
    const str = String(value).toLowerCase();
    for (let i = 0; i < str.length; i += 1) {
      h = (h + str.charCodeAt(i)) >>> 0;
      h = (h + (h << 10)) >>> 0;
      h = (h ^ (h >>> 6)) >>> 0;
    }
    h = (h + (h << 3)) >>> 0;
    h = (h ^ (h >>> 11)) >>> 0;
    return (h + (h << 15)) >>> 0;
  };

  let nextVehicleEntity = 5000;
  const vehicleWorld = new Map();
  const vehicleCalls = { created: [], deleted: [], orphan: [], coords: [] };
  const pedCoords = options.pedCoords || { x: -810.53, y: 187.79, z: 71.48 };
  // Simulates the tick or two the game needs before a server-created entity is
  // registered, which is what made the old code report create_failed.
  let hideNewVehicles = options.hideNewVehicles === true;
  let clock = 0;

  setGlobal('GetGameTimer', () => {
    lua.lua_pushnumber(L, clock);
    return 1;
  });

  function makeVehicle(entry = {}) {
    const entity = nextVehicleEntity++;
    const netId = 100000 + entity;
    vehicleWorld.set(entity, {
      netId,
      model: joaat(entry.model || 'adder'),
      modelName: String(entry.model || 'adder').toLowerCase(),
      x: entry.x === undefined ? -810.53 : entry.x,
      y: entry.y === undefined ? 187.79 : entry.y,
      z: entry.z === undefined ? 71.6 : entry.z,
      w: entry.w === undefined ? 110.0 : entry.w,
      exists: !hideNewVehicles,
      hidden: hideNewVehicles,
    });
    return { entity, netId };
  }

  setGlobal('CreateVehicle', () => {
    const hash = Math.trunc(lua.lua_tonumber(L, 1));
    const x = lua.lua_tonumber(L, 2);
    const y = lua.lua_tonumber(L, 3);
    const z = lua.lua_tonumber(L, 4);
    const w = lua.lua_tonumber(L, 5);
    const handle = makeVehicle({ x, y, z, w });
    vehicleWorld.get(handle.entity).model = hash >>> 0;
    vehicleCalls.created.push({ entity: handle.entity, hash: hash >>> 0, x, y, z, w });
    lua.lua_pushnumber(L, handle.entity);
    return 1;
  });

  setGlobal('DoesEntityExist', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    lua.lua_pushboolean(L, !!(entry && entry.exists));
    return 1;
  });

  setGlobal('GetEntityType', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    lua.lua_pushnumber(L, entry && entry.exists ? 2 : 0);
    return 1;
  });

  setGlobal('GetEntityModel', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    lua.lua_pushnumber(L, entry ? entry.model : 0);
    return 1;
  });

  setGlobal('GetHashKey', () => {
    const value = to_jsstring(lua.lua_tostring(L, 1));
    lua.lua_pushnumber(L, joaat(value));
    return 1;
  });

  setGlobal('NetworkGetNetworkIdFromEntity', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    lua.lua_pushnumber(L, entry ? entry.netId : 0);
    return 1;
  });

  setGlobal('NetworkGetEntityFromNetworkId', () => {
    const netId = Math.trunc(lua.lua_tonumber(L, 1));
    for (const [entity, entry] of vehicleWorld) {
      if (entry.netId === netId && entry.exists) {
        lua.lua_pushnumber(L, entity);
        return 1;
      }
    }
    lua.lua_pushnumber(L, 0);
    return 1;
  });

  setGlobal('GetPlayerPed', () => {
    const source = Math.trunc(lua.lua_tonumber(L, 1));
    lua.lua_pushnumber(L, 1000 + source);
    return 1;
  });

  setGlobal('GetEntityCoords', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    pushJs(entry ? { x: entry.x, y: entry.y, z: entry.z } : { ...pedCoords });
    return 1;
  });

  setGlobal('GetEntityHeading', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    lua.lua_pushnumber(L, entry ? entry.w : 0);
    return 1;
  });

  setGlobal('SetEntityOrphanMode', () => {
    vehicleCalls.orphan.push([Math.trunc(lua.lua_tonumber(L, 1)), Math.trunc(lua.lua_tonumber(L, 2))]);
    return 0;
  });

  setGlobal('DeleteEntity', () => {
    const entity = Math.trunc(lua.lua_tonumber(L, 1));
    const entry = vehicleWorld.get(entity);
    if (entry) entry.exists = false;
    vehicleCalls.deleted.push(entity);
    return 0;
  });

  setGlobal('SetEntityCoords', () => {
    vehicleCalls.coords.push(Math.trunc(lua.lua_tonumber(L, 1)));
    return 0;
  });

  setGlobal('SetEntityHeading', () => 0);

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
    joaat,
    makeVehicle,
    vehicleCalls,
    vehicleWorld,
    advance(ms) { clock += Number(ms) || 0; },
    revealVehicles() {
      hideNewVehicles = false;

      for (const entry of vehicleWorld.values()) {
        if (entry.hidden) {
          entry.hidden = false;
          entry.exists = true;
        }
      }
    },
    hideNewVehicles(value = true) { hideNewVehicles = value === true; },
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
      threads.forEach((ref) => {
        waitCalls = 0;
        try {
          callRef(ref);
        } catch (error) {
          // long-running threads are cut off by the Wait guard above
          if (String(error && error.message).indexOf('test harness') === -1) throw error;
        }
      });
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

// Read a global (or a field of one) without calling it.
function luaReadGlobal(pathName) {
  const vm = createHarness();
  const T = vm.lua;
  const S = vm.state;
  const parts = pathName.split('.');

  T.lua_getglobal(S, to_luastring(parts[0]));
  for (let i = 1; i < parts.length; i += 1) T.lua_getfield(S, -1, to_luastring(parts[i]));

  const value = luaValue(vm, -1);
  T.lua_settop(S, 0);
  return value;
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

check('the data folder exists (SaveResourceFile cannot create it)',
  fs.existsSync(path.join(ROOT, 'data')),
  path.join(ROOT, 'data'));

const h = createHarness();
h.runThreads(); // boot thread

const [spots] = h.callExport('GetSpots');
check('six interaction spots are configured', Array.isArray(spots) && spots.length === 6, spots && spots.length);

const names = (spots || []).map((spot) => spot.name);
check('spots cover wardrobe, bed, shower, kitchen, living room and garage',
  ['wardrobe', 'bed', 'shower', 'kitchen', 'livingroom', 'garage'].every((name) => names.includes(name)),
  names);

check('every spot has a sensible radius',
  (spots || []).every((spot) => spot.radius >= 0.5 && spot.radius <= 20),
  (spots || []).map((spot) => spot.radius));

// The coordinates in config.lua are derived from the game's own interior data
// (docs/COORDINATES.md): v_michael's MLO origin is -807.343, 174.981, 71.163,
// the ground floor is z 71.85 and the upstairs floor is z 75.74.
const house = luaReadGlobal('Config.House') || {};

const houseCentre = house.coords || {};

check('house centre is the v_michael MLO origin',
  Math.abs(houseCentre.x + 807.343) < 0.01 && Math.abs(houseCentre.y - 174.981) < 0.01
    && Math.abs(houseCentre.z - 71.163) < 0.01,
  house);

check('spots are gated by floor as well as distance',
  typeof house.zTolerance === 'number' && house.zTolerance > 0 && house.zTolerance < 3.9,
  house.zTolerance);

const FLOORS = { upstairs: 75.74, ground: 71.85 };
const ROOMS = {
  wardrobe: { x: [-815, -810], y: [173, 177.5], floor: 'upstairs' },
  bed: { x: [-817, -809], y: [176, 183], floor: 'upstairs' },
  shower: { x: [-807, -802], y: [166.5, 172.5], floor: 'upstairs' },
  kitchen: { x: [-806.5, -794.5], y: [182, 190], floor: 'ground' },
  livingroom: { x: [-808, -800], y: [171, 179], floor: 'ground' },
};

Object.entries(ROOMS).forEach(([name, room]) => {
  const spot = (spots || []).find((entry) => entry.name === name);

  check(`${name} sits in the room it belongs to`,
    !!spot && spot.x >= room.x[0] && spot.x <= room.x[1]
      && spot.y >= room.y[0] && spot.y <= room.y[1],
    spot);

  check(`${name} is on the ${room.floor} floor`,
    !!spot && Math.abs(spot.z - FLOORS[room.floor]) < 0.35,
    spot && spot.z);

  check(`${name} is inside the house radius`,
    !!spot && Math.hypot(spot.x - houseCentre.x, spot.y - houseCentre.y) <= house.radius,
    spot);
});

check('an upstairs spot does not fire from the floor below',
  luaCallGlobal('House.nearest', [spots, { x: -804.6, y: 169.9, z: 71.85 }, house.zTolerance])[0] === null);

check('the same spot fires when you are on its floor',
  (() => {
    const [spot] = luaCallGlobal('House.nearest', [spots, { x: -804.6, y: 169.9, z: 75.8 }, house.zTolerance]);
    return spot && spot.name === 'shower';
  })());

check('boot reports the version and spot count',
  h.captured.logs.some((line) => /Ready \(v[\d.]+\)\. 6 spot\(s\)/.test(line)),
  h.captured.logs);

check('distance is computed in 3D',
  luaCallGlobal('House.distance', [{ x: 0, y: 0, z: 0 }, { x: 3, y: 4, z: 0 }])[0] === 5);

// GetEntityCoords() returns a vector3, whose Lua type is NOT 'table'. A
// type == 'table' check here returned nil and killed the interaction loop.
const positionTypes = luaReadGlobal('House.positionTypes') || {};
check('vector3 is an accepted position type', positionTypes.vector3 === true, positionTypes);

check('vector4 is an accepted position type', positionTypes.vector4 === true);

check('readCoords pulls x/y/z out of a position',
  luaCallGlobal('House.readCoords', [{ x: 1, y: 2, z: 3 }]).join(',') === '1,2,3');

check('distance survives a bogus position instead of erroring',
  luaCallGlobal('House.distance', ['nope', { x: 0, y: 0, z: 0 }])[0] === null);

check('nearest spot is found inside its radius',
  (() => {
    const [spot] = luaCallGlobal('House.nearest', [spots, { x: -812.56, y: 174.85, z: 75.8 }]);
    return spot && spot.name === 'wardrobe';
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
  !!resetKitchen && resetKitchen.x === -800, resetKitchen);

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
// Garage: a parked car is persisted and comes back as the same model
// ---------------------------------------------------------------------------

const manifestSource = fs.readFileSync(path.join(ROOT, 'fxmanifest.lua'), 'utf8');
check('the manifest loads the shared, server and client garage files',
  ['shared/garage.lua', 'server/garage.lua', 'client/garage.lua']
    .every((file) => manifestSource.indexOf(file) !== -1),
  manifestSource.match(/garage\.lua/g));

const clientGarage = fs.readFileSync(path.join(ROOT, 'client', 'garage.lua'), 'utf8');
check('the client marks the car as a mission entity',
  /SetEntityAsMissionEntity/.test(clientGarage));
check('the client flags it as owned by the player',
  /SetVehicleHasBeenOwnedByPlayer\(veh, true\)/.test(clientGarage));
check('the client gives it a huge culling radius',
  /SetEntityDistanceCullingRadius/.test(clientGarage));
check('the client reads the real model from the entity',
  /GetDisplayNameFromVehicleModel\(GetEntityModel\(veh\)\)/.test(clientGarage));

const garageCfg = luaReadGlobal('Config.Garage') || {};
const garageCoords = garageCfg.coords || {};
const garageSpawn = garageCfg.spawn || {};

check('the garage is configured on the garage floor',
  Math.abs(garageCoords.x + 811.33) < 0.1 && Math.abs(garageCoords.y - 187.51) < 0.1,
  garageCoords);
check('the car has a spawn point inside the garage',
  Math.abs(garageSpawn.x - garageCoords.x) < 2 && Math.abs(garageSpawn.y - garageCoords.y) < 2,
  garageSpawn);
check('the car is a personal vehicle (huge culling radius)',
  typeof garageCfg.cullDistance === 'number' && garageCfg.cullDistance >= 1000,
  garageCfg.cullDistance);
check('the car is respawned if it ever disappears', garageCfg.respawn !== false);

const garageSpot = (spots || []).find((spot) => spot.name === 'garage');
check('there is a garage interaction spot',
  !!garageSpot && garageSpot.type === 'garage', garageSpot);
check('the garage spot is inside the garage interior',
  !!garageSpot && Math.abs(garageSpot.x + 811.33) < 1.0 && Math.abs(garageSpot.y - 187.51) < 1.0,
  garageSpot);
check('the garage spot sits on the garage floor',
  !!garageSpot && Math.abs(garageSpot.z - 71.47) < 0.35, garageSpot && garageSpot.z);

check('model names are lower-cased and trimmed',
  luaCallGlobal('Garage.normalizeModel', ['  Adder '])[0] === 'adder');
check('nonsense model names are refused',
  luaCallGlobal('Garage.normalizeModel', ['!!!'])[0] === null);
check('blocked models are recognised',
  luaCallGlobal('Garage.isBlocked', ['rhino', ['rhino']])[0] === true
    && luaCallGlobal('Garage.isBlocked', ['adder', ['rhino']])[0] === false);
check('plates are upper-cased and trimmed',
  luaCallGlobal('Garage.normalizePlate', [' fk 1234!'])[0] === 'FK 1234');
check('empty plates are refused', luaCallGlobal('Garage.normalizePlate', [''])[0] === null);
check('saved vehicles are normalised',
  (() => {
    const entry = luaCallGlobal('Garage.normalizeVehicle',
      [{ model: ' Adder', plate: 'fk 1', x: -810.4, y: 187.6, z: 71.6, w: 455.5 }])[0];
    return !!entry && entry.model === 'adder' && entry.plate === 'FK 1' && entry.w === 95.5;
  })());
check('a vehicle inside the garage is in the zone',
  luaCallGlobal('Garage.inZone', [{ x: -810.4, y: 187.6, z: 71.6 }, garageCoords, garageCfg.radius])[0] === true);
check('a vehicle down the street is not',
  luaCallGlobal('Garage.inZone', [{ x: -760, y: 187.6, z: 71.6 }, garageCoords, garageCfg.radius])[0] === false);
check('a car parked in the garage keeps its own spot',
  (() => {
    const [x, y, , w] = luaCallGlobal('Garage.spawnPoint',
      [{ model: 'adder', x: -810.4, y: 187.6, z: 71.6, w: 95 }, garageCfg]);
    return Math.abs(x + 810.4) < 0.01 && Math.abs(y - 187.6) < 0.01 && w === 95;
  })());
check('a saved car outside the garage falls back to the spawn point',
  luaCallGlobal('Garage.spawnPoint',
    [{ model: 'adder', x: -500, y: 100, z: 30, w: 0 }, garageCfg])[0] === garageSpawn.x);

// --- parking ---------------------------------------------------------------
const garage = createHarness();
const parked = garage.makeVehicle({ model: 'adder', x: -810.4, y: 187.6, z: 71.6, w: 95 });
garage.fireNet('fk_house:server:garage:park', 1, [parked.netId, 'Adder', 'fk 1234']);

const parkedState = garage.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').pop();
check('parking stores the car for that player',
  !!parkedState && !!parkedState.args[0] && parkedState.args[0].model === 'adder',
  parkedState && parkedState.args);
check('the model survives the round trip exactly',
  !!parkedState && parkedState.args[0].model === 'adder', parkedState && parkedState.args[0]);
check('the model hash is stored next to the name',
  !!parkedState && parkedState.args[0].hash === garage.joaat('adder'),
  parkedState && parkedState.args[0]);
check('the plate is stored in upper case',
  !!parkedState && parkedState.args[0].plate === 'FK 1234', parkedState && parkedState.args[0]);

const garageFile = garage.filesystem['data/garage.json'];
check('the car is written to data/garage.json',
  typeof garageFile === 'string' && garageFile.indexOf('"adder"') !== -1,
  garageFile && garageFile.slice(0, 120));
check('the file is keyed by the player licence',
  (() => {
    try {
      return !!JSON.parse(garageFile).vehicles['license:test1'];
    } catch (error) {
      return false;
    }
  })());

// --- it comes back ---------------------------------------------------------
// Pretend the car was culled / the player logged out: the entity is gone but
// the record survives, which is exactly what a reconnect looks like.
garage.vehicleWorld.get(parked.entity).exists = false;

garage.captured.client.length = 0;
garage.fireNet('fk_house:server:garage:spawn', 1, []);

const spawnedEvent = garage.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:spawned').pop();
check('asking for the car sends the client a net id',
  !!spawnedEvent && typeof spawnedEvent.args[0] === 'number' && spawnedEvent.args[0] > 0,
  spawnedEvent && spawnedEvent.args);
check('the car is created with the stored model',
  garage.vehicleCalls.created.some((call) => call.hash === garage.joaat('adder')),
  garage.vehicleCalls.created.map((call) => call.hash));
check('it is created inside the garage',
  garage.vehicleCalls.created.some((call) =>
    Math.abs(call.x + 810.4) < 1.0 && Math.abs(call.y - 187.6) < 1.0),
  garage.vehicleCalls.created);
check('it is orphaned so it never despawns without its owner',
  garage.vehicleCalls.orphan.some(([, mode]) => mode === 2),
  garage.vehicleCalls.orphan);

// --- a restart gives the same car ------------------------------------------
const garageRestart = createHarness({ files: { 'data/garage.json': garageFile } });
garageRestart.fireNet('fk_house:server:garage:request', 1, []);
const restored = garageRestart.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').pop();
check('the saved car survives a restart',
  !!restored && !!restored.args[0] && restored.args[0].model === 'adder',
  restored && restored.args);
garageRestart.fireNet('fk_house:server:garage:spawn', 1, []);
check('and spawns again as the identical model',
  garageRestart.vehicleCalls.created.some((call) => call.hash === garageRestart.joaat('adder')),
  garageRestart.vehicleCalls.created.map((call) => call.hash));

// --- refusals --------------------------------------------------------------
const outside = createHarness();
const streetCar = outside.makeVehicle({ model: 'sultan', x: -760, y: 150, z: 60 });
outside.fireNet('fk_house:server:garage:park', 1, [streetCar.netId, 'sultan', '']);
check('a car outside the garage is refused',
  outside.captured.client.some((event) => event.name === 'fk_house:client:notify'
    && /garage first/i.test(String(event.args[0]))),
  outside.captured.client);

const spoofed = createHarness();
const stolen = spoofed.makeVehicle({ model: 'adder', x: -810.4, y: 187.6, z: 71.6 });
spoofed.fireNet('fk_house:server:garage:park', 1, [stolen.netId, 'titan', '']);
spoofed.vehicleWorld.get(stolen.entity).exists = false;
spoofed.fireNet('fk_house:server:garage:spawn', 1, []);
check('a spoofed model name cannot change the stored model',
  spoofed.vehicleCalls.created.some((call) => call.hash === spoofed.joaat('adder'))
    && !spoofed.vehicleCalls.created.some((call) => call.hash === spoofed.joaat('titan')),
  spoofed.vehicleCalls.created.map((call) => call.hash));

const blocked = createHarness();
// Config.Garage.blockedModels = { 'rhino' }
blocked.lua.lua_getglobal(blocked.state, to_luastring('Config'));
blocked.lua.lua_getfield(blocked.state, -1, to_luastring('Garage'));
blocked.lua.lua_createtable(blocked.state, 1, 0);
blocked.lua.lua_pushstring(blocked.state, to_luastring('rhino'));
blocked.lua.lua_rawseti(blocked.state, -2, 1);
blocked.lua.lua_setfield(blocked.state, -2, to_luastring('blockedModels'));
blocked.lua.lua_settop(blocked.state, 0);

const tank = blocked.makeVehicle({ model: 'rhino', x: -810.4, y: 187.6, z: 71.6 });
blocked.fireNet('fk_house:server:garage:park', 1, [tank.netId, 'adder', '']);
check('a blocked model is refused by hash even with a fake name',
  blocked.captured.client.some((event) => event.name === 'fk_house:client:notify'
    && /cannot be kept in the garage/i.test(String(event.args[0]))),
  blocked.captured.client);
check('nothing is written for a refused park', !blocked.filesystem['data/garage.json']);

const ghost = createHarness();
ghost.fireNet('fk_house:server:garage:park', 1, [999999, 'adder', '']);
check('a made-up net id is refused',
  ghost.captured.client.some((event) => event.name === 'fk_house:client:notify'
    && /gone/i.test(String(event.args[0]))),
  ghost.captured.client);

const nothing = createHarness();
nothing.fireNet('fk_house:server:garage:spawn', 1, []);
check('asking to spawn with an empty garage explains why',
  nothing.captured.client.some((event) => event.name === 'fk_house:client:notify'
    && /no car saved/i.test(String(event.args[0]))),
  nothing.captured.client);

// --- console command -------------------------------------------------------
garage.runCommand('garage_list', 0, []);
check('garage_list prints the stored car on the server console',
  garage.captured.logs.some((line) => line.indexOf('adder (FK 1234)') !== -1),
  garage.captured.logs.filter((line) => line.indexOf('adder') !== -1));

// --- forgetting ------------------------------------------------------------
garage.fireNet('fk_house:server:garage:forget', 1, []);
const cleared = garage.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').pop();
check('forgetting the car clears the saved record',
  !!cleared && cleared.args[0] === null, cleared && cleared.args);
check('forgetting deletes the live car',
  garage.vehicleCalls.deleted.length > 0, garage.vehicleCalls.deleted);
check('the saved file is emptied too',
  (() => {
    try {
      return Object.keys(JSON.parse(garage.filesystem['data/garage.json']).vehicles).length === 0;
    } catch (error) {
      return false;
    }
  })(), garage.filesystem['data/garage.json']);

// ---------------------------------------------------------------------------
// Garage: appearance, /carreset, rate limits and crash safety
// ---------------------------------------------------------------------------

check('a full paint job survives validation',
  (() => {
    const clean = luaCallGlobal('Garage.normalizeAppearance', [{
      colors: { primary: 12, secondary: 3, custom: { r: 255, g: 10, b: 0 } },
      tint: 2,
      wheelType: 3,
      mods: { '0': 4, '11': 2, '18': 1 },
      extras: { '3': 1, '5': 0 },
    }])[0];

    return !!clean
      && clean.colors.primary === 12
      && clean.colors.custom.r === 255
      && clean.mods['0'] === 4
      && clean.extras['3'] === 1
      && clean.extras['5'] === 0
      && clean.tint === 2;
  })());

check('out-of-range appearance values are dropped, not stored',
  (() => {
    const clean = luaCallGlobal('Garage.normalizeAppearance', [{
      tint: 99,
      mods: { '0': 400, '60': 1 },
      wheelType: 1,
    }])[0];

    return !!clean && clean.tint === undefined && !clean.mods && clean.wheelType === 1;
  })());

check('an empty appearance is not stored', luaCallGlobal('Garage.normalizeAppearance', [{}])[0] === null);
check('a non-table appearance is refused', luaCallGlobal('Garage.normalizeAppearance', ['adder'])[0] === null);

const styled = createHarness();
const styledCar = styled.makeVehicle({ model: 'adder', x: -811.3, y: 187.5, z: 71.6 });
styled.fireNet('fk_house:server:garage:park', 1, [
  styledCar.netId, 'adder', 'FK 1',
  { colors: { primary: 12, secondary: 3 }, tint: 1, mods: { '0': 4 }, extras: { '1': 1 } },
]);

const styledFile = styled.filesystem['data/garage.json'];
check('the paint job is saved with the car',
  typeof styledFile === 'string' && styledFile.indexOf('"primary":12') !== -1
    && styledFile.indexOf('"mods"') !== -1,
  typeof styledFile === 'string' ? styledFile.slice(0, 200) : styledFile);

const styledState = styled.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').pop();
check('the client is told the appearance so it can re-apply it',
  !!styledState && styledState.args[0].appearance
    && styledState.args[0].appearance.colors.primary === 12,
  styledState && styledState.args[0]);

// -- /carreset --------------------------------------------------------------
styled.vehicleWorld.get(styledCar.entity).exists = false;
styled.runCommand('carreset', 1, []);

check('the car can be put back on the garage floor',
  styled.vehicleCalls.created.some((call) =>
    Math.abs(call.x + 811.33) < 0.1 && Math.abs(call.y - 187.51) < 0.1),
  styled.vehicleCalls.created);

styled.captured.client.length = 0;
styled.runCommand('carreset', 1, []);
const resetChat = JSON.stringify(styled.captured.client);
check('the reset cooldown is enforced', resetChat.indexOf('again in') !== -1, resetChat.slice(0, 160));

const emptyReset = createHarness();
emptyReset.runCommand('carreset', 1, []);
check('resetting with an empty garage explains why',
  JSON.stringify(emptyReset.captured.client).indexOf('no car saved') !== -1,
  emptyReset.captured.client);

// -- rate limits ------------------------------------------------------------
const floodGarage = createHarness();
const floodCar = floodGarage.makeVehicle({ model: 'adder', x: -811.3, y: 187.5, z: 71.6 });
for (let i = 0; i < 40; i += 1) {
  floodGarage.fireNet('fk_house:server:garage:park', 1, [floodCar.netId, 'adder', 'FK 1']);
}
const parkStates = floodGarage.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').length;
check('garage parking is rate limited', parkStates > 0 && parkStates <= 6, parkStates);

const floodOutfits = createHarness();
for (let i = 0; i < 40; i += 1) {
  floodOutfits.fireNet('fk_house:server:requestOutfits', 1);
}
check('outfit requests are rate limited too',
  floodOutfits.captured.client.filter((event) => event.name === 'fk_house:client:outfits').length <= 10,
  floodOutfits.captured.client.length);

// -- crash safety -----------------------------------------------------------
const recoveredGarage = createHarness({
  files: {
    'data/garage.json': '{"vehicles": {"license:test1": tru',
    'data/garage.bak.json': JSON.stringify({
      version: 1,
      vehicles: {
        'license:test1': { model: 'adder', hash: 782665360, plate: 'FK 9', x: -811.3, y: 187.5, z: 71.6, w: 90 },
      },
    }),
  },
});

recoveredGarage.fireNet('fk_house:server:garage:request', 1, []);
const recoveredState = recoveredGarage.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:state').pop();
check('a corrupt garage.json falls back to the backup',
  !!recoveredState && !!recoveredState.args[0] && recoveredState.args[0].model === 'adder',
  recoveredState && recoveredState.args);

// -- /housestatus -----------------------------------------------------------
styled.captured.client.length = 0;
styled.runCommand('housestatus', 0, []);
const statusLog = styled.captured.logs.join('\n');
check('/housestatus reports spots and cars',
  statusLog.indexOf('spot(s)') !== -1 && statusLog.indexOf('car(s)') !== -1,
  statusLog.split('\n').slice(-3));

// ---------------------------------------------------------------------------
// The reported bug: "could not be spawned (create_failed)" for a car that was
// actually there, followed by another car on every retry
// ---------------------------------------------------------------------------

check('model hashes are normalised to unsigned',
  luaCallGlobal('Garage.normalizeHash', [-1])[0] === 4294967295
    && luaCallGlobal('Garage.normalizeHash', [4294967295])[0] === 4294967295
    && luaCallGlobal('Garage.normalizeHash', [0])[0] === null);

check('a negative hash is kept on the saved vehicle',
  (() => {
    const entry = luaCallGlobal('Garage.normalizeVehicle',
      [{ model: 'adder', plate: 'fk', x: 0, y: 0, z: 0, hash: -1234 }])[0];
    return !!entry && entry.hash === 4294966062;
  })());

// A record written before the hash was normalised (so it is negative) must
// still spawn the same car.
const legacyHash = createHarness({
  files: {
    'data/garage.json': JSON.stringify({
      version: 1,
      vehicles: {
        'license:test1': {
          model: 'adder', hash: -1234, plate: 'FK 1', x: -811.3, y: 187.5, z: 71.6, w: 90,
        },
      },
    }),
  },
});

legacyHash.fireNet('fk_house:server:garage:spawn', 1, []);
check('a negative stored hash spawns the same car',
  legacyHash.vehicleCalls.created.length === 1
    && legacyHash.vehicleCalls.created[0].hash === 4294966062,
  legacyHash.vehicleCalls.created);

// The regression itself: the entity takes a tick to register. That must be
// "still coming", never "failed", and must not create a second car.
const slow = createHarness();
const slowParked = slow.makeVehicle({ model: 'adder', x: -811.3, y: 187.5, z: 71.6 });
slow.fireNet('fk_house:server:garage:park', 1, [slowParked.netId, 'adder', 'FK 1']);
check('the reported-bug harness parked a car first',
  (() => {
    const raw = slow.filesystem['data/garage.json'];
    if (!raw) return false;
    return Object.values(JSON.parse(raw).vehicles).some((veh) => veh.model === 'adder');
  })(), slow.filesystem['data/garage.json']);

// The parked car is impounded/despawned, so it has to be created again - and
// the server-side entity does not exist yet on the tick it is created.
slow.vehicleWorld.get(slowParked.entity).exists = false;
slow.hideNewVehicles(true);
slow.captured.client.length = 0;

slow.fireNet('fk_house:server:garage:spawn', 1, []);
check('a car that is still registering is not reported as failed',
  !slow.captured.client.some((event) => event.name === 'fk_house:client:notify'),
  slow.captured.client);

slow.fireNet('fk_house:server:garage:spawn', 1, []);
check('retrying while the car is registering does not create a second car',
  slow.vehicleCalls.created.length === 1, slow.vehicleCalls.created.length);

slow.revealVehicles();
slow.runThreads();

const slowSpawned = slow.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:spawned').pop();
check('the client gets the net id once the car registers',
  !!slowSpawned && typeof slowSpawned.args[0] === 'number' && slowSpawned.args[0] > 0,
  slowSpawned && slowSpawned.args);

slow.captured.client.length = 0;
slow.fireNet('fk_house:server:garage:spawn', 1, []);
const reused = slow.captured.client
  .filter((event) => event.name === 'fk_house:client:garage:spawned').pop();
check('a third request reuses the car instead of creating one',
  !!reused && slow.vehicleCalls.created.length === 1,
  { created: slow.vehicleCalls.created.length, reused: reused && reused.args[0] });

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
