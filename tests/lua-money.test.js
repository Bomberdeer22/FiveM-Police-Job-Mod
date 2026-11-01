/* Loads the fk_economy Lua resource inside fengari (a Lua VM in JS) with
   mocked FiveM natives, then exercises the money API, staff validation,
   purchases, commands and JSON persistence.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const ROOT = path.join(__dirname, '..', 'fk_economy');
const FILES = [
  'config.lua',
  'shared/utils.lua',
  'server/accounts.lua',
  'server/staff.lua',
  'server/main.lua',
  'server/commands.lua',
];

function createHarness(options = {}) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const captured = { client: [], server: [], chat: [], logs: [], saves: {} };
  const playerList = options.players || [];
  const filesystem = options.files || {};
  const settings = options.settings || {};

  function describeTop() {
    const value = luaToJs(-1);
    return typeof value === 'string' ? value : JSON.stringify({ type: lua.lua_typename(L, lua.lua_type(L, -1)), value });
  }

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
        const key = luaToJs(-2);
        obj[key] = luaToJs(-1);
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
    // message handler for real Lua tracebacks
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

  const netEvents = {};
  const eventHandlers = {};
  const commands = {};
  const exportRefs = {};

  function setGlobal(name, fn) {
    lua.lua_pushcfunction(L, fn);
    lua.lua_setglobal(L, to_luastring(name));
  }

  const byId = (src) => playerList.find((p) => p.id === Number(src));

  setGlobal('print', (Ls) => {
    const parts = [];
    for (let i = 1; i <= lua.lua_gettop(Ls); i += 1) parts.push(String(luaToJs(i)));
    captured.logs.push(parts.join('\t'));
    return 0;
  });

  setGlobal('GetCurrentResourceName', () => {
    lua.lua_pushstring(L, to_luastring('fk_economy'));
    return 1;
  });

  setGlobal('LoadResourceFile', () => {
    const key = to_jsstring(lua.lua_tostring(L, 2));
    const content = filesystem[key];
    if (content == null) lua.lua_pushnil(L);
    else lua.lua_pushstring(L, to_luastring(content));
    return 1;
  });

  setGlobal('SaveResourceFile', () => {
    const key = to_jsstring(lua.lua_tostring(L, 2));
    const data = to_jsstring(lua.lua_tostring(L, 3));
    filesystem[key] = data;
    captured.saves[key] = data;
    lua.lua_pushboolean(L, true);
    return 1;
  });

  setGlobal('GetPlayerIdentifiers', () => {
    const player = byId(luaToJs(1));
    pushJs(player ? player.identifiers : []);
    return 1;
  });

  setGlobal('GetPlayerName', () => {
    const player = byId(luaToJs(1));
    pushJs(player ? player.name : undefined);
    return 1;
  });

  setGlobal('IsPlayerAceAllowed', () => {
    const player = byId(luaToJs(1));
    const ace = luaToJs(2);
    lua.lua_pushboolean(L, !!(player && player.aces && player.aces.includes(ace)));
    return 1;
  });

  setGlobal('GetPlayers', () => {
    pushJs(playerList.map((p) => String(p.id)));
    return 1;
  });

  setGlobal('CreateThread', () => {
    // Background threads (autosave) are not driven by this harness.
    return 0;
  });
  setGlobal('Wait', () => 0);
  setGlobal('SetTimeout', () => 0);

  setGlobal('RegisterNetEvent', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    const ref = reg();
    (netEvents[name] = netEvents[name] || []).push(ref);
    return 0;
  });

  setGlobal('AddEventHandler', () => {
    const name = to_jsstring(lua.lua_tostring(L, 1));
    const ref = reg();
    (eventHandlers[name] = eventHandlers[name] || []).push(ref);
    return 0;
  });

  setGlobal('TriggerEvent', (Ls) => {
    const name = to_jsstring(lua.lua_tostring(Ls, 1));
    const args = [];
    for (let i = 2; i <= lua.lua_gettop(Ls); i += 1) args.push(luaToJs(i));
    captured.server.push({ name, args });
    return 0;
  });

  setGlobal('TriggerClientEvent', (Ls) => {
    const name = to_jsstring(lua.lua_tostring(Ls, 1));
    const target = luaToJs(2);
    const args = [];
    for (let i = 3; i <= lua.lua_gettop(Ls); i += 1) args.push(luaToJs(i));
    captured.client.push({ name, target: Number(target), args });
    return 0;
  });

  setGlobal('RegisterCommand', (Ls) => {
    const name = to_jsstring(lua.lua_tostring(Ls, 1));
    lua.lua_pushvalue(L, 2); // the handler, not the trailing `restricted` flag
    commands[name] = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('exports', (Ls) => {
    const name = to_jsstring(lua.lua_tostring(Ls, 1));
    exportRefs[name] = reg();
    return 0;
  });

  // json bridge (real JSON round-trip, like FiveM's json lib)
  lua.lua_createtable(L, 0, 2);
  lua.lua_pushcfunction(L, () => {
    const value = luaToJs(1);
    lua.lua_pushstring(L, to_luastring(JSON.stringify(value)));
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

  // Deterministic, standard-compatible os.date for audit log lines
  setGlobal('os_date', () => {
    const fmt = lua.lua_gettop(L) >= 1 ? to_jsstring(lua.lua_tostring(L, 1)) : '%Y-%m-%d';
    const cleaned = fmt.replace(/^!/, '');
    const date = new Date(Date.now());
    const iso = date.toISOString();
    const map = {
      '!%Y-%m-%dT%H:%M:%SZ': iso.replace(/\.\d+Z$/, 'Z'),
      '%Y-%m-%d': iso.slice(0, 10),
    };
    lua.lua_pushstring(L, to_luastring(map[fmt] || cleaned));
    return 1;
  });

  function runLua(code, label) {
    const buffer = to_luastring(code);
    const loadStatus = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring('@' + (label || 'harness')));
    if (loadStatus !== lua.LUA_OK) {
      throw new Error('Harness snippet failed to compile: ' + describeTop());
    }
    const runStatus = lua.lua_pcall(L, 0, 0, 0);
    if (runStatus !== lua.LUA_OK) {
      throw new Error('Harness snippet failed: ' + describeTop());
    }
  }

  FILES.forEach((file, index) => {
    const code = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const buffer = to_luastring(code);
    const status = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring('@' + file));
    if (status !== lua.LUA_OK) {
      throw new Error(`Failed to compile ${file}: ` + describeTop());
    }
    const runStatus = lua.lua_pcall(L, 0, 0, 0);
    if (runStatus !== lua.LUA_OK) {
      throw new Error(`Failed to run ${file}: ` + describeTop());
    }

    // Config tweaks for this harness, applied after config.lua/utils.lua and
    // before the server modules read them.
    if (index === 1 && options.overrides) runLua(options.overrides, 'overrides');
  });

  function fireNet(name, src, ...args) {
    const refs = netEvents[name] || [];
    lua.lua_pushnumber(L, Number(src));
    lua.lua_setglobal(L, to_luastring('source'));
    refs.forEach((ref) => callRef(ref, args));
  }

  function fireServerEvent(name, ...args) {
    (eventHandlers[name] || []).forEach((ref) => callRef(ref, args));
  }

  function callExport(name, ...args) {
    if (!exportRefs[name]) throw new Error('Missing export ' + name);
    return callRef(exportRefs[name], args);
  }

  function runCommand(name, src, args) {
    if (!commands[name]) throw new Error('Missing command ' + name);
    lua.lua_pushnumber(L, Number(src));
    lua.lua_setglobal(L, to_luastring('source'));
    return callRef(commands[name], [src, args]);
  }

  return { captured, fireNet, fireServerEvent, callExport, runCommand, filesystem, playerList };
}

/* ------------------------------- assertions ------------------------------- */

let pass = 0;
const failures = [];
function check(name, condition, extra) {
  if (condition) {
    pass += 1;
    console.log('PASS  ' + name);
  } else {
    failures.push({ name, extra });
    console.log('FAIL  ' + name + (extra === undefined ? '' : '  -> ' + JSON.stringify(extra)));
  }
}

const players = [
  { id: 1, name: 'Alice', identifiers: ['license:aaa', 'steam:1'], aces: [] },
  { id: 2, name: 'Bob', identifiers: ['license:bbb'], aces: [] },
  { id: 3, name: 'Admin', identifiers: ['license:admin'], aces: ['fk_economy.staff'] },
  // vMenu admins: vMenu stores staff status as ACE permissions
  { id: 4, name: 'Vicky', identifiers: ['license:vicky'], aces: ['vMenu.Everything'] },
  { id: 5, name: 'Mod', identifiers: ['license:mod'], aces: ['vMenu.OnlinePlayers.Kick', 'vMenu.OnlinePlayers.TempBan'] },
  { id: 6, name: 'Driver', identifiers: ['license:driver'], aces: ['vMenu.VehicleSpawner.Menu', 'vMenu.OnlinePlayers.Menu'] },
  { id: 7, name: 'Banhammer', identifiers: ['license:ban'], aces: ['vMenu.OnlinePlayers.PermBan'] },
];

const h = createHarness({ players });

// -- basics ----------------------------------------------------------------
h.fireNet('fk_economy:server:requestState', 1);
let stateEvent = h.captured.client.filter((e) => e.name === 'fk_economy:client:state').pop();
check('requestState pushes state', !!stateEvent && stateEvent.target === 1, stateEvent);
check('starting balances applied', stateEvent && stateEvent.args[0].balances.cash === 750 && stateEvent.args[0].balances.bank === 2500, stateEvent && stateEvent.args[0]);
check('state includes account list', stateEvent && Array.isArray(stateEvent.args[0].accounts) && stateEvent.args[0].accounts.length === 2);
check('state reports staff=false for normal player', stateEvent && stateEvent.args[0].staff === false);

let [money] = h.callExport('GetMoney', 1);
check('GetMoney export', money && money.cash === 750 && money.bank === 2500, money);

let [balance] = h.callExport('GetBalance', 1, 'bank');
check('GetBalance export', balance === 2500, balance);

// -- add / remove ----------------------------------------------------------
let [ok, result] = h.callExport('AddMoney', 1, 'cash', 250, 'Payroll');
check('AddMoney succeeds', ok === true && result === 1000, [ok, result]);
stateEvent = h.captured.client.filter((e) => e.name === 'fk_economy:client:state').pop();
check('AddMoney pushes new balance to player', stateEvent && stateEvent.args[0].balances.cash === 1000, stateEvent && stateEvent.args[0].balances);

[ok, result] = h.callExport('RemoveMoney', 1, 'cash', 100, 'Fine');
check('RemoveMoney succeeds', ok === true && result === 900, [ok, result]);

[ok, result] = h.callExport('RemoveMoney', 1, 'bank', 999999, 'Fine');
check('RemoveMoney refuses overdraft', ok === false && result === 'insufficient_funds', [ok, result]);

[ok, result] = h.callExport('RemoveMoney', 1, 'cash', 900, 'Fine');
check('RemoveMoney can empty an account', ok === true && result === 0, [ok, result]);

[ok, result] = h.callExport('AddMoney', 1, 'cash', -50, 'Nope');
check('AddMoney rejects negative', ok === false && result === 'invalid_amount', [ok, result]);

[ok, result] = h.callExport('AddMoney', 1, 'cash', 'abc', 'Nope');
check('AddMoney rejects non-numeric', ok === false && result === 'invalid_amount', [ok, result]);

[ok, result] = h.callExport('AddMoney', 1, 'vault', 100, 'Nope');
check('AddMoney rejects unknown account', ok === false && result === 'invalid_account', [ok, result]);

[ok, result] = h.callExport('AddMoney', 999, 'cash', 100, 'Nope');
check('AddMoney rejects offline target', ok === false && result === 'no_target', [ok, result]);

[ok, result] = h.callExport('SetMoney', 2, 'bank', 5000, 'Correction');
check('SetMoney works', ok === true && result === 5000, [ok, result]);

[ok, result] = h.callExport('SetMoney', 2, 'bank', -10, 'Correction');
check('SetMoney rejects negative', ok === false && result === 'invalid_amount', [ok, result]);

// -- prices / purchases ----------------------------------------------------
let [price] = h.callExport('GetPrice', 'bodycam');
check('GetPrice reads config.lua', price === 250, price);
[price] = h.callExport('GetPrice', 'does_not_exist');
check('GetPrice unknown = 0', price === 0, price);

let [prices] = h.callExport('GetPrices');
check('GetPrices returns the item table', prices && prices.radio && prices.radio.price === 450, prices && Object.keys(prices).length);

h.callExport('AddMoney', 1, 'cash', 1000, 'Test top-up');
let [afford] = h.callExport('CanAfford', 1, 'bodycam', 2, 'cash');
check('CanAfford true when rich enough', afford === true, afford);
[afford] = h.callExport('CanAfford', 1, 'vehicle_helicopter', 1, 'cash');
check('CanAfford false when poor', afford === false, afford);

[ok, result] = h.callExport('TryPurchase', 1, 'bodycam', 2, 'cash');
check('TryPurchase charges config price', ok === true && result === 500, [ok, result]);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('balance after purchase', balance === 500, balance);

[ok, result] = h.callExport('TryPurchase', 1, 'unknown_item', 1, 'cash');
check('TryPurchase rejects unknown item', ok === false && result === 'unknown_item', [ok, result]);

[ok, result] = h.callExport('TryPurchase', 1, 'vehicle_helicopter', 1, 'cash');
check('TryPurchase refuses when broke', ok === false && result === 'insufficient_funds', [ok, result]);

// -- staff -----------------------------------------------------------------
h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 2, { mode: 'add', account: 'cash', amount: 5000, target: 1 });
let staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('non-staff cannot use staff action', staffResult && staffResult.args[0].ok === false, staffResult && staffResult.args[0]);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('non-staff action changed nothing', balance === 500, balance);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'add', account: 'cash', amount: 5000, target: 1, reason: 'Bonus' });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('staff can add money', staffResult && staffResult.args[0].ok === true, staffResult && staffResult.args[0]);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('staff add applied', balance === 5500, balance);
check('staff add notified the target', h.captured.client.some((e) => e.name === 'fk_economy:client:notify' && e.target === 1));

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'remove', account: 'cash', amount: 500, target: 1, reason: 'Fine' });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('staff can remove money', staffResult && staffResult.args[0].ok === true, staffResult && staffResult.args[0]);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('staff remove applied', balance === 5000, balance);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'remove', account: 'cash', amount: 999999, target: 1 });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('staff remove blocks overdraft', staffResult && staffResult.args[0].ok === false, staffResult && staffResult.args[0]);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'add', account: 'cash', amount: 1000001, target: 1 });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('per-action cap enforced', staffResult && staffResult.args[0].ok === false, staffResult && staffResult.args[0]);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'add', account: 'cash', amount: 100, target: 404 });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('offline target rejected', staffResult && staffResult.args[0].ok === false, staffResult && staffResult.args[0]);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 3, { mode: 'add', account: 'cash', amount: -50, target: 1 });
staffResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('negative staff amount rejected', staffResult && staffResult.args[0].ok === false, staffResult && staffResult.args[0]);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:requestPlayers', 2);
check('non-staff cannot list players', !h.captured.client.some((e) => e.name === 'fk_economy:client:playerList'));

h.captured.client.length = 0;
h.fireNet('fk_economy:server:requestPlayers', 3);
const listEvent = h.captured.client.filter((e) => e.name === 'fk_economy:client:playerList').pop();
check('staff can list players', listEvent && Array.isArray(listEvent.args[0]) && listEvent.args[0].length === 7, listEvent && listEvent.args[0]);
check('player list includes balances', listEvent && listEvent.args[0][0].balances && typeof listEvent.args[0][0].balances.cash === 'number');

let [isStaffFlag] = h.callExport('IsStaff', 3);
check('IsStaff export true for admin', isStaffFlag === true, isStaffFlag);
[isStaffFlag] = h.callExport('IsStaff', 1);
check('IsStaff export false for normal player', isStaffFlag === false, isStaffFlag);

// -- staff roster (no ACE, no vMenu) ---------------------------------------
let [access] = h.callExport('GetStaffAccess', 1);
check('normal player starts without staff access', access && access.staff === false, access);

h.captured.client.length = 0;
h.runCommand('ecostaff', 1, ['claim']);
[access] = h.callExport('GetStaffAccess', 1);
check('claim makes the first player staff', access && access.staff === true && access.source === 'roster', access);

const claimState = h.captured.client.filter((e) => e.name === 'fk_economy:client:state' && e.target === 1).pop();
check('claim immediately unlocks the staff UI', claimState && claimState.args[0].staff === true, claimState && claimState.args[0]);

const rosterRaw = h.filesystem['data/staff.json'];
check('staff.json written on claim', !!rosterRaw, Object.keys(h.filesystem));

let rosterJson = null;
try { rosterJson = JSON.parse(rosterRaw); } catch (e) { /* ignore */ }
check('roster stores a license identifier', !!rosterJson && !!rosterJson.staff['license:aaa'], rosterJson && Object.keys(rosterJson.staff));
check('roster entry records owner role', !!rosterJson && rosterJson.staff['license:aaa'].role === 'owner', rosterJson && rosterJson.staff['license:aaa']);

h.runCommand('ecostaff', 2, ['claim']);
[access] = h.callExport('GetStaffAccess', 2);
check('second claim is refused once the list has staff', access && access.staff === false, access);

h.runCommand('ecostaff', 1, ['add', '2']);
[access] = h.callExport('GetStaffAccess', 2);
check('roster staff can add another player', access && access.staff === true && access.source === 'roster', access);

h.captured.client.length = 0;
h.fireNet('fk_economy:server:staffAction', 2, { mode: 'add', account: 'cash', amount: 100, target: 3 });
let rosterResult = h.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('newly added staff can give money', rosterResult && rosterResult.args[0].ok === true, rosterResult && rosterResult.args[0]);

h.runCommand('ecostaff', 1, ['remove', '2']);
[access] = h.callExport('GetStaffAccess', 2);
check('removed player loses staff access', access && access.staff === false, access);

h.runCommand('ecostaff', 1, ['remove', '1']);
[access] = h.callExport('GetStaffAccess', 1);
check('the last staff member cannot be removed', access && access.staff === true, access);

h.runCommand('eco_staff', 0, ['add', '3']);
let [access3] = h.callExport('GetStaffAccess', 3);
check('console can add staff by server id', access3 && access3.staff === true && access3.source === 'roster', access3);

h.captured.client.length = 0;
h.runCommand('ecostaff', 2, ['add', '1']);
check('non-staff cannot manage the list', h.captured.client.some((e) => e.name === 'chat:addMessage' && e.target === 2 && /staff access/i.test(e.args[0].args[1])));

const logStart = h.captured.logs.length;
h.runCommand('eco_staff', 0, ['list']);
const listLogs = h.captured.logs.slice(logStart).join('\n');
check('console list shows both staff members', /Staff list \(2\)/.test(listLogs), listLogs);

// -- vMenu admin detection (opt-in) ----------------------------------------
// vMenu detection is OFF by default, so those ACEs must be ignored...
let [vmenuAccess] = h.callExport('GetStaffAccess', 4);
check('vMenu ACEs are ignored while detection is off', vmenuAccess && vmenuAccess.staff === false, vmenuAccess);
let [watchedNodes] = h.callExport('GetVMenuPermissions');
check('no vMenu nodes watched while off', watchedNodes && Object.keys(watchedNodes).length === 0, watchedNodes);

// ...and picked up once enabled in config.
const hv = createHarness({ players, overrides: 'Config.Staff.vmenu.enabled = true' });

[vmenuAccess] = hv.callExport('GetStaffAccess', 4);
check('vMenu.Everything is detected as admin', vmenuAccess && vmenuAccess.staff === true && vmenuAccess.source === 'vmenu', vmenuAccess);
check('matched vMenu node reported', vmenuAccess && vmenuAccess.matched === 'vMenu.Everything', vmenuAccess && vmenuAccess.matched);

[vmenuAccess] = hv.callExport('GetStaffAccess', 7);
check('vMenu.OnlinePlayers.PermBan counts as admin', vmenuAccess && vmenuAccess.staff === true && vmenuAccess.source === 'vmenu', vmenuAccess);

[vmenuAccess] = hv.callExport('GetStaffAccess', 3);
check('own ACE still takes priority', vmenuAccess && vmenuAccess.staff === true && vmenuAccess.source === 'ace', vmenuAccess);

let [modIsStaff] = hv.callExport('IsStaff', 5);
check('vMenu moderators are not staff by default', modIsStaff === false, modIsStaff);
[modIsStaff] = hv.callExport('IsStaff', 6);
check('plain vMenu permissions are not staff', modIsStaff === false, modIsStaff);

[watchedNodes] = hv.callExport('GetVMenuPermissions');
check('vMenu node list exposed', Array.isArray(watchedNodes) && watchedNodes.includes('vMenu.Everything'), watchedNodes);

hv.captured.client.length = 0;
hv.fireNet('fk_economy:server:staffAction', 4, { mode: 'add', account: 'bank', amount: 250, target: 2, reason: 'Bonus' });
let vmenuResult = hv.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('vMenu admin can give money via menu', vmenuResult && vmenuResult.args[0].ok === true, vmenuResult && vmenuResult.args[0]);

let [vmenuBalance] = hv.callExport('GetBalance', 2, 'bank');
check('vMenu admin action applied', vmenuBalance === 2750, vmenuBalance);

hv.captured.client.length = 0;
hv.fireNet('fk_economy:server:staffAction', 5, { mode: 'add', account: 'bank', amount: 250, target: 2 });
vmenuResult = hv.captured.client.filter((e) => e.name === 'fk_economy:client:staffResult').pop();
check('vMenu moderator cannot give money', vmenuResult && vmenuResult.args[0].ok === false, vmenuResult && vmenuResult.args[0]);

hv.runCommand('addmoney', 4, ['2', 'cash', '50', 'vMenu test']);
[vmenuBalance] = hv.callExport('GetBalance', 2, 'cash');
check('vMenu admin can use chat commands', vmenuBalance === 800, vmenuBalance);

hv.captured.client.length = 0;
hv.runCommand('ecoaccess', 4, []);
const vmenuAccessMsg = hv.captured.client.filter((e) => e.name === 'chat:addMessage' && e.target === 4).pop();
check('/ecoaccess reports vMenu admin', vmenuAccessMsg && /vMenu admin/i.test(vmenuAccessMsg.args[0].args[1]), vmenuAccessMsg && vmenuAccessMsg.args[0].args[1]);

// -- commands --------------------------------------------------------------
h.captured.client.length = 0;
h.runCommand('addmoney', 2, ['1', 'cash', '100']);
const denial = h.captured.client.filter((e) => e.name === 'chat:addMessage' && e.target === 2).pop();
check('command blocks non-staff with a chat message', !!denial && /permission/i.test(denial.args[0].args[1]), denial);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('blocked command changed nothing', balance === 5000, balance);

h.captured.client.length = 0;
h.runCommand('addmoney', 3, ['1', 'cash', '250', 'Payroll']);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('staff command adds money', balance === 5250, balance);

h.runCommand('takemoney', 3, ['2', 'bank', '1000']);
[balance] = h.callExport('GetBalance', 2, 'bank');
check('staff command removes money', balance === 4000, balance);

// /ecoaccess explains the decision
h.captured.client.length = 0;
h.runCommand('ecoaccess', 1, []);
let accessMsg = h.captured.client.filter((e) => e.name === 'chat:addMessage' && e.target === 1).pop();
check('/ecoaccess reports the staff list', accessMsg && /staff list/i.test(accessMsg.args[0].args[1]), accessMsg && accessMsg.args[0].args[1]);

h.captured.client.length = 0;
h.runCommand('ecoaccess', 6, []);
accessMsg = h.captured.client.filter((e) => e.name === 'chat:addMessage' && e.target === 6).pop();
check('/ecoaccess reports no access', accessMsg && /NO/.test(accessMsg.args[0].args[1]), accessMsg && accessMsg.args[0].args[1]);

// -- persistence -----------------------------------------------------------
h.fireServerEvent('playerDropped', '1');
const savedRaw = h.filesystem['data/accounts.json'];
check('accounts.json written on drop', !!savedRaw, Object.keys(h.filesystem));
let savedJson = null;
try { savedJson = JSON.parse(savedRaw); } catch (e) { /* ignore */ }
check('accounts.json is valid JSON', !!savedJson && typeof savedJson.accounts === 'object', savedRaw && savedRaw.slice(0, 120));
check('saved balance matches memory', savedJson && savedJson.accounts['license:aaa'].cash === 5250, savedJson && savedJson.accounts['license:aaa']);
check('audit log written', !!h.filesystem['data/transactions.log'] && h.filesystem['data/transactions.log'].includes('actor='), h.filesystem['data/transactions.log'] && h.filesystem['data/transactions.log'].split('\n')[0]);

// Reload from disk in a fresh VM
const h2 = createHarness({
  players,
  files: { 'data/accounts.json': savedRaw, 'data/staff.json': h.filesystem['data/staff.json'] },
});
h2.fireNet('fk_economy:server:requestState', 1);
const reloaded = h2.captured.client.filter((e) => e.name === 'fk_economy:client:state').pop();
check('balance survives restart', reloaded && reloaded.args[0].balances.cash === 5250, reloaded && reloaded.args[0].balances);

let [reloadAccess] = h2.callExport('GetStaffAccess', 1);
check('staff roster survives a restart', reloadAccess && reloadAccess.staff === true && reloadAccess.source === 'roster', reloadAccess);

// Offline identifier access (staff tooling / other resources)
let [offline] = h2.callExport('GetMoney', 2);
check('online lookup still works after reload', offline && offline.bank === 4000, offline);

// -- misc ------------------------------------------------------------------
const [, errBalance] = h.callExport('AddMoney', 1, 'cash', 100000000, 'Cap test');
check('balance ceiling respected', errBalance === 999999999 || errBalance <= 999999999, errBalance);
[balance] = h.callExport('GetBalance', 1, 'cash');
check('balance never exceeds max', balance <= 999999999, balance);

const stats = h.callExport('GetAccountStats', 1)[0];
check('account stats track earned/spent', stats && stats.earned > 0 && stats.spent > 0, stats);

console.log(`\n${pass}/${pass + failures.length} checks passed`);
if (failures.length) {
  console.log('\nFailures:');
  failures.forEach((f) => console.log(' - ' + f.name + ' -> ' + JSON.stringify(f.extra)));
  process.exit(1);
}
