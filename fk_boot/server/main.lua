--[[
    fk_boot — server/main.lua
    ---------------------------------------------------------------------------
    Starts the heavy resources listed in Config.Deferred.packs once the server
    has finished its own boot sequence, so txAdmin's Resource Starting Tolerance
    only ever sees the small resources.

    Nothing here touches gameplay, money or another resource's files: it calls
    StartResource and reports the result on the server console.
]]

local RESOURCE = GetCurrentResourceName()

local function log(...)
    print(('^2[%s]^0 %s'):format(RESOURCE, table.concat({ ... }, ' ')))
end

local function warn(...)
    print(('^3[%s]^0 %s'):format(RESOURCE, table.concat({ ... }, ' ')))
end

local function deferred()
    return (Config and Config.Deferred) or {}
end

local function packs()
    local list = deferred().packs

    return type(list) == 'table' and list or {}
end

local function packsForGate()
    if deferred().enabled == false then return {} end

    return packs()
end

-- ---------------------------------------------------------------------------
-- Join gate
-- ---------------------------------------------------------------------------
-- A client that connects while a multi-hundred-megabyte pack is being started
-- can hang on the loading screen at 100%: it is downloading files from a
-- resource that is still being set up. Holding the connection with a deferral
-- (with a message on the loading screen) until the packs are up avoids that.

local bootDone = false     -- every deferred pack has been handed off
local currentPack          -- name of the pack being started, for the message
local gateWaiters = {}     -- [source] = { deferrals, at }

local function gateEnabled()
    return deferred().gateJoins ~= false and #packsForGate() > 0
end


--- Is this resource up (or on its way up)?
--- @return boolean
local function isRunning(name)
    local state = GetResourceState(name)

    return state == 'started' or state == 'starting' or state == 'starting_update'
end

--- Start one pack.
--- @return string state 'started' | 'skipped' | 'missing' | 'failed'
local function startPack(name, skipIfStarted)
    if skipIfStarted == nil then
        skipIfStarted = deferred().skipIfStarted ~= false
    end

    if type(name) ~= 'string' or name == '' then
        warn('skipping an empty entry in Config.Deferred.packs')
        return 'failed'
    end

    local state = GetResourceState(name)

    if state == 'missing' then
        warn(('"%s" is not installed on this server - check the folder name.'):format(name))
        return 'missing'
    end

    if skipIfStarted and isRunning(name) then
        if deferred().verbose ~= false then
            log(('left "%s" alone - it is already %s.'):format(name, tostring(state)))
        end

        return 'skipped'
    end

    currentPack = name
    local ok = StartResource(name)
    currentPack = nil

    if ok then
        log(('started "%s" after boot.'):format(name))
        return 'started'
    end

    warn(('the server refused to start "%s" - see the console above for why.'):format(name))
    return 'failed'
end

--- Start one pack, a gap apart from the next, without yielding.
local function startAll(spaced)
    local results = {}
    local configured = packs()
    local gap = math.min(math.max(math.floor(tonumber(deferred().gap) or 2000), 0), 60000)

    for index, name in ipairs(configured) do
        local state = startPack(name)

        results[name] = state

        if spaced and index < #configured and gap > 0 then
            Wait(gap)
        end
    end

    return results
end

exports('GetDeferredPacks', function()
    local list = {}

    for _, name in ipairs(packs()) do list[#list + 1] = name end

    return list
end)

--- Start everything now, from another resource. Does not wait between packs.
--- @return table results [name] = 'started' | 'skipped' | 'missing' | 'failed'
exports('StartDeferredNow', function()
    return startAll(false)
end)

--- @return table state [name] = resource state string
exports('GetDeferredState', function()
    local out = {}

    for _, name in ipairs(packs()) do out[name] = GetResourceState(name) end

    return out
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function say(source, line)
    local src = tonumber(source)

    if src and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { 'fk_boot', line } })
    else
        log(line)
    end
end

--- /boot_list — read only, so anyone may run it.
RegisterCommand('boot_list', function(source)
    local configured = packs()

    if #configured == 0 then
        return say(source, 'nothing is deferred (Config.Deferred.packs is empty).')
    end

    for _, name in ipairs(configured) do
        say(source, ('%s: %s'):format(name, tostring(GetResourceState(name))))
    end
end, false)

--- boot_start <resource> — server console (or an ACE-authorized admin).
RegisterCommand('boot_start', function(source, args)
    local name = type(args) == 'table' and args[1] or nil

    if not name then
        return say(source, 'Usage: boot_start <resource>')
    end

    say(source, ('%s -> %s'):format(name, startPack(name, false)))
end, true)

-- ---------------------------------------------------------------------------
-- Join gate
-- ---------------------------------------------------------------------------

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    if bootDone or not gateEnabled() or not deferrals then return end

    local source = source

    -- The deferral must be created inside this event, and it can be updated and
    -- finished later from a thread (that is the documented pattern).
    deferrals.defer()
    Wait(0)

    gateWaiters[source] = { deferrals = deferrals, at = os.time() }

    deferrals.update(('fk_boot: starting %s, one moment...')
        :format(currentPack or table.concat(packsForGate(), ', ')))

    if deferred().verbose ~= false then
        log(('%s is connecting while the packs are still starting - holding the connection.')
            :format(tostring(name)))
    end
end)

CreateThread(function()
    local timeout = math.max(10, math.floor(tonumber(deferred().gateTimeout) or 300))

    while not bootDone do
        Wait(1000)

        if bootDone then break end

        local now = os.time()

        for source, waiter in pairs(gateWaiters) do
            local waited = now - waiter.at

            if waited > timeout then
                waiter.deferrals.done(('fk_boot could not start %s in time - try again in a minute.')
                    :format(currentPack or 'the pack'))
                gateWaiters[source] = nil
                warn(('gave up holding player %s after %ds.'):format(tostring(source), waited))
            else
                waiter.deferrals.update(('fk_boot: starting %s (%ds)...')
                    :format(currentPack or 'a pack', waited))
            end
        end
    end

    -- Let everyone who was held in.
    local held = 0

    for source, waiter in pairs(gateWaiters) do
        waiter.deferrals.done()
        gateWaiters[source] = nil
        held = held + 1
    end

    if held > 0 and deferred().verbose ~= false then
        log(('join gate open - let %d waiting player(s) in.'):format(held))
    end
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

if deferred().enabled == false then
    bootDone = true
    log('deferred start is disabled in Config.Deferred.enabled - nothing to do.')
elseif #packs() == 0 then
    bootDone = true
    CreateThread(function()
        Wait(200)

        log(('ready (v%s). No packs deferred - add them to Config.Deferred.packs.')
            :format(GetResourceMetadata(RESOURCE, 'version', 0) or '?'))
    end)
else
    CreateThread(function()
        Wait(200)

        log(('ready (v%s). Waiting %d ms, then starting %d pack(s): %s')
            :format(
                GetResourceMetadata(RESOURCE, 'version', 0) or '?',
                math.floor(tonumber(deferred().delay) or 10000),
                #packs(),
                table.concat(packs(), ', ')))
    end)

    CreateThread(function()
        Wait(math.max(math.floor(tonumber(deferred().delay) or 10000), 0))

        startAll(true)

        bootDone = true

        log('done - the server is fully booted and every deferred pack has been handed off.')
    end)
end
