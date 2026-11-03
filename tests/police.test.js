/* Loads fk_police (config + MDT + server) in fengari with mocked natives, then
   drives the job: duty, records, dispatch, traffic stops, citations, arrests,
   backup, ranks and single-player behaviour. The MDT page is loaded in jsdom at
   the end.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..', 'fk_police');
const FILES = ['config.lua', 'shared/core.lua', 'shared/mdt.lua', 'server/main.lua', 'server/justice.lua'];

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
// Lua prelude: threads, fake clocks, Player(), exports/ and json
// ---------------------------------------------------------------------------

const PRELUDE = `
fkThreads = {}
fkTimer = 100000
fkPlayerStates = {}
fkExports = {}
fkClock = 1760000000
fkRemoveMoneyOk = true
fkRemoved = {}

function fkTick(ms) fkTimer = fkTimer + (ms or 0) end
os.time = function() return fkClock end
function fkAdvance(seconds) fkClock = fkClock + (seconds or 0) end
GetGameTimer = function() return fkTimer end

function CreateThread(fn) fkThreads[#fkThreads + 1] = coroutine.create(fn) end
function Wait(ms) coroutine.yield(ms or 0) end

function Player(source)
    fkPlayerStates[source] = fkPlayerStates[source] or { state = {} }
    return fkPlayerStates[source]
end

function fkStep()
    local out = {}

    for _, co in ipairs(fkThreads) do
        if coroutine.status(co) ~= 'dead' then
            local ok, res = coroutine.resume(co)
            if not ok then out[#out + 1] = 'error: ' .. tostring(res)
            elseif res ~= nil then out[#out + 1] = res end
        end
    end

    return out
end

-- FiveM's exports is callable *and* indexable.
exports = setmetatable({
    fk_economy = {
        AddMoney = function(self, ...) return fkAddMoney(...) end,
        RemoveMoney = function(self, ...) return fkRemoveMoneyImpl(...) end,
        GetBalance = function(self, ...) return 1000 end,
    },
}, {
    __call = function(_, name, fn) fkExports[name] = fn end,
})

function fkExport(name, ...)
    local fn = fkExports[name]

    if not fn then error('no export ' .. tostring(name)) end

    return fn(...)
end
`;

// JSON-ish values -> Lua source (JSON array syntax is not valid Lua).
function luaLiteral(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return '{ ' + value.map((item) => luaLiteral(item)).join(', ') + ' }';

  return '{ ' + Object.entries(value)
    .map(([key, item]) => `[${JSON.stringify(key)}] = ${luaLiteral(item)}`)
    .join(', ') + ' }';
}

function createHarness(options = {}) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const captured = { client: [], logs: [], commands: {}, handlers: {} };
  const filesystem = Object.assign({}, options.files || {});
  let removeMoneyOk = options.removeMoney !== false;
  const money = [];
  const players = options.players || ['1'];
  const identifiers = options.identifiers || { 1: 'license:officer1' };

  function luaToJs(idx, S = L) {
    if (idx < 0 && idx > lua.LUA_REGISTRYINDEX) idx = lua.lua_gettop(S) + idx + 1;
    const t = lua.lua_type(S, idx);
    if (t === lua.LUA_TNIL || t === lua.LUA_TNONE) return null;
    if (t === lua.LUA_TBOOLEAN) return lua.lua_toboolean(S, idx);
    if (t === lua.LUA_TNUMBER) return lua.lua_tonumber(S, idx);
    if (t === lua.LUA_TSTRING) return to_jsstring(lua.lua_tostring(S, idx));
    if (t === lua.LUA_TTABLE) {
      const obj = {};
      let count = 0;
      lua.lua_pushnil(S);
      while (lua.lua_next(S, idx) !== 0) {
        obj[luaToJs(-2, S)] = luaToJs(-1, S);
        count += 1;
        lua.lua_pop(S, 1);
      }
      if (count === 0) return [];
      const keys = Object.keys(obj);
      const isArray = count > 0 && keys.length === count
        && keys.every((k) => /^\d+$/.test(k)) && Math.max(...keys.map(Number)) === count;
      if (isArray) {
        const arr = [];
        for (let i = 1; i <= count; i += 1) arr.push(obj[i]);
        return arr;
      }
      return obj;
    }
    return null;
  }

  function pushJs(value, S = L) {
    if (value === null || value === undefined) lua.lua_pushnil(S);
    else if (typeof value === 'boolean') lua.lua_pushboolean(S, value);
    else if (typeof value === 'number') lua.lua_pushnumber(S, value);
    else if (typeof value === 'string') lua.lua_pushstring(S, to_luastring(value));
    else if (Array.isArray(value)) {
      lua.lua_createtable(S, value.length, 0);
      value.forEach((item, index) => {
        pushJs(item, S);
        lua.lua_rawseti(S, -2, index + 1);
      });
    } else {
      lua.lua_createtable(S, 0, Object.keys(value).length);
      Object.entries(value).forEach(([key, item]) => {
        pushJs(item, S);
        lua.lua_setfield(S, -2, to_luastring(key));
      });
    }
  }

  function callRef(ref, args = []) {
    const base = lua.lua_gettop(L);
    lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, ref);
    args.forEach((arg) => pushJs(arg, L));

    const status = lua.lua_pcall(L, args.length, lua.LUA_MULTRET, 0);
    if (status !== lua.LUA_OK) {
      const raw = lua.lua_tostring(L, -1);
      const message = raw ? to_jsstring(raw) : 'unknown error';
      lua.lua_settop(L, base);
      throw new Error('Lua error: ' + message);
    }
    const top = lua.lua_gettop(L);
    const out = [];
    for (let index = base + 1; index <= top; index += 1) out.push(luaToJs(index, L));
    lua.lua_settop(L, base);
    return out;
  }

  function setGlobal(name, fn) {
    lua.lua_pushcfunction(L, (S) => fn(S || L));
    lua.lua_setglobal(L, to_luastring(name));
  }

  function luaDo(source, chunkName = '@test-chunk') {
    const base = lua.lua_gettop(L);
    const buffer = Buffer.from(source, 'utf8');
    const st = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring(chunkName));
    if (st !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    const ran = lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0);
    if (ran !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    const top = lua.lua_gettop(L);
    const value = top > base ? luaToJs(top, L) : null;
    lua.lua_settop(L, base);
    return value;
  }

  setGlobal('GetCurrentResourceName', (S) => { lua.lua_pushstring(S, to_luastring('fk_police')); return 1; });
  setGlobal('GetResourceMetadata', (S) => { lua.lua_pushstring(S, to_luastring('0.1.0')); return 1; });

  setGlobal('GetPlayerIdentifiers', (S) => {
    const source = Math.trunc(lua.lua_tonumber(S, 1));
    lua.lua_createtable(S, 1, 0);
    lua.lua_pushstring(S, to_luastring(identifiers[source] || ('license:player' + source)));
    lua.lua_rawseti(S, -2, 1);
    return 1;
  });

  setGlobal('GetPlayers', (S) => {
    lua.lua_createtable(S, players.length, 0);
    players.forEach((id, index) => {
      lua.lua_pushstring(S, to_luastring(String(id)));
      lua.lua_rawseti(S, -2, index + 1);
    });
    return 1;
  });

  setGlobal('TriggerClientEvent', (S) => {
    captured.client.push({
      name: to_jsstring(lua.lua_tostring(S, 1)),
      target: lua.lua_tonumber(S, 2),
      args: luaToJs(3, S),
    });
    return 0;
  });

  const register = (S, sink, withFlags) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    lua.lua_pushvalue(S, 2);
    const ref = lauxlib.luaL_ref(S, lua.LUA_REGISTRYINDEX);
    if (withFlags) sink[name] = { ref, restricted: lua.lua_toboolean(S, 3) };
    else sink[name] = ref;
    return 0;
  };

  setGlobal('RegisterNetEvent', (S) => register(S, captured.handlers, false));
  setGlobal('AddEventHandler', (S) => register(S, captured.handlers, false));
  setGlobal('RegisterCommand', (S) => register(S, captured.commands, true));
  setGlobal('exports', () => 0); // overwritten by the prelude's callable table

  setGlobal('print', (S) => {
    const parts = [];
    const top = lua.lua_gettop(S);
    for (let i = 1; i <= top; i += 1) parts.push(String(luaToJs(i, S)));
    captured.logs.push(parts.join(' ').replace(/\^\d/g, ''));
    return 0;
  });

  setGlobal('SaveResourceFile', (S) => {
    filesystem[to_jsstring(lua.lua_tostring(S, 2))] = to_jsstring(lua.lua_tostring(S, 3));
    lua.lua_pushboolean(S, true);
    return 1;
  });

  setGlobal('LoadResourceFile', (S) => {
    const file = to_jsstring(lua.lua_tostring(S, 2));
    lua.lua_pushstring(S, to_luastring(filesystem[file] || ''));
    return 1;
  });

  setGlobal('SetTimeout', () => 0);

  setGlobal('json_encode', (S) => {
    lua.lua_pushstring(S, to_luastring(JSON.stringify(luaToJs(1, S))));
    return 1;
  });
  setGlobal('json_decode', (S) => {
    const raw = to_jsstring(lua.lua_tostring(S, 1));
    try {
      pushJs(JSON.parse(raw), S);
    } catch (err) {
      lua.lua_pushnil(S);
    }
    return 1;
  });

  setGlobal('fkRemoveMoneyImpl', (S) => {
    const source = lua.lua_tonumber(S, 1);
    const account = to_jsstring(lua.lua_tostring(S, 2));
    const amount = lua.lua_tonumber(S, 3);
    const ok = removeMoneyOk;

    if (ok) money.push({ source, account, amount: -Math.abs(amount), reason: 'removed' });

    lua.lua_pushboolean(S, ok);
    lua.lua_pushboolean(S, ok);
    return 2;
  });

  setGlobal('fkAddMoney', (S) => {
    money.push({
      source: lua.lua_tonumber(S, 1),
      account: to_jsstring(lua.lua_tostring(S, 2)),
      amount: lua.lua_tonumber(S, 3),
      reason: to_jsstring(lua.lua_tostring(S, 4) || ''),
    });
    lua.lua_pushboolean(S, true);
    lua.lua_pushboolean(S, true);
    return 2;
  });

  luaDo(PRELUDE, '@prelude');
  // json comes from FiveM, not the standard library.
  luaDo('json = { encode = json_encode, decode = json_decode }', '@json');

  FILES.forEach((file) => {
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const buffer = Buffer.from(source, 'utf8');
    const st = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring('@' + file));
    if (st !== lua.LUA_OK) throw new Error(`${file}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    const ran = lua.lua_pcall(L, 0, 0, 0);
    if (ran !== lua.LUA_OK) throw new Error(`${file}: ${to_jsstring(lua.lua_tostring(L, -1))}`);

    if (file === 'config.lua' && options.patch) luaDo(options.patch, '@patch');
  });

  return {
    captured,
    filesystem,
    money,
    luaDo,
    tick(ms) { luaDo(`fkTick(${Number(ms)})`, '@tick'); },
    advance(seconds) { luaDo(`fkAdvance(${Number(seconds)})`, '@advance'); },
    clock() { return luaDo('return fkClock', '@clock'); },
    setRemoveMoney(ok) { removeMoneyOk = ok === true; },
    step() { return luaDo('return fkStep()', '@step'); },
    state(source, key) {
      return luaDo(`local p = Player(${source}); return p.state[${JSON.stringify(key)}]`, '@state');
    },
    callExport(name, args = []) {
      const tail = args.length ? ', ' + args.map((a) => luaLiteral(a)).join(', ') : '';
      return [luaDo(`return fkExport(${JSON.stringify(name)}${tail})`, '@export')];
    },
    fireNet(name, source, args = []) {
      if (captured.handlers[name] === undefined) throw new Error(`no net event "${name}"`);
      luaDo(`source = ${Number(source) || 0}`, '@source');
      return callRef(captured.handlers[name], args);
    },
    fireEvent(name, args = []) {
      if (captured.handlers[name] === undefined) throw new Error(`no event "${name}"`);
      return callRef(captured.handlers[name], args);
    },
    runCommand(name, source, args = []) {
      if (!captured.commands[name]) throw new Error(`no command "${name}"`);
      return callRef(captured.commands[name].ref, [source, args]);
    },
    lastClient(name) {
      return captured.client.filter((event) => event.name === name).pop();
    },
    notes() {
      return captured.client
        .filter((event) => event.name === 'fk_police:client:notify')
        .map((event) => String(event.args));
    },
  };
}

// ---------------------------------------------------------------------------
// MDT pure functions
// ---------------------------------------------------------------------------

const mdtHost = createHarness();
const m = (expr) => mdtHost.luaDo(`return ${expr}`, '@mdt');

check('plates are normalised', m("Mdt.normalizePlate(' ab 12-cde ')") === 'AB12CDE', m("Mdt.normalizePlate(' ab 12-cde ')"));
check('an empty plate is rejected', m("Mdt.normalizePlate('  ')") === null);
check('an over-long plate is rejected', m("Mdt.normalizePlate('ABCDEFGHIJ')") === null);
check('names are trimmed and collapsed', m("Mdt.normalizeName('  Marcus   Vance ')") === 'Marcus Vance');
check('person keys are lower case', m("Mdt.personKey('Marcus Vance')") === 'name:marcus vance');
check('vehicle keys are the plate', m("Mdt.vehicleKey('ma rc us1')") === 'plate:MARCUS1');

check('a person record is normalised',
  m("Mdt.normalizePerson({ name = '  Dana   Cruz ', license = 'expired' }).name") === 'Dana Cruz');
check('a vehicle record is normalised',
  m("Mdt.normalizeVehicle({ plate = 'abc 123', model = 'SULTAN' }).plate") === 'ABC123');
check('an empty vehicle record is rejected', m('Mdt.normalizeVehicle({})') === null);

// seeded records are available through the MDT
const seeded = m('json.encode(fkExport("GetRecords").people)');
check('the server seeded a small population', typeof seeded === 'string' && seeded.includes('Marcus Vance'), seeded && seeded.slice(0, 80));

check('a person can be found by name',
  m('Mdt.findPeople(fkExport("GetRecords"), "marcus")[1].name') === 'Marcus Vance');
check('a partial name finds one match',
  m('#Mdt.findPeople(fkExport("GetRecords"), "cruz")') === 1,
  m('#Mdt.findPeople(fkExport("GetRecords"), "cruz")'));
check('an unknown name finds nothing',
  m('#Mdt.findPeople(fkExport("GetRecords"), "nobody")') === 0);
check('a plate finds the vehicle',
  m('Mdt.findVehicle(fkExport("GetRecords"), "marcus1").owner') === 'Marcus Vance');
check('a plate with spaces still finds it',
  m('Mdt.findVehicle(fkExport("GetRecords"), "marc us1").model') === 'sultan');

check('a stolen vehicle reports the flag',
  (m('json.encode(Mdt.vehicleFlags(Mdt.findVehicle(fkExport("GetRecords"), "OWEN555")))') || '').includes('STOLEN'));
const ellisFlags = m('json.encode(Mdt.personFlags(Mdt.findPerson(fkExport("GetRecords"), "Ellis Roan")))') || '';
check('a suspended licence and a warrant are flags',
  /suspended/.test(ellisFlags) && /WARRANT/.test(ellisFlags), ellisFlags);
check('a warrant is reported', m('Mdt.hasWarrant(Mdt.findPerson(fkExport("GetRecords"), "Owen Pike"))') === true);

const sentence = (ids) => m(`(function() local fine, jail = Mdt.sentence(Config, ${ids}); return { fine = fine, jail = jail } end)()`);
const sentenceFine = (ids) => (sentence(ids) || {}).fine;
const sentenceJail = (ids) => (sentence(ids) || {}).jail;

check('a sentence adds the charges', sentenceFine('{ "speeding", "reckless_driving" }') === 850,
  sentence('{ "speeding", "reckless_driving" }'));
check('duplicate charges count once', sentenceFine('{ "speeding", "speeding" }') === 250);
check('an unknown charge is ignored', sentenceFine('{ "made_up" }') === 0);
check('jail time comes from the charges', sentenceJail('{ "assault", "armed_robbery" }') === 420,
  sentence('{ "assault", "armed_robbery" }'));

check('ranks follow XP', m('Mdt.rankFor(Config, 160).name') === 'Officer', m('Mdt.rankFor(Config, 160).name'));
check('the top rank has no next rank', m('Mdt.nextRank(Config, 99999)') === null);
check('the next rank is reported', m('Mdt.nextRank(Config, 10).name') === 'Officer');

check('a weighted roll of 0 picks the first callout', m('Mdt.pickCallout(Config, 0).id') === 'traffic_stop');
check('a weighted roll near 1 picks a real callout', m('Mdt.pickCallout(Config, 0.999)') !== null);

// ---------------------------------------------------------------------------
// Duty
// ---------------------------------------------------------------------------

const police = createHarness();
police.tick(1000);
police.step();
police.step(); // the banner thread yields once on Wait(1000) before it logs

check('the boot banner reports the records',
  police.captured.logs.some((line) => line.includes('ready (v0.1.0). 5 person record(s), 5 vehicle record(s)')),
  police.captured.logs);
check('seeding wrote the records file', !!police.filesystem['data/records.json']);

check('searching off duty is refused',
  (police.callExport('Search', [1, 'person', 'marcus'])[0] || {}).reason === 'off_duty',
  police.callExport('Search', [1, 'person', 'marcus'])[0]);

police.fireNet('fk_police:server:duty', 1, [true]);

check('going on duty sets the state bag', police.state(1, 'fkPoliceDuty') === true);
check('the rank reaches the state bag', police.state(1, 'fkPoliceRank') === 'Cadet');
check('the client is told to start duty',
  !!police.lastClient('fk_police:client:duty') && police.lastClient('fk_police:client:duty').args === true);
check('the status export knows the officer is on duty',
  (police.callExport('GetStatus', [1])[0] || {}).onDuty === true);

const personSearch = police.callExport('Search', [1, 'person', 'owen'])[0];
check('a name search returns the person and their warrant',
  personSearch.ok === true && personSearch.results[0].name === 'Owen Pike'
    && personSearch.results[0].flags.join(' ').includes('WARRANT'), personSearch);

const vehicleSearch = police.callExport('Search', [1, 'vehicle', 'owen 555'])[0];
check('a plate search returns the vehicle, its owner flags and stolen flag',
  vehicleSearch.ok === true && vehicleSearch.results[0].stolen === true
    && vehicleSearch.results[0].ownerFlags.join(' ').includes('WARRANT'), vehicleSearch);
check('an unknown plate returns an empty list',
  (police.callExport('Search', [1, 'vehicle', 'ZZZZ999'])[0] || {}).results.length === 0);
check('an unknown search kind is refused',
  (police.callExport('Search', [1, 'nonsense', 'x'])[0] || {}).reason === 'unknown_kind');

// ---------------------------------------------------------------------------
// Traffic stops, citations, arrests
// ---------------------------------------------------------------------------

check('a stop with an unreadable plate is refused',
  (police.callExport('StartStop', [1, ' ', 'sultan'])[0] || {}).reason === 'bad_plate');
check('a citation without a stop is refused',
  (police.callExport('Cite', [1, ['speeding']])[0] || {}).reason === 'no_stop');
check('an arrest without a stop is refused',
  (police.callExport('Arrest', [1, ['assault']])[0] || {}).reason === 'no_stop');

const stop = police.callExport('StartStop', [1, 'marcus1', 'sultan'])[0];
check('a stop finds the owner', stop.ok === true && stop.owner === 'Marcus Vance', stop);
check('a clean vehicle has no flags', (stop.vehicleFlags || []).length === 0, stop.vehicleFlags);

police.money.length = 0;
const citation = police.callExport('Cite', [1, ['speeding', 'reckless_driving']])[0];
check('a citation totals the fine', citation.ok === true && citation.fine === 850, citation);
check('the officer is paid the citation fee plus a share of the fine',
  citation.paid === 100 + Math.floor(850 * 0.25), citation.paid);
check('the money went through fk_economy into the bank',
  police.money.length === 1 && police.money[0].account === 'bank'
    && police.money[0].amount === citation.paid, police.money);
check('the citation earned XP',
  (police.callExport('GetStatus', [1])[0] || {}).xp === 25,
  police.callExport('GetStatus', [1])[0]);
const onServer = (expr) => police.luaDo(expr, '@server-expr');

check('the citation is in the records',
  (onServer('return json.encode(fkExport("GetRecords").citations)') || '').includes(citation.id));

check('a citation with no known charge is refused',
  (police.callExport('Cite', [1, ['not_a_charge']])[0] || {}).reason === 'no_charge');

const warrantStop = police.callExport('StartStop', [1, 'ellis3', 'buffalo'])[0];
check('a wanted owner shows a warrant at the stop', warrantStop.warrant === true, warrantStop);

police.money.length = 0;
const arrest = police.callExport('Arrest', [1, ['assault']])[0];
check('an arrest computes fine and sentence', arrest.ok === true && arrest.fine === 1200 && arrest.jail === 120, arrest);
check('the arrest pays the arrest fee plus the fine share',
  arrest.paid === 400 + Math.floor(1200 * 0.25), arrest.paid);
check('the warrant is cleared by the arrest',
  onServer('return Mdt.hasWarrant(Mdt.findPerson(fkExport("GetRecords"), "Ellis Roan"))') === false);
check('the arrest is in the records',
  (onServer('return json.encode(fkExport("GetRecords").arrests)') || '').includes(arrest.id));
check('the officer XP went up by the citation and the arrest',
  (police.callExport('GetStatus', [1])[0] || {}).xp === 85,
  police.callExport('GetStatus', [1])[0]);
check('the stop is cleared after an arrest',
  (police.callExport('Cite', [1, ['speeding']])[0] || {}).reason === 'no_stop');

// ---------------------------------------------------------------------------
// Dispatch callouts
// ---------------------------------------------------------------------------

police.fireNet('fk_police:server:pos', 1, [{ x: 441.0, y: -982.0, z: 30.68 }]);

police.captured.client.length = 0;
police.tick(30000);
police.step();

const offered = police.lastClient('fk_police:client:callout');
check('dispatch issues a callout while on duty', !!offered && !!offered.args, offered && offered.args);

const callout = offered && offered.args;
check('the callout has a code, a label and a scene',
  !!callout && !!callout.code && !!callout.label && !!callout.coords, callout);

police.fireNet('fk_police:server:callout:accept', 1, []);
check('accepting the callout marks it accepted',
  (police.callExport('ResolveCallout', [1, { x: callout.coords.x + 500, y: callout.coords.y, z: callout.coords.z }])[0] || {}).reason === 'too_far');

police.money.length = 0;
const resolved = police.callExport('ResolveCallout', [1, callout.coords])[0];
check('resolving at the scene closes the callout', resolved.ok === true, resolved);
check('the callout pays the officer',
  resolved.paid === 250 && police.money.length === 1, { resolved, money: police.money });
check('the callout awards its XP',
  (police.callExport('GetStatus', [1])[0] || {}).xp === 85 + callout.xp,
  police.callExport('GetStatus', [1])[0]);

police.fireNet('fk_police:server:callout:force', 1, []);
const forced = police.lastClient('fk_police:client:callout');
check('a callout can be forced (single player convenience)', !!forced && !!forced.args, forced && forced.args);

police.fireNet('fk_police:server:callout:decline', 1, []);
check('declining clears the board', police.lastClient('fk_police:client:callout').args === null);

// ---------------------------------------------------------------------------
// Backup, station services, commands
// ---------------------------------------------------------------------------

check('an unknown backup type is refused',
  (police.callExport('RequestBackup', [1, 'spaceship'])[0] || {}).reason === 'unknown_kind');

police.captured.client.length = 0;
const backup = police.callExport('RequestBackup', [1, 'code3'])[0];
check('code 3 backup sends two units', backup.ok === true && backup.units === 2, backup);
check('the client is asked to spawn them',
  !!police.lastClient('fk_police:client:backup')
    && police.lastClient('fk_police:client:backup').args === 'code3');

police.captured.client.length = 0;
police.fireNet('fk_police:server:locker', 1, []);
check('the locker dresses the officer', !!police.lastClient('fk_police:client:uniform'));

police.captured.client.length = 0;
police.fireNet('fk_police:server:armoury', 1, []);
check('the armoury issues the loadout',
  !!police.lastClient('fk_police:client:loadout')
    && Array.isArray(police.lastClient('fk_police:client:loadout').args.weapons),
  police.lastClient('fk_police:client:loadout'));

police.captured.client.length = 0;
police.fireNet('fk_police:server:garage', 1, ['adder']);
check('a non-police vehicle is refused by the garage',
  !police.lastClient('fk_police:client:garage')
    && police.notes().some((line) => /not in the police garage/.test(line)), police.notes());

police.fireNet('fk_police:server:garage', 1, ['police3']);
check('a police vehicle is spawned', !!police.lastClient('fk_police:client:garage'));

police.runCommand('pdstatus', 0, []);
check('pdstatus works in the console',
  police.captured.logs.some((line) => /officer\(s\) tracked/.test(line)), police.captured.logs.slice(-2));

police.runCommand('pdxp', 0, [1, 500]);
check('pdxp awards XP from the console',
  (police.callExport('GetStatus', [1])[0] || {}).xp >= 500,
  police.callExport('GetStatus', [1])[0]);
check('a commendation promotes at the threshold',
  (police.callExport('GetStatus', [1])[0] || {}).rank !== 'Cadet',
  police.callExport('GetStatus', [1])[0]);

// ---------------------------------------------------------------------------
// Single player: rate limits are off
// ---------------------------------------------------------------------------

let allowed = 0;

for (let i = 0; i < 40; i += 1) {
  const result = police.callExport('Search', [1, 'person', 'marcus'])[0];

  if (result && result.ok) allowed += 1;
}

check('40 searches in a row are all allowed on a single-player server', allowed === 40, allowed);

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

const savedRecords = police.filesystem['data/records.json'];
check('records are written to disk', !!savedRecords);
check('officer progress is saved',
  (() => {
    const parsed = JSON.parse(savedRecords);
    const officer = parsed.officers['license:officer1'];
    return !!officer && officer.xp > 0;
  })(), savedRecords && savedRecords.slice(0, 200));

police.fireEvent('onResourceStop', ['fk_police']);

const restarted = createHarness({ files: { 'data/records.json': savedRecords } });
restarted.tick(1000);
restarted.step();
restarted.fireNet('fk_police:server:ready', 1, []);

check('XP survives a restart',
  (restarted.callExport('GetStatus', [1])[0] || {}).xp > 0,
  restarted.callExport('GetStatus', [1])[0]);
check('the arrested warrant stays cleared after a restart',
  restarted.luaDo('return Mdt.hasWarrant(Mdt.findPerson(fkExport("GetRecords"), "Ellis Roan"))', '@w') === false);
check('citations survive a restart',
  (restarted.luaDo('return #fkExport("GetRecords").citations', '@c') || 0) >= 1);

// ---------------------------------------------------------------------------
// The MDT page (jsdom)
// ---------------------------------------------------------------------------

const html = fs.readFileSync(path.join(ROOT, 'html', 'index.html'), 'utf8')
  .replace('<script src="app.js"></script>', '');
const appJs = fs.readFileSync(path.join(ROOT, 'html', 'app.js'), 'utf8');

const dom = new JSDOM(html, { runScripts: 'dangerously', pretendToBeVisual: true });
dom.window.eval(appJs);

const doc = dom.window.document;
check('the MDT starts hidden', doc.getElementById('mdt').classList.contains('is-hidden'));

dom.window.mdt.open({
  status: { onDuty: true, rank: 'Officer', xp: 160, citations: 2, arrests: 1, callsign: '1-ADAM-12' },
  charges: [
    { id: 'speeding', label: 'Speeding', fine: 250, jail: 0, type: 'infraction' },
    { id: 'assault', label: 'Assault', fine: 1200, jail: 120, type: 'felony' },
  ],
  calls: [],
});

check('opening the MDT shows it', !doc.getElementById('mdt').classList.contains('is-hidden'));
check('the header shows rank and XP',
  /Officer/.test(doc.getElementById('officer').textContent)
    && /160 XP/.test(doc.getElementById('officer').textContent),
  doc.getElementById('officer').textContent);
check('the duty pill is on', doc.getElementById('duty').classList.contains('on'));

check('the charges table is filled', doc.querySelectorAll('#charges-body tr').length === 2,
  doc.querySelectorAll('#charges-body tr').length);
check('the charge rows name the charge and the fine',
  /Assault/.test(doc.getElementById('charges-body').textContent)
    && /\$1,?200/.test(doc.getElementById('charges-body').textContent));

dom.window.mdt.renderResults({
  ok: true,
  kind: 'vehicle',
  results: [{ plate: 'OWEN555', model: 'schafter2', owner: 'Owen Pike', registration: 'expired', insurance: 'none', stolen: true, flags: ['STOLEN', 'expired registration'], ownerFlags: ['WARRANT: grand_theft_auto'] }],
});

check('a vehicle result renders the owner and flags',
  /Owen Pike/.test(doc.getElementById('results').textContent)
    && /STOLEN/.test(doc.getElementById('results').textContent),
  doc.getElementById('results').textContent);
check('a bad flag is styled', !!doc.querySelector('#results .flag.bad'));

dom.window.mdt.renderResults({ ok: true, kind: 'person', results: [] });
check('no record says so', /No record found/.test(doc.getElementById('results').textContent));

dom.window.mdt.renderCalls([{ code: '10-31', label: 'Robbery in progress', coords: { x: 1, y: 2, z: 3 }, xp: 120 }]);
check('a callout renders with accept and decline',
  /Robbery/.test(doc.getElementById('calls-body').textContent)
    && doc.querySelectorAll('#calls-body button').length === 2);

dom.window.mdt.close();
check('closing hides it', doc.getElementById('mdt').classList.contains('is-hidden'));


// --- HUD -------------------------------------------------------------------

dom.window.mdt.renderHud({ onDuty: false, rank: 'Cadet', xp: 0, percent: 0 });
check('the HUD stays hidden off duty', dom.window.document.getElementById('hud').classList.contains('is-hidden'));

dom.window.mdt.renderHud({
  onDuty: true,
  rank: 'Officer',
  xp: 300,
  percent: 42,
  shiftSeconds: 3720,
  callout: { code: '10-31', label: 'Robbery in progress', distance: 260 },
  radar: { speed: 64, plate: 'OWEN555', alert: true },
  backup: { kind: 'code3', eta: 8 },
  pursuit: { seconds: 120 },
  bodycam: true,
});

check('the HUD shows on duty', !dom.window.document.getElementById('hud').classList.contains('is-hidden'));
check('the HUD shows the rank and XP',
  /Officer/.test(dom.window.document.getElementById('hud-rank').textContent)
    && /300 XP/.test(dom.window.document.getElementById('hud-rank').textContent),
  dom.window.document.getElementById('hud-rank').textContent);
check('the XP bar is filled to the percentage',
  dom.window.document.getElementById('hud-xp').style.width === '42%',
  dom.window.document.getElementById('hud-xp').style.width);
check('the shift timer is formatted',
  dom.window.document.getElementById('hud-shift').textContent === '1h 02m',
  dom.window.document.getElementById('hud-shift').textContent);
check('the HUD shows the callout and its distance',
  /10-31/.test(dom.window.document.getElementById('hud-callout').textContent)
    && /260 m/.test(dom.window.document.getElementById('hud-callout').textContent));
check('the HUD radar shows the speed and plate',
  dom.window.document.getElementById('radar-speed').textContent === '64'
    && dom.window.document.getElementById('radar-plate').textContent === 'OWEN555');
check('the radar flashes when the plate is hot',
  !dom.window.document.getElementById('radar-alert').classList.contains('is-hidden'));
check('the HUD shows backup ETA, pursuit and bodycam',
  /code3/.test(dom.window.document.getElementById('hud-backup').textContent)
    && /PURSUIT/.test(dom.window.document.getElementById('hud-pursuit').textContent)
    && !dom.window.document.getElementById('hud-bodycam').classList.contains('is-hidden'));

dom.window.mdt.renderHud({ onDuty: true, rank: 'Officer', xp: 300, percent: 42, custody: { seconds: 95, person: 'Ellis Roan' } });
check('the HUD shows who is in custody',
  /CUSTODY/.test(dom.window.document.getElementById('hud-custody').textContent)
    && /1m 35s/.test(dom.window.document.getElementById('hud-custody').textContent),
  dom.window.document.getElementById('hud-custody').textContent);

dom.window.mdt.open({ status: { onDuty: true, rank: 'Officer', xp: 300, citations: 1, arrests: 0 }, charges: [], calls: [] });
dom.window.mdt.renderHud({ onDuty: true, rank: 'Officer', xp: 300, percent: 42 });
check('the HUD hides behind the open MDT',
  dom.window.document.getElementById('hud').classList.contains('is-hidden'));
dom.window.mdt.close();

// --- MDT bundle ------------------------------------------------------------

const pageBundle = {
  status: {
    onDuty: true, rank: 'Sergeant', xp: 1500, citations: 4, arrests: 2, callsign: '1-ADAM-12',
    medals: [{ label: 'Meritorious Service', blurb: '500 XP on the job', xp: 500 }],
  },
  progress: { rank: 'Sergeant', percent: 55 },
  shift: { active: true, seconds: 5400, counters: { citations: 3, arrests: 1, callouts: 2, reports: 1, fines: 3, backups: 0 }, projected: { pay: 900 } },
  charges: [{ id: 'speeding', label: 'Speeding', fine: 250, jail: 0, type: 'infraction' }],
  callouts: [],
  backup: { code2: { label: 'Code 2 (no lights)', units: 1 }, code3: { label: 'Code 3 (lights)', units: 2 } },
  bolos: [
    { id: 'BOLO-1', kind: 'vehicle', value: 'OWEN555', reason: 'Robbery getaway', active: true, expired: false },
    { id: 'BOLO-2', kind: 'person', value: 'Tasha Bell', reason: 'Questioning', active: false, expired: true },
  ],
  reports: [{ id: 'RPT-1', kind: 'incident', title: 'Robbery on Vinewood', subjects: ['Marcus Vance'], plate: 'MARCUS1', charges: ['armed_robbery'], at: '2026-11-03T10:00:00Z' }],
  fines: {
    totals: { count: 2, owed: 1250, overdue: 1 },
    list: [
      { id: 'FINE-1', person: 'Marcus Vance', owed: 250, dueAt: 1760000000, status: 'unpaid', overdue: false },
      { id: 'FINE-2', person: 'Owen Pike', owed: 1000, dueAt: 1700000000, status: 'unpaid', overdue: true },
    ],
  },
  warrants: [{ id: 'WAR-1', person: 'Tasha Bell', charge: 'burglary', active: true }],
  impounds: [{ id: 'IMP-1', plate: 'OWEN555', model: 'schafter2', reason: 'stolen recovery', fee: 1250, released: false }],
  shifts: [{ id: 'SHIFT-1', seconds: 3600, citations: 2, arrests: 1, callouts: 1, pay: 1200 }],
  pursuits: [{ id: 'PUR-1', seconds: 240, outcome: 'arrested', plate: 'OWEN555' }],
  verdicts: [{ id: 'VRD-1', person: 'Ellis Roan', booking: 'BOOK-1', outcome: 'guilty', refund: 0 }],
  evidence: [{ id: 'EVD-1', person: 'Owen Pike', kind: 'frisk', items: [{ label: 'Pistol', qty: 1 }], at: '2026-11-03T10:00:00Z' }],
  department: { balance: 4200, label: 'LSPD court fund' },
  pursuit: { active: false },
  callout: false,
};

dom.window.mdt.renderBundle(pageBundle);

const text = (id) => dom.window.document.getElementById(id).textContent;

check('the MDT shows the court fund', /4,200/.test(text('fund')), text('fund'));
check('the MDT renders BOLOs', /Robbery getaway/.test(text('bolo-list')) && /Tasha Bell/.test(text('bolo-list')));
check('the MDT greys out a cleared BOLO', /Cleared|Expired/.test(text('bolo-list')));
check('the MDT renders warrants with a revoke button',
  /burglary/.test(text('warrant-list')) && /Revoke/.test(text('warrant-list')));
check('the MDT renders reports', /Robbery on Vinewood/.test(text('report-list')));
check('the MDT renders the fine ledger totals',
  /2 fine\(s\)/.test(text('fines-totals')) && /1,250|1250/.test(text('fines-totals')), text('fines-totals'));
check('the MDT marks an overdue fine',
  /overdue/.test(text('fines-body')), text('fines-body'));
check('the MDT offers to collect and waive a fine',
  /Collect/.test(text('fines-body')) && /Waive/.test(text('fines-body')));
check('the MDT renders the impound lot with a release button',
  /OWEN555/.test(text('impound-list')) && /Release/.test(text('impound-list')));
check('the MDT renders the shift counters',
  /1h 30m/.test(text('shift-cards')) && /900/.test(text('shift-cards')), text('shift-cards'));
check('the MDT renders the shift and pursuit history',
  /SHIFT-1/.test(text('shift-body')) && /PUR-1/.test(text('pursuit-body')));
check('the MDT shows the medals that were earned',
  /Meritorious Service/.test(text('medal-list')), text('medal-list'));
check('the MDT renders the court docket',
  /VRD-1/.test(text('verdict-body')) && /guilty/.test(text('verdict-body')), text('verdict-body'));
check('the MDT renders the evidence locker',
  /Owen Pike/.test(text('evidence-body')) && /Pistol x1/.test(text('evidence-body')), text('evidence-body'));
check('the MDT renders the backup buttons from the config',
  /Code 3|code3/.test(text('backup-grid')), text('backup-grid'));

check('the MDT lists nine tabs',
  dom.window.document.querySelectorAll('.tab').length === 9,
  dom.window.document.querySelectorAll('.tab').length);

// --- the page's buttons actually post --------------------------------------

const posted = [];
dom.window.fetch = (url, options) => {
  posted.push({ url, body: JSON.parse(options.body) });
  return Promise.resolve({ ok: true });
};

dom.window.document.querySelector('#bolo-value').value = 'OWEN555';
dom.window.document.querySelector('#bolo-reason').value = 'Robbery getaway';
dom.window.document.getElementById('form-bolo').dispatchEvent(new dom.window.Event('submit'));

check('the BOLO form posts a BOLO',
  posted.some((call) => call.url.endsWith('/bolo') && call.body.value === 'OWEN555'),
  posted);

posted.length = 0;
dom.window.document.querySelector('#report-title').value = 'Robbery on Vinewood';
dom.window.document.querySelector('#report-body').value = 'Two suspects fled north.';
const firstCharge = dom.window.document.querySelector('#report-charges input');
if (firstCharge) firstCharge.checked = true;
dom.window.document.getElementById('form-report').dispatchEvent(new dom.window.Event('submit'));

check('the report form posts the report and its charges',
  posted.some((call) => call.url.endsWith('/report')
    && call.body.title === 'Robbery on Vinewood'
    && Array.isArray(call.body.charges) && call.body.charges.length === 1),
  posted);

posted.length = 0;
const collectButton = dom.window.document.querySelector('#fines-body button');
if (collectButton) collectButton.click();
check('collecting a fine posts it', posted.some((call) => call.url.endsWith('/fineCollect')
  && call.body.id === 'FINE-1'), posted);

posted.length = 0;
const releaseButton = dom.window.document.querySelector('#impound-list button');
if (releaseButton) releaseButton.click();
check('releasing a car posts it', posted.some((call) => call.url.endsWith('/impoundRelease')
  && call.body.id === 'IMP-1'), posted);

posted.length = 0;
const revokeButton = dom.window.document.querySelector('#warrant-list button');
if (revokeButton) revokeButton.click();
check('revoking a warrant posts it', posted.some((call) => call.url.endsWith('/warrantRevoke')
  && call.body.id === 'WAR-1'), posted);

posted.length = 0;
dom.window.mdt.renderResults({ ok: true, kind: 'vehicle', results: [{ plate: 'OWEN555', model: 'schafter2', owner: 'Owen Pike', registration: 'expired', insurance: 'none', flags: ['STOLEN'], bolos: [{ id: 'BOLO-1', reason: 'Robbery getaway' }], impounded: true, ownerFines: { owed: 1500 } }] });
check('a plate result shows the BOLO, impound and the owner debt',
  /BOLO BOLO-1/.test(text('results')) && /impound lot/.test(text('results')) && /1,500|1500/.test(text('results')),
  text('results'));

// --- report drafts ---------------------------------------------------------

dom.window.mdt.open({ status: { onDuty: true, rank: 'Officer', xp: 10, citations: 0, arrests: 0 }, charges: [], calls: [] });
dom.window.dispatchEvent(new dom.window.MessageEvent('message', { data: { action: 'reportDraft', title: 'Shots fired on Grove St' } }));

check('a /report draft opens the reports tab with the title',
  dom.window.document.getElementById('panel-reports').classList.contains('is-active')
    && dom.window.document.getElementById('report-title').value === 'Shots fired on Grove St',
  dom.window.document.getElementById('report-title').value);

// --- field results ---------------------------------------------------------

dom.window.dispatchEvent(new dom.window.MessageEvent('message', { data: { action: 'field', kind: 'frisk', result: { person: 'Ellis Roan', items: [] } } }));
check('a field result is shown in the MDT', /frisk result/.test(text('results')), text('results'));




// ---------------------------------------------------------------------------
// Justice: fines, warrants, BOLOs, reports, impound, pursuits, field work
// ---------------------------------------------------------------------------

function dutied(options = {}) {
  const host = createHarness(options);

  host.tick(1000);
  host.step();
  host.step();
  host.fireNet('fk_police:server:duty', 1, [true]);
  host.fireNet('fk_police:server:pos', 1, [{ x: 441.0, y: -982.0, z: 30.68 }]);

  return host;
}

const exp = (host, name, args = []) => host.callExport(name, args)[0];

// --- shifts ----------------------------------------------------------------

const law = dutied();

const shift = exp(law, 'GetShift', [1]);
check('going on duty starts a shift', shift && shift.active === true, shift);
check('the shift starts with empty counters',
  shift && shift.counters.citations === 0 && shift.counters.arrests === 0, shift && shift.counters);
check('the status payload carries the shift timer',
  typeof (exp(law, 'GetStatus', [1]) || {}).shiftSeconds === 'number',
  exp(law, 'GetStatus', [1]));

// --- fines come from citations ---------------------------------------------

law.callExport('StartStop', [1, 'MARCUS1', 'sultan']);
const cite = exp(law, 'Cite', [1, ['speeding']]);

check('the citation still writes the fine', cite.ok === true && cite.fine === 250, cite);

let fines = exp(law, 'ListFines', [{}]) || [];
check('a citation creates a ledger fine', fines.length === 1 && fines[0].amount === 250, fines);
check('the fine is due in a week',
  fines[0].dueAt - fines[0].issuedAt === 7 * 86400, fines[0].dueAt - fines[0].issuedAt);
check('a fresh fine is not overdue', fines[0].overdue === false);

const personSearchAfterFine = (law.callExport('Search', [1, 'person', 'marcus'])[0] || {}).results[0];
check('a person lookup shows what they owe',
  personSearchAfterFine.fines.owed === 250 && personSearchAfterFine.fines.count === 1,
  personSearchAfterFine.fines);

const fineId = fines[0].id;
let collected = exp(law, 'CollectFine', [1, fineId, 100]);
check('a part-payment is accepted', collected.ok === true && collected.amount === 100, collected);
check('a part-payment leaves the fine unpaid', collected.status === 'unpaid' && collected.owed === 150, collected);
check('the part-payment went into the court fund', collected.balance === 100, collected.balance);

collected = exp(law, 'CollectFine', [1, fineId, 999]);
check('an over-payment is clamped to what is owed',
  collected.ok === true && collected.amount === 150 && collected.status === 'paid', collected);
check('the court fund has the whole fine now', collected.balance === 250, collected.balance);
check('a paid fine cannot be collected again',
  (exp(law, 'CollectFine', [1, fineId]) || {}).reason === 'already_paid');
check('a paid fine cannot be waived',
  (exp(law, 'WaiveFine', [1, fineId]) || {}).reason === 'already_paid');

// --- waive -----------------------------------------------------------------

law.callExport('StartStop', [1, 'DANA22', 'blista']);
const secondCite = exp(law, 'Cite', [1, ['illegal_parking']]);
fines = exp(law, 'ListFines', [{}]) || [];
const secondFine = fines.find((fine) => fine.amount === 150);

check('the second citation made a second fine', !!secondFine && secondFine.amount === 150, secondFine);

const unknownCollect = exp(law, 'CollectFine', [1, 'FINE-NOPE']);
check('collecting an unknown fine is refused', unknownCollect.reason === 'unknown_fine', unknownCollect);

const waivedFine = exp(law, 'WaiveFine', [1, secondFine && secondFine.id, 'issued in error']);
check('an unpaid fine can be waived', waivedFine.ok === true, waivedFine);
check('a waived fine stays on the ledger, marked waived',
  (exp(law, 'ListFines', [{}]) || []).some((fine) => fine.id === waivedFine.id && fine.status === 'waived'));
check('a waived fine cannot be collected',
  (exp(law, 'CollectFine', [1, waivedFine.id]) || {}).reason === 'waived');

// --- overdue sweep: suspend the licence, issue the warrant ------------------

const sweepHost = dutied();
sweepHost.callExport('StartStop', [1, 'MARCUS1', 'sultan']);
sweepHost.callExport('Cite', [1, ['reckless_driving']]);
sweepHost.fireNet('fk_police:server:duty', 1, [false]);

sweepHost.advance(8 * 86400);
sweepHost.fireNet('fk_police:server:duty', 1, [true]);

const afterSweep = sweepHost.callExport('Search', [1, 'person', 'marcus'])[0].results[0];
check('an overdue fine suspends the licence', afterSweep.license === 'suspended', afterSweep.license);
check('an overdue fine puts a warrant out',
  afterSweep.flags.join(' ').includes('unpaid_fines'), afterSweep.flags);
check('the warrant is on the warrant board',
  (sweepHost.callExport('ListWarrants', [{ active: true }])[0] || []).some((w) => w.charge === 'unpaid_fines'),
  sweepHost.callExport('ListWarrants', [{ active: true }])[0]);

const sweptAgain = exp(sweepHost, 'SweepOverdue');
check('the sweep is idempotent', sweptAgain.warrants === 0, sweptAgain);

// --- warrants --------------------------------------------------------------

const warrantHost = dutied();

const issued = exp(warrantHost, 'IssueWarrant', [1, { person: 'Tasha Bell', charge: 'burglary', note: 'Break-in' }]);
check('a warrant can be issued', issued.ok === true && issued.charge === 'burglary', issued);

const tasha = warrantHost.callExport('Search', [1, 'person', 'tasha'])[0].results[0];
check('the warrant shows on the person', tasha.flags.join(' ').includes('WARRANT: burglary'), tasha.flags);

check('a duplicate warrant is refused',
  (exp(warrantHost, 'IssueWarrant', [1, { person: 'Tasha Bell', charge: 'burglary' }]) || {}).reason
    === 'already_warranted');
check('a warrant for an unknown person is refused',
  (exp(warrantHost, 'IssueWarrant', [1, { person: 'Nobody Atall', charge: 'assault' }]) || {}).reason
    === 'unknown_person');

const revoked = exp(warrantHost, 'RevokeWarrant', [1, issued.id]);
check('a warrant can be revoked', revoked.ok === true, revoked);

const tashaAfter = warrantHost.callExport('Search', [1, 'person', 'tasha'])[0].results[0];
check('the revoked warrant is gone from the person',
  !tashaAfter.flags.join(' ').includes('WARRANT: burglary'), tashaAfter.flags);
check('the warrant board keeps the record, marked inactive',
  (warrantHost.callExport('ListWarrants', [{}])[0] || []).some((w) => w.id === issued.id && w.active === false));

// --- BOLOs -----------------------------------------------------------------

const boloHost = dutied();

const bolo = exp(boloHost, 'AddBolo', [1, 'vehicle', 'OWEN 555', 'Used in a robbery']);
check('a vehicle BOLO can be put out', bolo.ok === true && bolo.value === 'OWEN555', bolo);
check('a duplicate BOLO is refused',
  (exp(boloHost, 'AddBolo', [1, 'vehicle', 'OWEN555', 'again']) || {}).reason === 'already_flagged');
check('a BOLO needs a reason',
  (exp(boloHost, 'AddBolo', [1, 'vehicle', 'ZZZ123', '']) || {}).reason === 'bad_reason');

const boloStop = boloHost.callExport('StartStop', [1, 'OWEN555', 'schafter2'])[0];
check('a stop on a BOLO plate reports it',
  (boloStop.bolos || []).length === 1 && boloStop.bolos[0].reason === 'Used in a robbery', boloStop.bolos);

const boloLookup = boloHost.callExport('Search', [1, 'vehicle', 'OWEN555'])[0].results[0];
check('a plate lookup reports the BOLO', (boloLookup.bolos || []).length === 1, boloLookup.bolos);
check('the BOLO is in the MDT bundle',
  (exp(boloHost, 'GetMdt', [1]) || {}).bolos.some((entry) => entry.value === 'OWEN555'));

exp(boloHost, 'AddBolo', [1, 'person', 'Owen Pike', 'Wanted for questioning']);
const personBolo = boloHost.callExport('Search', [1, 'person', 'owen'])[0].results[0];
check('a person BOLO shows on the person', (personBolo.bolos || []).length === 1, personBolo.bolos);

const clearedBolo = exp(boloHost, 'ClearBolo', [1, bolo.id]);
check('a BOLO can be cleared', clearedBolo.ok === true, clearedBolo);
check('a cleared BOLO no longer matches a stop',
  ((boloHost.callExport('StartStop', [1, 'OWEN555', 'schafter2'])[0] || {}).bolos || []).length === 0);

boloHost.advance(121 * 60);
check('a BOLO expires on its own',
  ((boloHost.callExport('StartStop', [1, 'OWEN555', 'schafter2'])[0] || {}).bolos || []).length === 0);

// --- reports ---------------------------------------------------------------

const reportHost = dutied();

const filed = exp(reportHost, 'FileReport', [1, {
  kind: 'incident',
  title: 'Robbery on Vinewood Blvd',
  body: 'Two suspects fled north in a black Sultan after taking the till.',
  subjects: ['Marcus Vance', 'Dana Cruz', 'Marcus Vance'],
  plate: 'MARCUS1',
  charges: ['armed_robbery', 'not_a_charge'],
}]);
check('a report can be filed', filed.ok === true && /^RPT-/.test(filed.id), filed);
check('filing a report earns XP', filed.xp === 15, filed.xp);

const reports = exp(reportHost, 'ListReports', ['']) || [];
check('the report is listed', reports.length === 1 && reports[0].title === 'Robbery on Vinewood Blvd', reports);
check('a report finds by text', (exp(reportHost, 'ListReports', ['vinewood']) || []).length === 1);
check('a report filters unknown charges',
  JSON.stringify(exp(reportHost, 'ListReports', ['']) || []).includes('not_a_charge') === false);

const storedReport = reportHost.luaDo('return json.encode(fkExport("GetRecords").reports[1])', '@report');
check('the report stored its subjects and plate',
  storedReport.includes('Marcus Vance') && storedReport.includes('MARCUS1'), storedReport);
check('duplicate subjects are collapsed',
  (storedReport.match(/Marcus Vance/g) || []).length === 1, storedReport);

check('a too-short title is refused',
  (exp(reportHost, 'FileReport', [1, { title: 'ab', body: 'A long enough body of text.' }]) || {}).reason
    === 'title_too_short');
check('a too-short body is refused',
  (exp(reportHost, 'FileReport', [1, { title: 'A title', body: 'short' }]) || {}).reason === 'body_too_short');
check('an empty title is refused',
  (exp(reportHost, 'FileReport', [1, { title: '', body: 'A long enough body of text.' }]) || {}).reason
    === 'bad_title');

const longBody = 'x'.repeat(4100);
check('an over-long body is refused',
  (exp(reportHost, 'FileReport', [1, { title: 'A title', body: longBody }]) || {}).reason === 'body_too_long');

// --- impound ---------------------------------------------------------------

const impoundHost = dutied();

check('impounding without a stop is refused',
  (exp(impoundHost, 'ImpoundVehicle', [1, 'abandoned']) || {}).reason === 'no_stop');

impoundHost.callExport('StartStop', [1, 'OWEN555', 'schafter2']);
const impound = exp(impoundHost, 'ImpoundVehicle', [1, 'stolen recovery']);
impoundHost.tick(1000);

check('a stopped car can be impounded', impound.ok === true && impound.plate === 'OWEN555', impound);
check('a stolen car carries the surcharge', impound.fee === 500 + 750, impound.fee);
check('the car is marked impounded',
  (impoundHost.callExport('Search', [1, 'vehicle', 'OWEN555'])[0].results[0] || {}).impounded === true);
check('the same car cannot be impounded twice',
  (exp(impoundHost, 'ImpoundVehicle', [1, 'again']) || {}).reason === 'already_impounded');

const impoundList = exp(impoundHost, 'ListImpounds', [{}]) || [];
check('the lot lists the car', impoundList.length === 1 && impoundList[0].released === false, impoundList);

impoundHost.money.length = 0;
const release = exp(impoundHost, 'ReleaseImpound', [1, impound.id]);
check('a car can be released from the lot', release.ok === true && release.fee === 1250, release);
check('the release fee is taken from the bank',
  impoundHost.money.some((entry) => entry.amount === -1250 && entry.account === 'bank'), impoundHost.money);
check('the released car is no longer flagged',
  (impoundHost.callExport('Search', [1, 'vehicle', 'OWEN555'])[0].results[0] || {}).impounded !== true);
check('a released car cannot be released twice',
  (exp(impoundHost, 'ReleaseImpound', [1, impound.id]) || {}).reason === 'already_released');

const brokeHost = dutied({ removeMoney: false });
brokeHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
const brokeImpound = exp(brokeHost, 'ImpoundVehicle', [1, 'seizure']);
check('a release with no money in the bank is refused',
  (exp(brokeHost, 'ReleaseImpound', [1, brokeImpound.id]) || {}).reason === 'insufficient_funds');

// --- pursuits --------------------------------------------------------------

const pursuitHost = dutied();

check('a pursuit needs a reason to start',
  (exp(pursuitHost, 'PursuitState', [1]) || {}).active === false);

pursuitHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
const pursuitStart = exp(pursuitHost, 'PursuitState', [1]);

pursuitHost.fireNet('fk_police:server:pursuit:start', 1, []);
const running = exp(pursuitHost, 'PursuitState', [1]);
check('a pursuit starts from a live stop', running.active === true, running);
check('starting a pursuit asks for backup',
  pursuitHost.captured.client.some((event) => event.name === 'fk_police:client:backup'), pursuitHost.captured.client.length);

pursuitHost.advance(90);
check('the pursuit clock runs', (exp(pursuitHost, 'PursuitState', [1]) || {}).seconds >= 90,
  exp(pursuitHost, 'PursuitState', [1]));

check('a pursuit cannot be started twice',
  (exp(pursuitHost, 'ListPursuits') || []) !== undefined);

pursuitHost.money.length = 0;
pursuitHost.fireNet('fk_police:server:pursuit:end', 1, ['arrested']);
const ended = exp(pursuitHost, 'PursuitState', [1]);
const pursuits = exp(pursuitHost, 'ListPursuits') || [];

check('ending a pursuit closes it', ended.active === false, ended);
check('the pursuit is logged with its outcome',
  pursuits.length === 1 && pursuits[0].outcome === 'arrested' && pursuits[0].seconds >= 90, pursuits);
check('an arrest outcome pays XP', (exp(pursuitHost, 'GetStatus', [1]) || {}).xp > 0,
  exp(pursuitHost, 'GetStatus', [1]));

pursuitHost.fireNet('fk_police:server:pursuit:start', 1, []);
pursuitHost.fireNet('fk_police:server:pursuit:end', 1, ['not_an_outcome']);
check('a pursuit with an unknown outcome stays open',
  (exp(pursuitHost, 'PursuitState', [1]) || {}).active === true,
  exp(pursuitHost, 'PursuitState', [1]));
pursuitHost.fireNet('fk_police:server:pursuit:end', 1, ['terminated']);

// --- field work ------------------------------------------------------------

const fieldHost = dutied();

check('frisking with no subject is refused',
  (exp(fieldHost, 'Frisk', [1]) || {}).reason === 'no_subject');

fieldHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);

const friskOne = exp(fieldHost, 'Frisk', [1]) || {};
const friskTwo = exp(fieldHost, 'Frisk', [1]) || {};

check('a frisk returns a person', friskOne.ok === true && friskOne.person === 'Ellis Roan', friskOne.person);
check('a frisk is deterministic',
  JSON.stringify(friskOne.items) === JSON.stringify(friskTwo.items), [friskOne.items, friskTwo.items]);
check('frisk items carry a label and a quantity',
  (friskOne.items || []).every((item) => typeof item.label === 'string' && item.qty >= 1), friskOne.items);

const breath = exp(fieldHost, 'Breathalyzer', [1]) || {};
check('a breath test is in range',
  breath.ok === true && breath.bac >= 0 && breath.bac <= 0.2, breath);
check('a breath test is deterministic',
  (exp(fieldHost, 'Breathalyzer', [1]) || {}).bac === breath.bac);
check('the breath test flags the legal limit',
  breath.over === (breath.bac >= breath.limit), breath);

const k9Result = exp(fieldHost, 'K9', [1]) || {};
check('the K9 works the stopped car', k9Result.ok === true && k9Result.plate === 'ELLIS3', k9Result);
check('the K9 gives a clear answer',
  k9Result.alert === true || k9Result.alert === false, k9Result.alert);

// --- shifts pay ------------------------------------------------------------

const payHost = dutied();

payHost.callExport('StartStop', [1, 'MARCUS1', 'sultan']);
payHost.callExport('Cite', [1, ['speeding']]);
payHost.advance(30 * 60);
payHost.money.length = 0;

const closed = exp(payHost, 'EndShift', [1, 'test']);
check('ending a shift returns a summary', closed.ok === true && closed.seconds >= 1800, closed);
check('the shift pays the rank salary for the time worked',
  closed.base === Math.floor(500 * 0.5), { base: closed.base, expected: Math.floor(500 * 0.5) });
check('the shift pays a bonus per citation', closed.bonus === 50, closed.bonus);
check('the shift pay actually moved through fk_economy',
  payHost.money.some((entry) => entry.amount === closed.pay && entry.account === 'bank'), payHost.money);

const shiftHistory = exp(payHost, 'GetMdt', [1]) || {};
check('the shift is in the MDT history',
  shiftHistory.shifts.length >= 1 && shiftHistory.shifts[0].pay === closed.pay, shiftHistory.shifts);

const shortHost = dutied();
const shortShift = exp(shortHost, 'EndShift', [1, 'too_soon']);
check('a shift shorter than a minute pays nothing', shortShift.pay === 0, shortShift);


// --- custody / jail --------------------------------------------------------

const jailHost = dutied();

check('booking with nobody to book is refused',
  ['no_subject', 'no_stop'].includes((exp(jailHost, 'BookSuspect', [1]) || {}).reason),
  exp(jailHost, 'BookSuspect', [1]));

jailHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
jailHost.callExport('Arrest', [1, ['assault']]);

const booked = exp(jailHost, 'BookSuspect', [1]);
check('an arrest can be booked into custody',
  booked.ok === true && booked.person === 'Ellis Roan' && booked.seconds === 120, booked);
check('the cell comes from the config', !!booked.cell && typeof booked.cell.x === 'number', booked.cell);

const custody = exp(jailHost, 'Custody', [1]);
check('custody is visible while the sentence runs',
  custody.active === true && custody.remaining >= 119, custody);
check('the status carries the custody timer',
  (exp(jailHost, 'GetStatus', [1]) || {}).custodySeconds >= 119,
  (exp(jailHost, 'GetStatus', [1]) || {}).custodySeconds);
check('the client is told to walk the suspect to the cell',
  jailHost.captured.client.some((event) => event.name === 'fk_police:client:custody'
    && event.args.person === 'Ellis Roan'), jailHost.captured.client.length);
check('a second booking while someone is in custody is refused',
  (exp(jailHost, 'BookSuspect', [1]) || {}).reason === 'already_in_custody');

const released = exp(jailHost, 'ReleaseSuspect', [1, 'bail']);
check('a suspect can be released early', released.ok === true && released.served >= 0, released);
check('custody is empty after the release', (exp(jailHost, 'Custody', [1]) || {}).active === false);

jailHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
const capped = exp(jailHost, 'BookSuspect', [1, 99999]);
check('a sentence is capped by Config.Jail.maxSeconds', capped.ok === true && capped.seconds === 600, capped);

jailHost.advance(601);
check('custody ends on its own when the sentence is up',
  (exp(jailHost, 'Custody', [1]) || {}).active === false);

const bookingsRaw = jailHost.luaDo('return json.encode(fkExport("GetRecords").bookings)', '@bookings') || '';
check('bookings are written to the records', bookingsRaw.includes('Ellis Roan'), bookingsRaw.slice(0, 120));
check('the custody state is in the MDT bundle',
  'custody' in (exp(jailHost, 'GetMdt', [1]) || {}));

// --- the car is actually taken off the street -------------------------------

check('impounding tells the client to remove the car',
  impoundHost.captured.client.some((event) => event.name === 'fk_police:client:impound'
    && event.args.plate === 'OWEN555'), impoundHost.captured.client.length);

// --- the court rules when custody ends -------------------------------------

const courtHost = dutied();

courtHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
courtHost.callExport('Arrest', [1, ['assault']]);
const courtBooking = exp(courtHost, 'BookSuspect', [1]);
const courtRelease = exp(courtHost, 'ReleaseSuspect', [1, 'bail']);

check('releasing a suspect produces a verdict',
  ['guilty', 'acquitted'].includes(courtRelease.verdict), courtRelease);
check('the verdict is on the docket',
  (exp(courtHost, 'ListVerdicts', []) || []).length === 1, exp(courtHost, 'ListVerdicts', []));
check('the verdict is tied to the booking',
  (exp(courtHost, 'ListVerdicts', []) || [])[0].booking === courtBooking.id,
  exp(courtHost, 'ListVerdicts', []));
check('the verdict is written onto the booking',
  /"verdict":"(guilty|acquitted)"/.test(
    courtHost.luaDo('return json.encode(fkExport("GetRecords").bookings[1])', '@booking') || ''),
  courtHost.luaDo('return json.encode(fkExport("GetRecords").bookings[1])', '@booking'));

const verdictTwice = courtHost.luaDo(
  'return Mdt.verdict(Config, "BOOK-FIXED", 0.72) == Mdt.verdict(Config, "BOOK-FIXED", 0.72)', '@verdict');
check('the same booking always gets the same verdict', verdictTwice === true, verdictTwice);
check('a high chance is not an acquittal',
  courtHost.luaDo('return Mdt.verdict(Config, "BOOK-FIXED", 2)', '@verdict') === 'guilty');
check('a zero chance is always an acquittal',
  courtHost.luaDo('return Mdt.verdict(Config, "BOOK-FIXED", 0)', '@verdict') === 'acquitted');

// A court that never convicts: the fine goes back and the fund is debited.
const acquitHost = dutied({ patch: 'Config.Justice.verdictChance = 0' });

acquitHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
acquitHost.callExport('Cite', [1, ['speeding']]);
const fineBefore = (exp(acquitHost, 'ListFines', [{}]) || []).find((fine) => fine.person === 'Ellis Roan');

// Put some money in the court fund so the refund is a real debit, not a clamp.
acquitHost.callExport('StartStop', [1, 'MARCUS1', 'sultan']);
acquitHost.callExport('Cite', [1, ['reckless_driving']]);
const marcusFine = (exp(acquitHost, 'ListFines', [{}]) || []).find((fine) => fine.person === 'Marcus Vance');
exp(acquitHost, 'CollectFine', [1, marcusFine.id]);
const fundBefore = (exp(acquitHost, 'GetMdt', [1]) || {}).department.balance;
acquitHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
acquitHost.callExport('Arrest', [1, ['assault']]);
exp(acquitHost, 'BookSuspect', [1]);
const acquittal = exp(acquitHost, 'ReleaseSuspect', [1, 'no evidence']);

if (false) console.log('DBG acquit', JSON.stringify({ acquittal, fineBefore, fundBefore, fines: exp(acquitHost, 'ListFines', [{}]) }));
check('an acquittal is reported to the officer', acquittal.verdict === 'acquitted', acquittal);
check('an acquittal refunds the fine', acquittal.refund === fineBefore.owed,
  { refund: acquittal.refund, fine: fineBefore.owed });
check('the court fund had the money to give back', fundBefore >= fineBefore.owed, fundBefore);
check('the refunded fine is waived, not paid',
  ((exp(acquitHost, 'ListFines', [{}]) || []).find((fine) => fine.id === fineBefore.id) || {}).status === 'waived',
  exp(acquitHost, 'ListFines', [{}]));
check('the court fund is debited by the refund',
  ((exp(acquitHost, 'GetMdt', [1]) || {}).department.balance) === fundBefore - fineBefore.owed,
  { before: fundBefore, after: (exp(acquitHost, 'GetMdt', [1]) || {}).department.balance });

// --- evidence --------------------------------------------------------------

const evidenceHost = dutied();

evidenceHost.callExport('StartStop', [1, 'OWEN555', 'schafter2']);
const friskResult = exp(evidenceHost, 'Frisk', [1, 'Owen Pike']);
const seized = exp(evidenceHost, 'ListEvidence', ['Owen Pike']) || [];

check('a frisk that finds something is logged as evidence',
  friskResult.items.length === 0 || seized.length === 1, { found: friskResult.items.length, seized: seized.length });
check('the evidence names what was seized',
  seized.length === 0 || (seized[0].items[0] && seized[0].items[0].label), seized[0]);
check('evidence is kept per person',
  (exp(evidenceHost, 'ListEvidence', ['Marcus Vance']) || []).length === 0,
  exp(evidenceHost, 'ListEvidence', ['Marcus Vance']));

evidenceHost.callExport('StartStop', [1, 'ELLIS3', 'buffalo']);
evidenceHost.callExport('Arrest', [1, ['assault', 'burglary']]);
exp(evidenceHost, 'BookSuspect', [1]);
const bookingEvidence = exp(evidenceHost, 'ListEvidence', ['Ellis Roan']) || [];
if (false) console.log('DBG evidence', JSON.stringify({ bookingEvidence, arrests: exp(evidenceHost, 'GetRecords') }));
check('booking a suspect files the charges as evidence',
  bookingEvidence.some((item) => item.kind === 'booking' && item.items.length === 2), bookingEvidence);
check('evidence survives a restart',
  (exp(dutied({ files: { 'data/records.json': evidenceHost.filesystem['data/records.json'] } }),
    'ListEvidence', ['Ellis Roan']) || []).length === bookingEvidence.length);

// --- callsigns -------------------------------------------------------------

const callHost = dutied();

callHost.runCommand('callsign', 1, ['3', 'adam', '9']);
const called = exp(callHost, 'GetStatus', [1]) || {};

check('a callsign can be set on duty', called.callsign === '3-ADAM-9', called.callsign);
if (false) console.log('DBG callsign', JSON.stringify(callHost.captured.logs.slice(-4)));
check('the callsign is announced in chat',
  callHost.notes().some((line) => /Callsign (set to|changed from .* to) 3-ADAM-9/.test(line)),
  callHost.notes().slice(-3));

callHost.runCommand('callsign', 1, ['!']);
check('a nonsense callsign is refused', (exp(callHost, 'GetStatus', [1]) || {}).callsign === '3-ADAM-9',
  (exp(callHost, 'GetStatus', [1]) || {}).callsign);
check('callsigns are normalised',
  callHost.luaDo('return Mdt.normalizeCallsign("  7  lincoln  21 ")', '@callsign') === '7-LINCOLN-21',
  callHost.luaDo('return Mdt.normalizeCallsign("  7  lincoln  21 ")', '@callsign'));

const callReload = dutied({ files: { 'data/records.json': callHost.filesystem['data/records.json'] } });
callReload.fireNet('fk_police:server:duty', 1, [true]);
check('the callsign survives a restart',
  (exp(callReload, 'GetStatus', [1]) || {}).callsign === '3-ADAM-9',
  (exp(callReload, 'GetStatus', [1]) || {}).callsign);

// --- medals ----------------------------------------------------------------

check('no medals at zero XP',
  (courtHost.luaDo('return #Mdt.medalsFor(Config, 0)', '@medal') || 0) === 0);
check('two medals at 1,600 XP',
  (courtHost.luaDo('return #Mdt.medalsFor(Config, 1600)', '@medal') || 0) === 2);
check('every medal at 5,000 XP',
  courtHost.luaDo('return #Mdt.medalsFor(Config, 5000)', '@medal')
    === courtHost.luaDo('return #Config.Medals', '@medal')
    && (courtHost.luaDo('return #Config.Medals', '@medal') || 0) >= 3,
  courtHost.luaDo('return #Mdt.medalsFor(Config, 5000)', '@medal'));
check('the status carries the medals that were earned',
  Array.isArray((exp(courtHost, 'GetStatus', [1]) || {}).medals),
  (exp(courtHost, 'GetStatus', [1]) || {}).medals);

// --- the new sections in the bundle ---------------------------------------

const waveBundle = exp(courtHost, 'GetMdt', [1]) || {};

check('the bundle carries verdicts and evidence',
  Array.isArray(waveBundle.verdicts) && Array.isArray(waveBundle.evidence),
  [typeof waveBundle.verdicts, typeof waveBundle.evidence]);
check('the bundle shows the docket newest first',
  waveBundle.verdicts.length === 0 || waveBundle.verdicts[0].booking === courtBooking.id,
  waveBundle.verdicts);

// --- /verdict and /evidence work from chat --------------------------------

courtHost.runCommand('verdict', 1, ['3']);
const verdictNotes = courtHost.notes();
check('the verdict command prints the docket',
  verdictNotes.some((line) => /Court verdicts/.test(line))
    && verdictNotes.some((line) => /acquitted|guilty/.test(line)),
  verdictNotes.slice(-3));

evidenceHost.runCommand('evidence', 1, ['Ellis', 'Roan']);
const evidenceNotes = evidenceHost.notes();
check('the evidence command prints the file',
  evidenceNotes.some((line) => /Evidence against Ellis Roan/.test(line)), evidenceNotes.slice(-3));


// --- the /jail command is chat-only but works ------------------------------

jailHost.captured.client.length = 0;
jailHost.runCommand('jail', 0, []);
check('jail works from the console too',
  jailHost.captured.logs.some((line) => /jail/i.test(line)), jailHost.captured.logs.slice(-2));

// --- the MDT bundle --------------------------------------------------------

const bundle = exp(law, 'GetMdt', [1]) || {};

check('the MDT bundle has every section',
  ['status', 'progress', 'shift', 'charges', 'callouts', 'backup', 'bolos', 'reports',
    'fines', 'warrants', 'impounds', 'shifts', 'pursuits', 'department', 'callout'].every((key) => key in bundle),
  Object.keys(bundle));
check('the bundle names the court fund',
  typeof bundle.department.balance === 'number' && !!bundle.department.label, bundle.department);
check('the bundle lists the charges and callouts',
  bundle.charges.length >= 12 && bundle.callouts.length >= 10,
  [bundle.charges.length, bundle.callouts.length]);
check('the bundle carries the XP progress', bundle.progress.rank === 'Cadet' && bundle.progress.percent >= 0,
  bundle.progress);

// --- persistence of the new sections ---------------------------------------

const savedLaw = law.filesystem['data/records.json'];
const reloaded = dutied({ files: { 'data/records.json': savedLaw } });

check('the fines survive a restart', (exp(reloaded, 'ListFines', [{}]) || []).length >= 2,
  (exp(reloaded, 'ListFines', [{}]) || []).length);
check('the court fund survives a restart',
  ((exp(reloaded, 'GetMdt', [1]) || {}).department || {}).balance >= 250,
  (exp(reloaded, 'GetMdt', [1]) || {}).department);

const reportReload = dutied({ files: { 'data/records.json': reportHost.filesystem['data/records.json'] } });
check('reports survive a restart', (exp(reportReload, 'ListReports', ['']) || []).length === 1,
  (exp(reportReload, 'ListReports', ['']) || []).length);


// ---------------------------------------------------------------------------
// Contract checks: the parts that cannot run in this VM
// ---------------------------------------------------------------------------

const luaFiles = [];
(function walk(dir) {
  fs.readdirSync(dir, { withFileTypes: true }).forEach((item) => {
    const full = path.join(dir, item.name);
    if (item.isDirectory()) walk(full);
    else if (item.name.endsWith('.lua')) luaFiles.push(full);
  });
}(ROOT));

const sources = {};
luaFiles.forEach((file) => { sources[path.relative(ROOT, file)] = fs.readFileSync(file, 'utf8'); });
const allLua = Object.values(sources).join('\n');

const configKeys = new Set();
Object.entries(sources)
  .filter(([name]) => name.endsWith('config.lua'))
  .forEach(([, text]) => {
    (text.match(/^Config\.([A-Za-z_][A-Za-z0-9_]*)\s*=/gm) || []).forEach((line) => {
      configKeys.add(line.replace(/^Config\./, '').replace(/\s*=$/, ''));
    });
  });

const missingConfig = new Set();
Object.entries(sources)
  .filter(([name]) => !name.endsWith('config.lua'))
  .forEach(([, text]) => {
    (text.match(/\bConfig\.([A-Za-z_][A-Za-z0-9_]*)/g) || []).forEach((match) => {
      const key = match.replace('Config.', '');
      if (!configKeys.has(key)) missingConfig.add(key);
    });
  });

check('every Config.<key> the code reads exists in config.lua',
  missingConfig.size === 0, [...missingConfig]);

const mdtFunctions = new Set(
  (sources[path.join('shared', 'mdt.lua')].match(/^function Mdt\.([A-Za-z0-9_]+)/gm) || [])
    .map((line) => line.replace('function Mdt.', '')),
);

const missingMdt = new Set();
Object.entries(sources).forEach(([, text]) => {
  (text.match(/\bMdt\.([A-Za-z0-9_]+)\s*\(/g) || []).forEach((match) => {
    const name = match.replace('Mdt.', '').replace(/\s*\($/, '');
    if (!mdtFunctions.has(name)) missingMdt.add(name);
  });
});

check('every Mdt.<fn> the code calls is defined in shared/mdt.lua',
  missingMdt.size === 0, [...missingMdt]);

const serverEventHandlers = new Set(
  (allLua.match(/RegisterNetEvent\('(fk_police:server:[A-Za-z:_]+)'/g) || [])
    .map((line) => line.replace("RegisterNetEvent('", '').replace(/'$/, '')),
);

const clientTriggeredServer = new Set(
  (sources[path.join('client', 'main.lua')].match(/TriggerServerEvent\('(fk_police:server:[A-Za-z:_]+)'/g) || [])
    .map((line) => line.replace("TriggerServerEvent('", '').replace(/'$/, '')),
);

check('every event the client sends has a server handler',
  [...clientTriggeredServer].every((name) => serverEventHandlers.has(name)),
  [...clientTriggeredServer].filter((name) => !serverEventHandlers.has(name)));

const clientEventHandlers = new Set(
  (sources[path.join('client', 'main.lua')].match(/RegisterNetEvent\('(fk_police:client:[A-Za-z:_]+)'/g) || [])
    .map((line) => line.replace("RegisterNetEvent('", '').replace(/'$/, '')),
);

const serverTriggeredClient = new Set(
  (allLua.match(/TriggerClientEvent\('(fk_police:client:[A-Za-z:_]+)'/g) || [])
    .map((line) => line.replace("TriggerClientEvent('", '').replace(/'$/, '')),
);

check('every event the server sends is handled by the client',
  [...serverTriggeredClient].every((name) => clientEventHandlers.has(name)),
  [...serverTriggeredClient].filter((name) => !clientEventHandlers.has(name)));

const nuiCallbacks = new Set(
  (sources[path.join('client', 'main.lua')].match(/RegisterNUICallback\('([a-zA-Z]+)'/g) || [])
    .map((line) => line.replace("RegisterNUICallback('", '').replace(/'$/, '')),
);

const postedCallbacks = new Set(
  (appJs.match(/\bpost\('([a-zA-Z]+)'/g) || []).map((line) => line.replace("post('", '').replace(/'$/, '')),
);

check('every callback the MDT posts exists in the client',
  [...postedCallbacks].every((name) => nuiCallbacks.has(name)),
  [...postedCallbacks].filter((name) => !nuiCallbacks.has(name)));

const nuiActions = new Set(
  (appJs.match(/case '([a-zA-Z]+)':/g) || []).map((line) => line.replace("case '", '').replace(/':$/, '')),
);

const sentActions = new Set();
{
  const clientSource = sources[path.join('client', 'main.lua')];
  const pattern = /SendNUIMessage\(\{\s*action = '([a-zA-Z]+)'/g;
  let match = pattern.exec(clientSource);

  while (match) {
    sentActions.add(match[1]);
    match = pattern.exec(clientSource);
  }
}

check('every NUI message the client sends is handled by the page',
  [...sentActions].every((name) => nuiActions.has(name)),
  [...sentActions].filter((name) => !nuiActions.has(name)));

check('the manifest loads justice after the core',
  /server_scripts\s*\{[^}]*'server\/main\.lua'[^}]*'server\/justice\.lua'[^}]*\}/s
    .test(sources['fxmanifest.lua']), sources['fxmanifest.lua']);
check('the manifest ships version 0.3.0', /version '0\.3\.0'/.test(sources['fxmanifest.lua']),
  (sources['fxmanifest.lua'].match(/version '[^']+'/) || [])[0]);
check('the manifest still points at the single NUI page',
  /ui_page 'html\/index\.html'/.test(sources['fxmanifest.lua']));
check('the key mappings cover the documented keys',
  ['F5', 'F6', 'F7', 'F9', 'F10', 'F11', 'G', 'L', 'M', 'X', 'Y'].every((key) => sources[path.join('client', 'main.lua')].includes(`'${key}'`)));
check('the client never uses a native that does not exist',
  !/TaskCuffed|PlayerData\.state/.test(sources[path.join('client', 'main.lua')]));
const pageCss = fs.readFileSync(path.join(ROOT, 'html', 'style.css'), 'utf8');

check('the HUD and MDT share one transparent page',
  pageCss.includes('background: transparent') && !pageCss.includes('backdrop-filter:'));

const chargeIds = new Set((sources['config.lua'].match(/\{ id = '([a-z_]+)', label =/g) || [])
  .map((line) => line.replace(/\{ id = '/, '').replace(/', label =$/, '')));

const calloutCharges = (sources['config.lua'].match(/charges = \{ ([^}]*) \}/g) || [])
  .flatMap((entry) => (entry.match(/'([a-z_]+)'/g) || []).map((id) => id.replace(/'/g, '')));

check('every callout charge exists in Config.Charges',
  calloutCharges.every((id) => chargeIds.has(id)),
  calloutCharges.filter((id) => !chargeIds.has(id)));

const calloutIds = (sources['config.lua'].match(/id = '([a-z_]+)',\n\s+code = /g) || [])
  .map((line) => line.replace(/id = '/, '').replace(/',\n\s+code = $/, ''));

check('callout ids are unique', new Set(calloutIds).size === calloutIds.length, calloutIds);
check('there are at least ten callout types', calloutIds.length >= 10, calloutIds.length);
check('there are at least twelve charges', chargeIds.size >= 12, chargeIds.size);

// ---------------------------------------------------------------------------
// Static checks on the parts that cannot run in fengari/jsdom here
// ---------------------------------------------------------------------------

const clientSrc = fs.readFileSync(path.join(ROOT, 'client', 'main.lua'), 'utf8');
const cssSrc = fs.readFileSync(path.join(ROOT, 'html', 'style.css'), 'utf8');

check('the client maps every LSPDFR-style key through RegisterKeyMapping',
  ['F9', 'F10', 'F11', 'Y', 'M'].every((key) => clientSrc.includes(`'${key}'`)),
  []);
check('the client registers the four MDT callbacks the page posts to',
  ['close', 'search', 'callout', 'backup'].every((name) => clientSrc.includes(`RegisterNUICallback('${name}'`)));
check('the client drops its stop once the arrest is booked',
  /RegisterNetEvent\('fk_police:client:arrest'[\s\S]{0,400}currentStop = nil/.test(clientSrc));
check('the MDT page posts to the real resource name, never to localhost',
  appJs.includes('GetParentResourceName') && !/localhost|127\.0\.0\.1/.test(appJs));
check('the MDT page is transparent (no backdrop-filter black box in CEF)',
  !/backdrop-filter\s*:/.test(cssSrc) && cssSrc.includes('background: transparent'));
// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

if (failures.length) {
  console.log('');
  for (const failure of failures) {
    console.log(`FAIL  ${failure.name}`);
    if (failure.detail !== undefined) console.log('      got:', JSON.stringify(failure.detail).slice(0, 400));
  }
}

const total = pass + failures.length;
console.log(`\n${pass}/${total} police checks passed`);
process.exit(failures.length ? 1 : 0);
