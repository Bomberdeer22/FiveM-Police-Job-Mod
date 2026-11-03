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
const FILES = ['config.lua', 'shared/core.lua', 'shared/mdt.lua', 'server/main.lua'];

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

function fkTick(ms) fkTimer = fkTimer + (ms or 0) end
os.time = function() return fkClock end
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
    && /\$1200/.test(doc.getElementById('charges-body').textContent));

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
