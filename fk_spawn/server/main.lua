--[[
    fk_spawn — server/main.lua
    ---------------------------------------------------------------------------
    Owns the spawn point list: config defaults, in-game overrides (saved to
    data/spawns.json), the staff check for /spawnset and the console commands.
]]

local RESOURCE = GetCurrentResourceName()
local FILE = Config.Persistence.file or 'data/spawns.json'

local overrides = {}      -- [name] = { x, y, z, w, label, updatedBy, updatedAt }
local saveQueued = false
local pendingSpawn = {}   -- [source] = true while a freshly joined player still owes a spawn
local joins = {}          -- [source] = { name, connectedAt, joiningAt, helloAt, spawnedAt, warnedAt }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(...)
    print('^2[fk_spawn]^0 ' .. table.concat({ ... }, ' '))
end

local function warn(...)
    print('^3[fk_spawn]^0 ' .. table.concat({ ... }, ' '))
end

local function errorf(...)
    print('^1[fk_spawn]^0 ' .. table.concat({ ... }, ' '))
end

local function isoNow()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function reply(target, message)
    if target == 0 then
        log(message)
    else
        TriggerClientEvent('fk_spawn:client:notify', target, message)
    end
end

--- The join timeline. Everything here is console/chat output: a client stuck on
--- the loading screen cannot open its F8 console, so the server has to say what
--- is (not) happening.
--- @return table entry
local function joinEntry(source, name)
    joins[source] = joins[source] or { connectedAt = os.time() }

    if name then joins[source].name = name end

    return joins[source]
end

-- ---------------------------------------------------------------------------
-- Rate limits (shared/core.lua token buckets)
-- ---------------------------------------------------------------------------

local limits = {
    requestSpawns  = RateLimit.new(Config.RateLimit.requestSpawns),
    requestSpawn   = RateLimit.new(Config.RateLimit.requestSpawn),
    setSpawn       = RateLimit.new(Config.RateLimit.setSpawn),
    resetSpawn     = RateLimit.new(Config.RateLimit.resetSpawn),
    isSpawnPending = RateLimit.new(Config.RateLimit.isSpawnPending),
}

--- @return boolean allowed
local function allow(name, source)
    local limiter = limits[name]

    if not limiter then return true end

    return limiter:allow(source)
end

--- Blocked-request counters, shown by /spawnstatus.
--- @return table
function SpawnRateLimitStats()
    local out = {}

    for name, limiter in pairs(limits) do
        out[name] = limiter.blocked or 0
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function loadOverrides()
    overrides = {}

    local data, source = Persist.decode(FILE)

    if not data then
        if Persist.read(FILE) then
            errorf(('Could not read %s (invalid JSON), using config.lua values.'):format(FILE))
        elseif Config.Debug then
            log('No saved spawn points yet, using config.lua.')
        end
        return
    end

    if source and source ~= FILE then
        warn(('%s was unreadable — restored %s instead.'):format(FILE, source))
    end

    for name, entry in pairs(data.spawns or {}) do
        local point = Spawn.normalize({
            name = name,
            label = entry.label,
            interior = entry.interior,
            coords = entry,
        })

        if point then
            overrides[point.name] = {
                x = point.x,
                y = point.y,
                z = point.z,
                w = point.w,
                label = point.label,
                updatedBy = entry.updatedBy,
                updatedAt = entry.updatedAt,
            }
        else
            warn(('Skipped saved spawn point %s from %s.'):format(tostring(name), FILE))
        end
    end
end

local function writeOverrides()
    local payload = {
        version = 1,
        savedAt = isoNow(),
        spawns = overrides,
    }

    local ok, encoded = pcall(json.encode, payload, { indent = true })

    if not ok or not encoded then
        errorf('Could not encode spawn points, nothing saved.')
        return false
    end

    return Persist.write(FILE, encoded)
end

local function queueSave()
    if saveQueued then return end
    saveQueued = true

    SetTimeout(Config.Persistence.saveDelay or 2000, function()
        saveQueued = false
        writeOverrides()
    end)
end

-- ---------------------------------------------------------------------------
-- Spawn point list
-- ---------------------------------------------------------------------------

--- Config points, with saved overrides applied on top.
--- @return table array of normalized points
function GetSpawnPoints()
    local points = Spawn.normalizeList(Config.Spawns)
    local seen = {}

    for _, point in ipairs(points) do
        local saved = overrides[point.name]

        if saved then
            point.x, point.y, point.z, point.w = saved.x, saved.y, saved.z, saved.w
        end

        seen[point.name] = true
    end

    -- Points added from the console with a name that is not in config.lua.
    for name, saved in pairs(overrides) do
        if not seen[name] then
            points[#points + 1] = {
                name = name,
                label = saved.label or name,
                x = saved.x,
                y = saved.y,
                z = saved.z,
                w = saved.w or 0.0,
                enabled = true,
            }
        end
    end

    table.sort(points, function(a, b) return a.name < b.name end)

    return points
end

--- @return table|nil
function GetSpawnPoint(name)
    return Spawn.resolve(GetSpawnPoints(), name or Config.DefaultSpawn)
end

--- The point used for the first spawn and for /spawn with no argument.
--- @return string
function GetDefaultSpawnName()
    local points = GetSpawnPoints()
    local wanted = Spawn.sanitizeName(Config.DefaultSpawn or '')

    if wanted then
        local point = Spawn.resolve(points, wanted)
        if point then return point.name end
    end

    local first = Spawn.resolve(points, nil)
    return first and first.name or nil
end

--- Save the given coordinates as the new position of a spawn point.
--- @param name string
--- @param coords table { x, y, z, w }
--- @param by string|nil who changed it
--- @return boolean ok, string|nil reason
function SetSpawnPoint(name, coords, by)
    local parsed = Spawn.parseCoords(coords)
    if not parsed then return false, 'invalid_coords' end

    local point, reason = Spawn.normalize({ name = name, coords = parsed })
    if not point then return false, reason end

    local existing = Spawn.resolve(Spawn.normalizeList(Config.Spawns), point.name)

    overrides[point.name] = {
        x = point.x,
        y = point.y,
        z = point.z,
        w = point.w,
        label = existing and existing.label or point.label,
        updatedBy = by or 'console',
        updatedAt = isoNow(),
    }

    queueSave()

    local points = GetSpawnPoints()
    for _, id in ipairs(GetPlayers()) do
        TriggerClientEvent('fk_spawn:client:spawns', tonumber(id), points, GetDefaultSpawnName())
    end

    if Config.Debug then
        log(('Spawn point %s set to %s.'):format(point.name, Spawn.describe(point)))
    end

    return true
end

--- Remove a saved override, falling back to the config.lua value.
--- @return boolean ok, string|nil reason
function ResetSpawnPoint(name)
    local key = Spawn.sanitizeName(name)
    if not key then return false, 'missing_name' end

    if not overrides[key] then return false, 'not_overridden' end

    overrides[key] = nil
    queueSave()

    local points = GetSpawnPoints()
    for _, id in ipairs(GetPlayers()) do
        TriggerClientEvent('fk_spawn:client:spawns', tonumber(id), points, GetDefaultSpawnName())
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------

--- Staff = fk_economy's staff list (/ecostaff) when available, else the ACE.
--- @return boolean
function IsSpawnStaff(source)
    if source == 0 or source == nil then return true end

    if Config.Staff.useEconomy ~= false and GetResourceState('fk_economy') == 'started' then
        local ok, allowed = pcall(function()
            return exports.fk_economy:IsStaff(source)
        end)

        if ok and allowed then return true end
    end

    local ace = Config.Staff.ace
    if ace and IsPlayerAceAllowed and IsPlayerAceAllowed(source, ace) then return true end

    return false
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_spawn:server:requestSpawns', function()
    local source = source

    if not allow('requestSpawns', source) then return end

    TriggerClientEvent('fk_spawn:client:spawns', source, GetSpawnPoints(), GetDefaultSpawnName())
end)

--- Requests come from /spawn and from the first-join handshake. The server
--- decides whether the player may spawn, and which point they get.
RegisterNetEvent('fk_spawn:server:requestSpawn', function(name)
    local source = source

    if not allow('requestSpawn', source) then
        return reply(source, 'Slow down a moment before spawning again.')
    end

    if Config.Spawn.allowPlayerCommand == false and not IsSpawnStaff(source) then
        return reply(source, 'Spawning is automatic here, ask staff for a teleport.')
    end

    local points = GetSpawnPoints()

    if name ~= nil and tostring(name) ~= '' and not Spawn.resolve(points, name) then
        return reply(source, ('No spawn point called "%s". Try /spawnlist.'):format(tostring(name)))
    end

    local point = Spawn.resolve(points, name or GetDefaultSpawnName())

    if not point then
        return reply(source, 'No spawn point is configured on the server.')
    end

    TriggerClientEvent('fk_spawn:client:doSpawn', source, point)
end)

RegisterNetEvent('fk_spawn:server:setSpawn', function(name, x, y, z, w)
    local source = source

    if not allow('setSpawn', source) then return end

    if not IsSpawnStaff(source) then
        return reply(source, 'You need staff access to move a spawn point.')
    end

    local ok, reason = SetSpawnPoint(name, { x = x, y = y, z = z, w = w }, ('player:%d'):format(source))

    if not ok then
        return reply(source, ('Could not save that spawn point (%s).'):format(tostring(reason)))
    end

    local point = GetSpawnPoint(name)
    reply(source, ('Spawn point %s saved: %s'):format(point.name, Spawn.describe(point)))
end)

RegisterNetEvent('fk_spawn:server:resetSpawn', function(name)
    local source = source

    if not allow('resetSpawn', source) then return end

    if not IsSpawnStaff(source) then
        return reply(source, 'You need staff access to reset a spawn point.')
    end

    local ok, reason = ResetSpawnPoint(name)

    if not ok then
        local message = reason == 'not_overridden'
            and 'That spawn point already uses the values from config.lua.'
            or ('Could not reset that spawn point (%s).'):format(tostring(reason))

        return reply(source, message)
    end

    reply(source, ('Spawn point %s reset to config.lua.'):format(tostring(name)))
end)

--- Clients report where they actually ended up, useful while tuning.
RegisterNetEvent('fk_spawn:server:spawned', function(name, x, y, z)
    local source = source

    -- The client played its spawn: clear the join flag so a resource restart
    -- never teleports someone who is already playing.
    pendingSpawn[source] = nil

    local entry = joinEntry(source)
    entry.spawnedAt = os.time()

    if entry.connectedAt and (Config.Spawn.diagnostics or {}).enabled ~= false then
        log(('player %d (%s) finished joining after %ds'):format(
            source, GetPlayerName(source) or '?', entry.spawnedAt - entry.connectedAt))
    end

    local player = Player(source)
    if player and player.state then
        player.state.fkSpawnPending = false
    end

    log(('Player %d (%s) spawned at %s.'):format(source, GetPlayerName(source) or '?', tostring(name)))

    if Config.Debug then
        log(('Player %d (%s) landed at %.2f, %.2f, %.2f'):format(
            source, GetPlayerName(source) or '?', tostring(name), tonumber(x) or 0.0,
            tonumber(y) or 0.0, tonumber(z) or 0.0))
    end

    -- Other resources (police job, interiors, ...) can hook this.
    TriggerEvent('fk_spawn:server:playerSpawned', source, name, x, y, z)
end)

-- ---------------------------------------------------------------------------
-- Join flag — tells the client it should play the spawn once
-- ---------------------------------------------------------------------------

--- The server drives the join spawn: it keeps offering the point until the
--- player confirms they are there. No handshake for the client to miss, and a
--- client that is still loading simply catches the next push.
--- @param source number
function pushJoinSpawn(source)
    CreateThread(function()
        local point = GetSpawnPoint(GetDefaultSpawnName())

        if not point then
            warn('No spawn point configured, cannot spawn players on join.')
            return
        end

        -- Give the client's scripts a moment to come up.
        Wait(Config.Spawn.pushDelay or 3000)

        local attempts = 0
        local maxAttempts = math.max(1, math.floor((Config.Spawn.joinFallback or 30000) / 2500))

        while pendingSpawn[source] and attempts < maxAttempts do
            if GetPlayerName(source) then
                TriggerClientEvent('fk_spawn:client:doSpawn', source, point, true)
                attempts = attempts + 1
            else
                break
            end

            Wait(2500)
        end

        if pendingSpawn[source] then
            pendingSpawn[source] = nil
            warn(('player %d never confirmed the join spawn, giving up.'):format(source))
        end
    end)
end

AddEventHandler('playerConnecting', function(name)
    local source = source

    joinEntry(source, name)
end)

AddEventHandler('playerJoining', function()
    local source = source
    pendingSpawn[source] = true

    local entry = joinEntry(source)
    entry.joiningAt = os.time()

    if Config.Debug then
        log(('player %d joined — spawn pending'):format(source))
    end

    pushJoinSpawn(source)

    local player = Player(source)

    if player and player.state then
        player.state.fkSpawnPending = true
    end
end)

AddEventHandler('playerDropped', function()
    pendingSpawn[source] = nil
    joins[tonumber(source) or source] = nil
end)

--- The client asks on start instead of relying on state bag timing.
RegisterNetEvent('fk_spawn:server:isSpawnPending', function()
    local source = source

    if not allow('isSpawnPending', source) then return end

    TriggerClientEvent('fk_spawn:client:spawnPending', source, pendingSpawn[source] == true)
end)

-- ---------------------------------------------------------------------------
-- Join diagnostics
-- ---------------------------------------------------------------------------

local function diagnostics()
    return Config.Spawn.diagnostics or {}
end

--- The client's scripts are running: everything from here on is our code, not
--- the game's resource streaming.
RegisterNetEvent('fk_spawn:server:hello', function()
    local source = source
    local entry = joinEntry(source)

    if entry.helloAt then return end

    entry.helloAt = os.time()

    if diagnostics().enabled == false then return end

    local after = entry.helloAt - (entry.connectedAt or entry.helloAt)

    log(('player %d (%s): client scripts are up after %ds'):format(
        source, GetPlayerName(source) or '?', after))
end)

--- Human-readable state of one player's join.
--- @return table { stage, connectedFor, ... }
function GetJoinStatus(source)
    local entry = joins[tonumber(source) or 0]

    if not entry then return nil end

    local now = os.time()

    local stage = 'complete'

    if not entry.spawnedAt then
        stage = entry.helloAt and 'spawn_pending' or 'streaming'
    end

    return {
        name = entry.name,
        stage = stage,
        connectedFor = now - (entry.connectedAt or now),
        clientUp = entry.helloAt ~= nil,
        spawned = entry.spawnedAt ~= nil,
        spawnedAfter = entry.spawnedAt and entry.connectedAt
            and (entry.spawnedAt - entry.connectedAt) or nil,
    }
end

exports('GetJoinStatus', function(source)
    return GetJoinStatus(source)
end)

--- Watch every join and say, in the console, what the client is waiting for.
--- Re-armed with SetTimeout instead of looping, so a resource restart cannot
--- leave a stack of watchers behind.
local function checkJoins()
    local ok, err = pcall(function()
        if diagnostics().enabled == false then return end

        local now = os.time()
        local warnAfterClient = math.max(1, math.floor(tonumber(diagnostics().clientWarnAfter) or 15))
        local warnAfterSpawn = math.max(1, math.floor(tonumber(diagnostics().spawnWarnAfter) or 20))
        local repeatEvery = math.max(1, math.floor(tonumber(diagnostics().repeatEvery) or 15))

        for _, id in ipairs(GetPlayers()) do
            local source = tonumber(id)
            local entry = source and joins[source]

            if entry and not entry.spawnedAt and GetPlayerName(source) then
                local sinceConnect = now - (entry.connectedAt or now)
                local sinceHello = entry.helloAt and (now - entry.helloAt) or 0
                -- Single player: say it once. With one client there is no one
                -- else to compare against, so a repeating warning is just noise
                -- in the console of the person who already knows.
                local due = not entry.warnedAt
                    or (not Config.Singleplayer and (now - entry.warnedAt) >= repeatEvery)

                if due and not entry.helloAt and sinceConnect >= warnAfterClient then
                    entry.warnedAt = now
                    warn(('player %d (%s) has been connected for %ds and its scripts have NOT '
                        .. 'started - that PC is still streaming resources (a big pack), not '
                        .. 'our spawn code.'):format(source, GetPlayerName(source) or '?', sinceConnect))
                elseif due and entry.helloAt and sinceHello >= warnAfterSpawn then
                    entry.warnedAt = now
                    warn(('player %d (%s): client scripts are up but the spawn has not completed '
                        .. 'after %ds - check /joinstatus.'):format(
                            source, GetPlayerName(source) or '?', sinceHello))
                end
            end
        end
    end)

    if not ok then
        warn('join diagnostics failed: ' .. tostring(err))
    end

    SetTimeout(5000, checkJoins)
end

SetTimeout(5000, checkJoins)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--- /joinstatus [id] — where a join is stuck, in chat. Works without F8: a
--- client on the loading screen can still be checked from the server console
--- (`joinstatus <id>`) or by an admin in game.
RegisterCommand('joinstatus', function(source, args)
    local src = tonumber(source) or 0
    local target = tonumber(type(args) == 'table' and args[1] or nil)

    if not target then
        if src < 1 then
            return print('Usage: joinstatus <player id>')
        end

        target = src
    end

    if target ~= src and src > 0 and not IsSpawnStaff(src) then
        return reply(src, 'You can only check your own join.')
    end

    local status = GetJoinStatus(target)

    if not status then
        return reply(source, ('Nothing is recorded for player %d.'):format(target))
    end

    if status.stage == 'streaming' then
        return reply(source, ('Player %d: connected %ds ago and its client scripts have not started - '
            .. 'that PC is still streaming resources. Nothing to fix on the server.'):format(
                target, status.connectedFor))
    end

    if status.stage == 'spawn_pending' then
        return reply(source, ('Player %d: client is up, spawn not confirmed after %ds - check the '
            .. 'console for a spawn point error.'):format(target, status.connectedFor))
    end

    reply(source, ('Player %d: joined in %ds.'):format(target, status.spawnedAfter or status.connectedFor))
end, false)

-- /spawnlist — works in chat and in the console.
RegisterCommand(Config.Commands.list or 'spawnlist', function(source)
    local text = Spawn.listText(GetSpawnPoints())

    if source == 0 then
        print(text)
    else
        TriggerClientEvent('fk_spawn:client:list', source, text)
    end
end, false)

-- spawn_set <name> <x> <y> <z> [w] — console (and rcon/txAdmin).
RegisterCommand(Config.Commands.consoleSet or 'spawn_set', function(source, args)
    if source ~= 0 and not IsSpawnStaff(source) then
        return reply(source, 'You need staff access to move a spawn point.')
    end

    local name = args[1]
    local x, y, z, w = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])

    if not name or not x or not y or not z then
        return reply(source, 'Usage: spawn_set <name> <x> <y> <z> [heading]')
    end

    local ok, reason = SetSpawnPoint(name, { x = x, y = y, z = z, w = w }, 'console')

    if not ok then
        return reply(source, ('Could not save that spawn point (%s).'):format(tostring(reason)))
    end

    local point = GetSpawnPoint(name)
    reply(source, ('Spawn point %s saved: %s'):format(point.name, Spawn.describe(point)))
end, true)

-- spawn_reset <name> — drop the override and go back to config.lua.
RegisterCommand(Config.Commands.consoleReset or 'spawn_reset', function(source, args)
    if source ~= 0 and not IsSpawnStaff(source) then
        return reply(source, 'You need staff access to reset a spawn point.')
    end

    local name = args[1]

    if not name then
        return reply(source, 'Usage: spawn_reset <name>')
    end

    local ok, reason = ResetSpawnPoint(name)

    if not ok then
        return reply(source, reason == 'not_overridden'
            and 'That spawn point already uses the values from config.lua.'
            or ('Could not reset that spawn point (%s).'):format(tostring(reason)))
    end

    reply(source, ('Spawn point %s reset to config.lua.'):format(name))
end, true)

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('GetRateLimitStats', SpawnRateLimitStats)
exports('GetSpawnPoints', GetSpawnPoints)
exports('GetSpawnPoint', GetSpawnPoint)
exports('SetSpawnPoint', function(name, coords, by) return SetSpawnPoint(name, coords, by) end)
exports('ResetSpawnPoint', ResetSpawnPoint)
exports('GetDefaultSpawnName', GetDefaultSpawnName)
exports('IsSpawnStaff', IsSpawnStaff)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

loadOverrides()

CreateThread(function()
    Wait(500)

    local points, errors = Spawn.normalizeList(Config.Spawns)

    for _, failure in ipairs(errors) do
        warn(('config.lua spawn point %s is invalid (%s) and was skipped.')
            :format(tostring(failure.name), tostring(failure.reason)))
    end

    local defaultName = GetDefaultSpawnName()

    if not defaultName then
        errorf('No usable spawn point! Check Config.Spawns in config.lua.')
        return
    end

    local point = GetSpawnPoint(defaultName)
    local version = GetResourceMetadata(RESOURCE, 'version', 0) or '?'

    log(('Ready (v%s). Default spawn: %s'):format(version, Spawn.describe(point)))
    log('Players wake up there on join. In game: /spawn to test, /spawnstatus to check.')

    if #overrides > 0 then
        log(('%d spawn point(s) loaded from %s.'):format(#overrides, FILE))
    end
end)
