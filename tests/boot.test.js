/* Loads fk_boot inside fengari with mocked natives and coroutine threads, then
   checks that heavy packs are started after boot, skipped when they are already
   up, and reported on the console.
   Run with: npm test */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const ROOT = path.join(__dirname, '..', 'fk_boot');
const FILES = ['config.lua', 'server/main.lua'];

let pass = 0;
const failures = [];

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
    return;
  }
  failures.push({ name, detail });
}

// Threads have to be real coroutines: the boot code waits more than once, and a
// thread that restarted from the top on every resume would start every pack
// twice. Everything lives in Lua so `Wait` can yield.
const PRELUDE = `
fkThreads = {}
fkHandlers = {}
fkDeferrals = {}
fkClock = 1700000000

-- A fake clock, so the join gate's timeout can be tested without waiting.
os.time = function() return fkClock end
function fkTick(seconds) fkClock = fkClock + (seconds or 1) end

function CreateThread(fn)
    fkThreads[#fkThreads + 1] = coroutine.create(fn)
end

function Wait(ms)
    coroutine.yield(ms or 0)
end

function AddEventHandler(name, fn)
    fkHandlers[name] = fn
end

--- Fire a server event that FiveM would run in its own thread, with \`source\`.
function fkFireAs(src, name, ...)
    local fn = fkHandlers[name]

    if not fn then return false end

    local args = table.pack(...)
    local co = coroutine.create(function()
        source = src
        fn(table.unpack(args, 1, args.n))
    end)

    fkThreads[#fkThreads + 1] = co

    local ok, err = coroutine.resume(co)

    if not ok then error(err) end

    return true
end

--- A stand-in for FiveM's deferrals object.
function fkNewDeferrals()
    local d = {}
    d.calls = {}

    function d.defer()
        d.calls[#d.calls + 1] = { 'defer' }
    end

    function d.update(message)
        d.calls[#d.calls + 1] = { 'update', tostring(message) }
    end

    function d.done(message)
        d.calls[#d.calls + 1] = { 'done', message ~= nil and tostring(message) or nil }
    end

    function d.presentCard()
        d.calls[#d.calls + 1] = { 'card' }
    end

    fkDeferrals[#fkDeferrals + 1] = d

    return d, #fkDeferrals
end

function fkStep()
    local out = {}

    for _, co in ipairs(fkThreads) do
        if coroutine.status(co) ~= 'dead' then
            local ok, res = coroutine.resume(co)

            if not ok then
                out[#out + 1] = 'error: ' .. tostring(res)
            elseif res ~= nil then
                out[#out + 1] = res
            end
        end
    end

    return out
end
`;

function createHarness(options = {}) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const logs = [];
  const started = [];
  const stopped = [];
  const clientEvents = [];
  const commands = {};
  const exportsMap = {};
  const states = Object.assign({}, options.states || {});
  const failStarts = new Set(options.failStarts || []);

  // Every C function is called with the *thread* that is running, which is not
  // the main state once CreateThread hands work to a coroutine. All of these
  // helpers therefore take the state they must operate on.
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

  function pushJs(value, S = L) {
    if (value === null || value === undefined) {
      lua.lua_pushnil(S);
    } else if (typeof value === 'boolean') {
      lua.lua_pushboolean(S, value);
    } else if (typeof value === 'number') {
      lua.lua_pushnumber(S, value);
    } else if (typeof value === 'string') {
      lua.lua_pushstring(S, to_luastring(value));
    } else if (Array.isArray(value)) {
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
    const results = [];
    for (let index = base + 1; index <= top; index += 1) results.push(luaToJs(index, L));
    lua.lua_settop(L, base);
    return results;
  }

  function setGlobal(name, fn) {
    lua.lua_pushcfunction(L, (S) => fn(S || L));
    lua.lua_setglobal(L, to_luastring(name));
  }

  function luaDo(source, chunkName = '@test-chunk') {
    const base = lua.lua_gettop(L);
    const buffer = Buffer.from(source, 'utf8');
    const status = lauxlib.luaL_loadbuffer(L, buffer, buffer.length, to_luastring(chunkName));
    if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    const ran = lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0);
    if (ran !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    const top = lua.lua_gettop(L);
    const value = top > base ? luaToJs(top, L) : null;
    lua.lua_settop(L, base);
    return value;
  }

  // -------------------------------------------------------------------------
  // natives
  // -------------------------------------------------------------------------

  setGlobal('GetCurrentResourceName', (S) => {
    lua.lua_pushstring(S, to_luastring('fk_boot'));
    return 1;
  });

  setGlobal('GetResourceMetadata', (S) => {
    lua.lua_pushstring(S, to_luastring('0.1.0'));
    return 1;
  });

  setGlobal('GetResourceState', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    lua.lua_pushstring(S, to_luastring(states[name] || 'stopped'));
    return 1;
  });

  setGlobal('StartResource', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    started.push(name);

    if (failStarts.has(name)) {
      lua.lua_pushboolean(S, false);
      return 1;
    }

    states[name] = 'started';
    lua.lua_pushboolean(S, true);
    return 1;
  });

  setGlobal('StopResource', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    stopped.push(name);
    states[name] = 'stopped';
    lua.lua_pushboolean(S, true);
    return 1;
  });

  setGlobal('print', (S) => {
    const parts = [];
    const top = lua.lua_gettop(S);
    for (let i = 1; i <= top; i += 1) parts.push(String(luaToJs(i, S)));
    logs.push(parts.join(' ').replace(/\^\d/g, ''));
    return 0;
  });

  setGlobal('TriggerClientEvent', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    const target = lua.lua_tonumber(S, 2);
    clientEvents.push({ name, target, args: luaToJs(3, S) });
    return 0;
  });

  setGlobal('exports', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    lua.lua_pushvalue(S, -1);
    exportsMap[name] = lauxlib.luaL_ref(S, lua.LUA_REGISTRYINDEX);
    return 0;
  });

  setGlobal('RegisterCommand', (S) => {
    const name = to_jsstring(lua.lua_tostring(S, 1));
    const restricted = lua.lua_toboolean(S, 3);
    lua.lua_pushvalue(S, 2);
    commands[name] = { ref: lauxlib.luaL_ref(S, lua.LUA_REGISTRYINDEX), restricted };
    return 0;
  });

  // -------------------------------------------------------------------------
  // load the resource
  // -------------------------------------------------------------------------

  luaDo(PRELUDE, '@harness-prelude');

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

    // Between config.lua and server/main.lua, so a test can change the config
    // before the boot threads are created.
    if (file === 'config.lua') {
      if (options.packs) {
        const list = options.packs.map((name) => JSON.stringify(name)).join(', ');
        luaDo(`Config.Deferred.packs = { ${list} }`, '@test-packs');
      }
      if (options.delay !== undefined) {
        luaDo(`Config.Deferred.delay = ${Number(options.delay)}`, '@test-delay');
      }
      if (options.enabled === false) {
        luaDo('Config.Deferred.enabled = false', '@test-enabled');
      }
      if (options.gateJoins === false) {
        luaDo('Config.Deferred.gateJoins = false', '@test-gate');
      }
      if (options.gateTimeout !== undefined) {
        luaDo(`Config.Deferred.gateTimeout = ${Number(options.gateTimeout)}`, '@test-gate-timeout');
      }
      if (options.gap !== undefined) {
        luaDo(`Config.Deferred.gap = ${Number(options.gap)}`, '@test-gap');
      }
    }
  });

  return {
    logs,
    started,
    stopped,
    clientEvents,
    commands,
    exports: exportsMap,
    luaDo,
    callExport(name, args = []) {
      if (exportsMap[name] === undefined) throw new Error(`no export "${name}"`);
      return callRef(exportsMap[name], args);
    },
    runCommand(name, source, args = []) {
      if (!commands[name]) throw new Error(`no command "${name}"`);
      return callRef(commands[name].ref, [source, args]);
    },
    /** Resume every live thread once (i.e. let one Wait elapse). */
    step() {
      return luaDo('return fkStep()', '@test-step');
    },
    config() {
      return luaDo('return Config.Deferred', '@test-config');
    },
    /** Create a deferrals stand-in; returns its 1-based index. */
    newDeferrals() {
      return luaDo('local _, index = fkNewDeferrals(); return index', '@test-deferrals');
    },
    deferralCalls(index) {
      const value = luaDo(`return fkDeferrals[${index}].calls`, '@test-deferral-calls') || {};
      if (Array.isArray(value)) return value;
      return Object.keys(value)
        .filter((key) => /^\d+$/.test(key))
        .sort((a, b) => Number(a) - Number(b))
        .map((key) => value[key]);
    },
    tick(seconds) {
      return luaDo(`fkTick(${Number(seconds)})`, '@test-tick');
    },
  };
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const defaults = createHarness();
const config = defaults.config();

check('the config ships with deferred start enabled', config.enabled === true, config);
check('the pack list is a table by default', config.packs !== null && typeof config.packs === 'object', config.packs);
check('the delay is in milliseconds and generous', config.delay === 10000, config.delay);
check('packs are spaced out', config.gap === 2000, config.gap);
check('already-running packs are left alone by default', config.skipIfStarted === true);
check('joins are gated while packs start', config.gateJoins === true);
check('the gate has a timeout', config.gateTimeout === 300);
check('an empty config creates no packs to start',
  (() => {
    const list = defaults.callExport('GetDeferredPacks')[0] || {};
    return Object.keys(list).length === 0;
  })(), defaults.callExport('GetDeferredPacks'));
defaults.step();
defaults.step();
check('an empty config says so on the console',
  defaults.logs.some((line) => /No packs deferred/.test(line)), defaults.logs);

// ---------------------------------------------------------------------------
// The boot thread
// ---------------------------------------------------------------------------

const boot = createHarness({ packs: ['military', 'packB'] });

check('nothing is started while the delay is running',
  (boot.step(), boot.started.length === 0), [...boot.started]);

boot.step();
check('the banner names the pack and the delay',
  boot.logs.some((line) => /Waiting 10000 ms, then starting 2 pack\(s\): military, packB/.test(line)),
  [...boot.logs]);
check('the first pack starts once the delay has elapsed',
  JSON.stringify(boot.started) === JSON.stringify(['military']), [...boot.started]);

boot.step();
check('the second pack follows, in order',
  JSON.stringify(boot.started) === JSON.stringify(['military', 'packB']), [...boot.started]);
check('each start is logged', boot.logs.some((line) => /started "military" after boot/.test(line)), [...boot.logs]);

boot.step();
check('the boot thread finishes and says so',
  boot.logs.some((line) => /every deferred pack has been handed off/.test(line)), [...boot.logs]);
check('nothing is started twice', boot.started.length === 2, [...boot.started]);

// ---------------------------------------------------------------------------
// Packs that are already up, missing, or broken
// ---------------------------------------------------------------------------

const already = createHarness({ packs: ['military'], states: { military: 'started' } });
already.step();
already.step();
already.step();
check('a pack that is already running is not started again', already.started.length === 0, already.started);
check('and the console explains why',
  already.logs.some((line) => /left "military" alone - it is already started/.test(line)), already.logs);

const starting = createHarness({ packs: ['military'], states: { military: 'starting' } });
starting.step();
starting.step();
starting.step();
check('a pack that is still starting is not touched', starting.started.length === 0, starting.started);

const missing = createHarness({ packs: ['miltary'], states: { miltary: 'missing' } });
missing.step();
missing.step();
missing.step();
check('a typo in the pack name does not try to start it', missing.started.length === 0, missing.started);
check('and the warning names the resource',
  missing.logs.some((line) => /"miltary" is not installed/.test(line)), missing.logs);

const broken = createHarness({ packs: ['military', 'packB'], failStarts: ['military'] });
broken.step();
broken.step();
broken.step();
broken.step();
check('a refused start is reported', broken.logs.some((line) => /refused to start "military"/.test(line)), broken.logs);
check('and the next pack is still attempted',
  JSON.stringify(broken.started) === JSON.stringify(['military', 'packB']), broken.started);

// ---------------------------------------------------------------------------
// Exports and commands
// ---------------------------------------------------------------------------

const manual = createHarness({ packs: ['military', 'packB'] });
const [manualPacks] = manual.callExport('GetDeferredPacks');
check('GetDeferredPacks lists the config', JSON.stringify(manualPacks) === JSON.stringify(['military', 'packB']), manualPacks);

const results = manual.callExport('StartDeferredNow')[0];
check('StartDeferredNow starts them all without waiting',
  JSON.stringify(manual.started) === JSON.stringify(['military', 'packB']), manual.started);
check('and returns what happened to each',
  results && results.military === 'started' && results.packB === 'started', results);

const [stateMap] = manual.callExport('GetDeferredState');
check('GetDeferredState reports the resource state',
  stateMap && stateMap.military === 'started' && stateMap.packB === 'started', stateMap);

const commands = createHarness({ packs: ['military'] });
check('boot_list is available to everyone', commands.commands.boot_list.restricted === false);
commands.runCommand('boot_list', 0, []);
check('boot_list prints each pack and its state',
  commands.logs.some((line) => /military: stopped/.test(line)), commands.logs);

check('boot_start is console/ACE only', commands.commands.boot_start.restricted === true);
commands.runCommand('boot_start', 0, ['packB']);
check('boot_start starts the named resource',
  JSON.stringify(commands.started) === JSON.stringify(['packB']), commands.started);
commands.runCommand('boot_start', 0, []);
check('boot_start without a name prints the usage',
  commands.logs.some((line) => /Usage: boot_start <resource>/.test(line)), commands.logs);

commands.runCommand('boot_list', 1, []);
check('boot_list answers an admin in chat',
  commands.clientEvents.some((event) => event.target === 1 && /military: stopped/.test(event.args.args[1])),
  commands.clientEvents);

// ---------------------------------------------------------------------------
// The join gate: nobody connects halfway through a pack download
// ---------------------------------------------------------------------------

function connect(harness, source, name) {
  const index = harness.newDeferrals();
  harness.luaDo(
    `return fkFireAs(${source}, 'playerConnecting', ${JSON.stringify(name)}, nil, fkDeferrals[${index}])`,
    '@test-connect');
  return index;
}

const gate = createHarness({ packs: ['military'] });
gate.step();

const held = connect(gate, 7, 'Bob');
const heldCalls = gate.deferralCalls(held) || [];
check('a connection while the pack is starting is held', heldCalls.some((call) => call[0] === 'defer'), heldCalls);
check('and is not let in yet', !heldCalls.some((call) => call[0] === 'done'), heldCalls);

gate.step();
const heldUpdate = (gate.deferralCalls(held) || []).filter((call) => call[0] === 'update');
check('the loading screen says which pack it is waiting for',
  heldUpdate.some((call) => /fk_boot: starting military/.test(call[1] || '')), heldUpdate);
check('the console notes the held connection',
  gate.logs.some((line) => /Bob is connecting while the packs are still starting/.test(line)), gate.logs);

for (let i = 0; i < 6; i += 1) gate.step();

const doneCalls = (gate.deferralCalls(held) || []).filter((call) => call[0] === 'done');
check('the player is let in once the pack is up', doneCalls.length === 1 && doneCalls[0].length === 1, doneCalls);
check('the console says the gate opened',
  gate.logs.some((line) => /join gate open - let 1 waiting player\(s\) in/.test(line)), gate.logs);

const late = connect(gate, 8, 'Late');
check('a connection after boot is not held',
  !(gate.deferralCalls(late) || []).some((call) => call[0] === 'defer'),
  gate.deferralCalls(late));

// A gate that would hang for ever must give the player an explanation instead.
const stuck = createHarness({ packs: ['military', 'packB', 'packC'], gateTimeout: 10 });
stuck.step();
const waiting = connect(stuck, 9, 'Patient');
stuck.step();
stuck.tick(400);
stuck.step();
const stuckCalls = (stuck.deferralCalls(waiting) || []).filter((call) => call[0] === 'done');
check('a pack that never finishes does not lock everyone out',
  stuckCalls.length === 1 && /could not start .* in time/.test(stuckCalls[0][1] || ''), stuckCalls);

// Opt out.
const open = createHarness({ packs: ['military'], gateJoins: false });
open.step();
const direct = connect(open, 10, 'Direct');
check('gateJoins = false lets everyone straight in',
  !(open.deferralCalls(direct) || []).some((call) => call[0] === 'defer'),
  open.deferralCalls(direct));

// Nothing deferred: nothing to wait for.
const nothing = createHarness();
nothing.step();
const plain = connect(nothing, 11, 'Plain');
check('with no packs configured nobody is held',
  !(nothing.deferralCalls(plain) || []).some((call) => call[0] === 'defer'),
  nothing.deferralCalls(plain));

// ---------------------------------------------------------------------------
// Switched off
// ---------------------------------------------------------------------------

const off = createHarness({ packs: ['military'], enabled: false });
off.step();
off.step();
off.step();
check('enabled = false starts nothing at all', off.started.length === 0, off.started);
check('and says so once',
  off.logs.some((line) => /deferred start is disabled/.test(line)), off.logs);

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log(`${pass}/${pass} boot checks passed`);
  process.exit(0);
}

failures.forEach((failure) => {
  console.log(`FAIL  ${failure.name}`);
  if (failure.detail !== undefined) console.log('      got:', JSON.stringify(failure.detail));
});
console.log(`\n${pass}/${pass + failures.length} boot checks passed`);
process.exit(1);
