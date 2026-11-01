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

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function loadOverrides()
    overrides = {}

    local raw = LoadResourceFile(RESOURCE, FILE)
    if not raw or raw == '' then
        if Config.Debug then log('No saved spawn points yet, using config.lua.') end
        return
    end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then
        errorf(('Could not read %s (invalid JSON), using config.lua values.'):format(FILE))
        return
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

    local saved = SaveResourceFile(RESOURCE, FILE, encoded, -1)

    if not saved then
        errorf(('Could not write %s (is the file read-only?).'):format(FILE))
        return false
    end

    return true
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
    TriggerClientEvent('fk_spawn:client:spawns', source, GetSpawnPoints(), GetDefaultSpawnName())
end)

--- Requests come from /spawn and from the first-join handshake. The server
--- decides whether the player may spawn, and which point they get.
RegisterNetEvent('fk_spawn:server:requestSpawn', function(name)
    local source = source

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

AddEventHandler('playerJoining', function()
    local source = source
    pendingSpawn[source] = true

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
end)

--- The client asks on start instead of relying on state bag timing.
RegisterNetEvent('fk_spawn:server:isSpawnPending', function()
    local source = source
    TriggerClientEvent('fk_spawn:client:spawnPending', source, pendingSpawn[source] == true)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

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
