--[[
    fk_house — server/garage.lua
    ---------------------------------------------------------------------------
    One personal vehicle per player, parked in Michael's garage.

    Why everything here happens on the server: an entity created by a client is
    deleted as soon as that client stops streaming it, so a client-side car can
    never survive a drive across the map, let alone a reconnect. The car is
    therefore created with the server-side CreateVehicle, marked as an orphan
    (SetEntityOrphanMode) so the server keeps it alive with no player nearby,
    and re-created by the watchdog if it ever disappears.

    What is stored is only the model, plate, last position and heading, so the
    car that comes back next session is the same model, in the garage.
]]

local RESOURCE = GetCurrentResourceName()
local FILE = (Config.Garage and Config.Garage.file) or 'data/garage.json'

local stored = {} -- [identifier] = { model, plate, x, y, z, w, savedAt }
local live = {}   -- [source] = { entity, netId, identifier, nextTry }

local save       -- forward declaration: load() writes a rescued file back
local loaded = false
local snapshotSlot = 0 -- rotating generation for data/garage.<n>.json

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(...) print('^2[fk_house/garage]^0 ' .. table.concat({ ... }, ' ')) end
local function warn(...) print('^3[fk_house/garage]^0 ' .. table.concat({ ... }, ' ')) end
local function errorf(...) print('^1[fk_house/garage]^0 ' .. table.concat({ ... }, ' ')) end

local function isoNow() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

local function reply(target, message)
    if target == 0 then
        log(message)
    else
        TriggerClientEvent('fk_house:client:notify', target, message)
    end
end

local function playerIdentifier(source)
    local identifiers = GetPlayerIdentifiers(source) or {}

    for _, identifier in ipairs(identifiers) do
        if identifier:sub(1, 8) == 'license:' then return identifier end
    end

    return identifiers[1]
end

local function garageEnabled()
    return not (Config.Garage and Config.Garage.enabled == false)
end

local function garageConfig()
    return Config.Garage or {}
end

--- How many rotating generations to keep (Config.Persistence.backups.slots).
local function backupSlots()
    local backups = (Config.Persistence or {}).backups or {}

    return math.max(1, math.floor(tonumber(backups.slots) or 3))
end

local function insideGarage(coords)
    if not coords then return false end

    return Garage.inZone(coords, garageConfig().coords, garageConfig().radius or 6.0)
end

--- Is this model hash on Config.Garage.blockedModels?
local function blockedHash(hash)
    local list = garageConfig().blockedModels

    if type(list) ~= 'table' or not hash then return false end

    for _, value in pairs(list) do
        local name = Garage.normalizeModel(value)

        if name and Garage.normalizeHash(GetHashKey(name)) == Garage.normalizeHash(hash) then
            return true
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Rate limits (shared/core.lua token buckets)
-- ---------------------------------------------------------------------------

local limits = {
    request = RateLimit.new(Config.RateLimit.garageRequest),
    spawn   = RateLimit.new(Config.RateLimit.garageSpawn),
    park    = RateLimit.new(Config.RateLimit.garagePark),
    forget  = RateLimit.new(Config.RateLimit.garageForget),
}

local lastReset = {}   -- [identifier] = os.time()
local lastFailure = {} -- [source] = os.time(), so a retry loop cannot spam the player

--- @return boolean allowed
local function allow(name, source)
    local limiter = limits[name]

    if not limiter then return true end

    return limiter:allow(source)
end

--- Blocked-request counters for /housestatus.
--- @return table
function GarageRateLimitStats()
    local out = {}

    for name, limiter in pairs(limits) do
        out[name] = limiter.blocked or 0
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

--- Read every saved car back from disk. This runs once at resource start, so
--- it is what makes a car survive a server restart.
local function load()
    stored = {}

    local data, source = Persist.decodeAny(FILE, backupSlots())

    if not data then
        if Persist.read(FILE) then
            errorf(('%s is not valid JSON, starting with an empty garage.'):format(FILE))
        end

        loaded = true
        return
    end

    for identifier, entry in pairs(data.vehicles or {}) do
        local okEntry, clean = pcall(Garage.normalizeVehicle, entry)

        if type(identifier) == 'string' and okEntry and clean then
            stored[identifier] = clean
        else
            warn(('Skipped a saved vehicle for %s.'):format(tostring(identifier)))
        end
    end

    local count = 0

    for _ in pairs(stored) do count = count + 1 end

    if source and source ~= FILE then
        warn(('%s was unreadable — restored %d vehicle(s) from %s.')
            :format(FILE, count, source))
    else
        log(('%d saved vehicle(s) loaded from %s'):format(count, FILE))
    end

    loaded = true

    -- Continue the rotation after the newest generation that already exists,
    -- instead of restarting at slot 1 and overwriting the freshest backup.
    for slot = 1, backupSlots() do
        if Persist.read(Persist.slotPath(FILE, slot)) then snapshotSlot = slot end
    end

    -- Put the rescued copy back where it belongs, so the next restart reads the
    -- main file again instead of needing the backup.
    if source and source ~= FILE then save() end
end

save = function()
    local count = 0

    for _ in pairs(stored) do count = count + 1 end

    local ok, encoded = pcall(json.encode, {
        version = 1,
        savedAt = isoNow(),
        vehicles = stored,
    }, { indent = true })

    if not ok or not encoded then
        errorf('Could not encode the garage.')
        return false
    end

    if not Persist.write(FILE, encoded) then
        return false
    end

    -- Older generations, so a crash mid-write (or a corrupted file) still leaves
    -- something to restore from. Written round-robin; load() picks the newest.
    local slots = backupSlots()

    snapshotSlot = (snapshotSlot % slots) + 1
    Persist.snapshot(FILE, encoded, snapshotSlot, slots)

    if Config.Debug then
        log(('saved %d vehicle(s)'):format(count))
    end

    return true
end

--- Write the garage to disk when the resource stops (restart, `ensure`, server
--- shutdown), so a car parked seconds earlier is not lost with the process.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE or not loaded then return end

    save()
end)

-- ---------------------------------------------------------------------------
-- Live vehicles
-- ---------------------------------------------------------------------------

local function removeLive(source)
    local entry = live[source]

    if not entry then return end

    live[source] = nil

    if entry.entity and entry.entity ~= 0 and DoesEntityExist(entry.entity) then
        DeleteEntity(entry.entity)
    end
end

--- Tell the client about a car that exists on the server.
--- @return number|nil netId
local function announceSpawn(source, identifier, entity, entry, record)
    if not entity or entity == 0 then return nil end
    if not DoesEntityExist(entity) then return nil end

    local netId = NetworkGetNetworkIdFromEntity(entity)

    -- A handle that exists but has no net id yet is not ready either: the client
    -- would get 0 and never resolve the car.
    if not netId or netId == 0 then return nil end

    record.netId = netId
    record.pending = false
    record.nextTry = 0

    pcall(function() SetEntityOrphanMode(entity, 2) end)

    -- Replicated on the entity, so any other script can ask whose car it is
    -- without going through fk_house: Entity(veh).state.garageOwner
    pcall(function()
        local handle = Entity(entity)

        if handle then
            handle.state:set('garageOwner', identifier, true)
            handle.state:set('garagePlate', entry.plate, true)
            handle.state:set('personalVehicle', true, true)
        end
    end)

    TriggerClientEvent('fk_house:client:garage:spawned', source, netId, Garage.publicView(entry))
    log(('spawned %s (%s) for %s, net id %s'):format(entry.model, entry.plate, identifier, tostring(netId)))

    return netId
end

--- Keep asking the game whether a freshly created entity has registered yet.
--- Server-side CreateVehicle can take a tick or two, which is why checking
--- DoesEntityExist once, immediately, used to report a failure for a car that
--- was actually there - and then the next attempt spawned a second one.
local function confirmSpawn(source, entity, entry, record)
    CreateThread(function()
        local deadline = GetGameTimer() + 5000

        while GetGameTimer() < deadline do
            if announceSpawn(source, record.identifier, entity, entry, record) then return end

            if not DoesEntityExist(entity) and GetGameTimer() > (deadline - 4000) then
                break
            end

            Wait(100)
        end

        -- Only forget the record we were confirming: the player may have parked
        -- another car while this one was still coming up.
        if live[source] == record then live[source] = nil end

        if DoesEntityExist(entity) then
            pcall(function() DeleteEntity(entity) end)
        end

        warn(('gave up spawning %s for %s'):format(entry.model, tostring(record.identifier)))

        local now = os.time()

        if GetPlayerName(source) and (now - (lastFailure[source] or 0)) >= 15 then
            lastFailure[source] = now
            reply(source, 'Your car could not be spawned. Try /carreset.')
        end
    end)
end

local function spawnFor(source, identifier, entry, forcePoint)
    if not garageEnabled() then return nil, 'disabled' end
    if type(entry) ~= 'table' then return nil, 'empty' end

    local current = live[source]

    if current then
        -- A creation that is still being confirmed counts as "out": creating a
        -- second one here is exactly how two cars used to appear.
        if current.pending then return 'pending' end

        if current.entity and current.entity ~= 0 and DoesEntityExist(current.entity) then
            TriggerClientEvent('fk_house:client:garage:spawned', source, current.netId, Garage.publicView(entry))
            return current.netId
        end

        live[source] = nil
    end

    local x, y, z, w

    if forcePoint then
        local spawn = garageConfig().spawn or {}
        x, y, z, w = spawn.x or 0.0, spawn.y or 0.0, spawn.z or 0.0, spawn.w or 0.0
    else
        x, y, z, w = Garage.spawnPoint(entry, garageConfig())
    end

    -- The stored hash is what the entity actually was, so a car whose display
    -- name differs from its spawn name (add-ons, police3, ...) still comes back
    -- as the same model. Hashes are unsigned: see Garage.normalizeHash.
    local hash = Garage.normalizeHash(entry.hash) or Garage.normalizeHash(GetHashKey(entry.model))

    if not hash then
        warn(('no usable model hash for %s (stored %s)'):format(entry.model, tostring(entry.hash)))
        return nil, 'create_failed'
    end

    local entity = CreateVehicle(hash, x, y, z, w or 0.0, true, true)

    if not entity or entity == 0 then
        warn(('could not create a %s for %s (model hash %s)')
            :format(entry.model, tostring(identifier), tostring(hash)))
        return nil, 'create_failed'
    end

    local liveRecord = {
        entity = entity,
        netId = nil,
        identifier = identifier,
        pending = true,
        nextTry = os.time() + 10,
    }

    live[source] = liveRecord

    -- Fast path: on a healthy server the entity is registered straight away,
    -- so the client gets the net id in this same tick.
    local netId = announceSpawn(source, identifier, entity, entry, liveRecord)

    if netId then return netId end

    -- Slow path: confirm in the background instead of declaring failure.
    confirmSpawn(source, entity, entry, liveRecord)

    return 'pending'
end

--- Health snapshot for /housestatus.
--- @return table
function GarageStats()
    local storedCount, liveCount, blocked = 0, 0, 0

    for _ in pairs(stored) do storedCount = storedCount + 1 end
    for _ in pairs(live) do liveCount = liveCount + 1 end
    for _, count in pairs(GarageRateLimitStats()) do blocked = blocked + count end

    return {
        stored = storedCount,
        live = liveCount,
        blocked = blocked,
        file = FILE,
    }
end

--- @return table|nil
function GetStoredVehicle(identifier)
    if type(identifier) ~= 'string' then return nil end
    return stored[identifier]
end

--- @return table|nil public view
function GetGarageState(source)
    return Garage.publicView(stored[playerIdentifier(source)])
end

--- Put the car back on the garage floor (stuck in a wall, upside down in a
--- hedge, spawned under the map). Refused while the cooldown is running.
--- @param source number
--- @param force boolean|nil skip the cooldown (staff / your own scripts)
--- @return boolean ok, string|number reasonOrNetId
function ResetGarageVehicle(source, force)
    local identifier = playerIdentifier(source)

    if not identifier then return false, 'no_player' end

    local entry = stored[identifier]

    if not entry then return false, 'empty' end

    local cooldown = math.max(0, tonumber(garageConfig().resetCooldown) or 60)
    local now = os.time()

    if not force and (now - (lastReset[identifier] or 0)) < cooldown then
        return false, math.ceil(cooldown - (now - lastReset[identifier]))
    end

    lastReset[identifier] = now
    removeLive(source)

    local netId = spawnFor(source, identifier, entry, true)

    if netId == 'pending' then return true, nil end
    if not netId then return false, 'create_failed' end

    return true, netId
end

--- Bring the saved car out from your own code.
--- @return number|nil netId (nil when there is nothing stored or the game is still confirming)
function SpawnGarageVehicle(source)
    local identifier = playerIdentifier(source)

    if not identifier then return nil end

    local netId = spawnFor(source, identifier, stored[identifier])

    if netId == 'pending' then return nil end

    return netId
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_house:server:garage:request', function()
    local source = source

    if not garageEnabled() then return end
    if not allow('request', source) then return end

    TriggerClientEvent('fk_house:client:garage:state', source, GetGarageState(source))
end)

--- Bring the saved car out (safe to call repeatedly).
RegisterNetEvent('fk_house:server:garage:spawn', function()
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier or not garageEnabled() then return end
    if not allow('spawn', source) then return end

    local entry = stored[identifier]

    if not entry then
        return reply(source, 'You have no car saved in the garage. Park one first.')
    end

    local netId = spawnFor(source, identifier, entry)

    -- The game is still confirming the entity: the client gets the net id as
    -- soon as it registers, so there is nothing to report.
    if netId == 'pending' then return end

    if not netId then
        local now = os.time()

        -- A retry loop must not turn one failure into a wall of red chat.
        if (now - (lastFailure[source] or 0)) < 15 then return end

        lastFailure[source] = now
        reply(source, 'Your car could not be spawned. Try /carreset.')
    end
end)

--- Park the vehicle the player is next to. The client sends the net id and the
--- model name it thinks it is; the server checks both against the real entity.
RegisterNetEvent('fk_house:server:garage:park', function(netId, modelName, plate, appearance)
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier or not garageEnabled() then return end
    if not allow('park', source) then return end

    local net = House.toNumber(netId)
    if not net then return end

    local entity = NetworkGetEntityFromNetworkId(math.floor(net))

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return reply(source, 'That vehicle is gone — sit in it again and retry.')
    end

    if GetEntityType(entity) ~= 2 then return end

    local coords = GetEntityCoords(entity)

    if not insideGarage(coords) then
        return reply(source, 'Drive the car into the garage first.')
    end

    -- The hash comes from the entity itself, so a client cannot claim a
    -- different model than the one it is standing next to.
    local hash = GetEntityModel(entity)

    if not hash or hash == 0 then
        return reply(source, 'Could not read that vehicle model.')
    end

    hash = Garage.normalizeHash(hash)

    local model = Garage.normalizeModel(modelName)

    if not model then
        model = ('vehicle_%d'):format(math.floor(hash))
    elseif Garage.normalizeHash(GetHashKey(model)) ~= hash then
        warn(('%s sent "%s" for a vehicle with hash %s — storing the hash.')
            :format(tostring(identifier), tostring(model), tostring(math.floor(hash))))
    end

    if Garage.isBlocked(model, garageConfig().blockedModels) or blockedHash(hash) then
        return reply(source, 'That vehicle cannot be kept in the garage.')
    end

    local ped = GetPlayerPed(source)

    if not ped or ped == 0 then return end

    local pedCoords = GetEntityCoords(ped)

    if not pedCoords or House.distance(pedCoords, coords) > 20.0 then
        return reply(source, 'Stand next to the car you want to park.')
    end

    local heading = 0.0

    pcall(function() heading = GetEntityHeading(entity) end)

    local ok, entry = pcall(Garage.normalizeVehicle, {
        model = model,
        hash = hash,
        plate = plate,
        appearance = (garageConfig().appearance ~= false) and appearance or nil,
        x = coords.x,
        y = coords.y,
        z = coords.z,
        w = heading,
        savedAt = isoNow(),
    })

    if not ok or type(entry) ~= 'table' then
        return reply(source, 'That vehicle could not be saved.')
    end

    local previous = live[source]

    if previous and previous.entity and previous.entity ~= entity
        and previous.entity ~= 0 and DoesEntityExist(previous.entity) then
        DeleteEntity(previous.entity)
    end

    live[source] = {
        entity = entity,
        netId = math.floor(net),
        identifier = identifier,
        pending = false,
        nextTry = 0,
    }
    stored[identifier] = entry

    save()

    -- Let the client re-track the car it just parked (it keeps the personal
    -- vehicle flags on it), then refresh the card.
    TriggerClientEvent('fk_house:client:garage:spawned', source, math.floor(net), Garage.publicView(entry))
    TriggerClientEvent('fk_house:client:garage:state', source, Garage.publicView(entry))
    reply(source, ('Parked your %s. It will be waiting in the garage next time you log in.')
        :format(entry.model))
end)

RegisterNetEvent('fk_house:server:garage:forget', function()
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier then return end
    if not allow('forget', source) then return end

    removeLive(source)
    stored[identifier] = nil
    save()

    TriggerClientEvent('fk_house:client:garage:state', source, nil)
    reply(source, 'Your garage is empty again.')
end)

--- Keep the car alive for as long as the player is connected.
AddEventHandler('playerDropped', function()
    -- `source` arrives as a string here, the live table is keyed by number.
    local source = tonumber(source) or source

    removeLive(source)

    for _, limiter in pairs(limits) do
        limiter:reset(source)
    end
end)

-- ---------------------------------------------------------------------------
-- Watchdog
-- ---------------------------------------------------------------------------
-- If the entity ever disappears (engine cleanup, a bad stream, someone calling
-- DeleteEntity on it) it is recreated in the garage a few seconds later. While
-- the player is online the car is never simply gone.
-- How often the watchdog checks. Config.Garage.watchdog is the multiplayer
-- cadence; a single-player server caps it so a culled car returns in seconds.
local watchdogMs = math.max(1000, tonumber(garageConfig().watchdog) or 15000)

if Config.Singleplayer then watchdogMs = math.min(watchdogMs, 5000) end

CreateThread(function()
    while true do
        Wait(watchdogMs)

        if garageEnabled() and garageConfig().respawn ~= false then
            local now = os.time()

            for _, id in ipairs(GetPlayers()) do
                local source = tonumber(id)
                local entry = source and live[source]

                if entry and entry.identifier and not entry.pending then
                    local alive = entry.entity and entry.entity ~= 0 and DoesEntityExist(entry.entity)

                    if not alive and (not entry.nextTry or entry.nextTry <= now) then
                        local record = stored[entry.identifier]

                        live[source] = nil

                        if record then
                            local wait = math.floor((garageConfig().respawnDelay or 5000) / 1000)

                            spawnFor(source, entry.identifier, record)

                            if live[source] then
                                live[source].nextTry = now + math.max(wait, 5)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--- /carreset — chat, so it works without F8.
RegisterCommand('carreset', function(source)
    local src = tonumber(source)

    if not src or src < 1 then
        return print('[fk_house] /carreset is an in-game command.')
    end

    local ok, result = ResetGarageVehicle(src)

    if ok then
        return reply(src, 'Your car is back on the garage floor.')
    end

    if type(result) == 'number' then
        return reply(src, ('You can reset your car again in %d second(s).'):format(result))
    end

    if result == 'empty' then
        return reply(src, 'You have no car saved in the garage.')
    end

    reply(src, 'Your car could not be reset (' .. tostring(result) .. ').')
end, false)

--- garage_list — console overview of what is stored.
RegisterCommand('garage_list', function(source)
    local lines = { '' }
    local count = 0

    for identifier, entry in pairs(stored) do
        count = count + 1
        lines[#lines + 1] = ('%s -> %s at %.1f, %.1f, %.1f')
            :format(identifier, Garage.describe(entry), entry.x, entry.y, entry.z)
    end

    if count == 0 then
        lines[#lines + 1] = 'No vehicles stored.'
    end

    local text = table.concat(lines, '\n')

    if source == 0 then
        print(text)
    else
        TriggerClientEvent('fk_house:client:list', source, text)
    end
end, true)

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('GetGarageVehicle', GetStoredVehicle)
exports('GetGarageState', GetGarageState)
exports('SpawnGarageVehicle', SpawnGarageVehicle)
exports('ResetGarageVehicle', function(source, force)
    return ResetGarageVehicle(source, force)
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

load()

CreateThread(function()
    Wait(800)

    local count = 0

    for _ in pairs(stored) do count = count + 1 end

    log(('Ready (v%s). %d stored vehicle(s).'):format(
        GetResourceMetadata(RESOURCE, 'version', 0) or '?', count))
end)
