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

        if name and math.floor(GetHashKey(name)) == math.floor(hash) then return true end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function load()
    stored = {}

    local raw = LoadResourceFile(RESOURCE, FILE)
    if not raw or raw == '' then return end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then
        errorf(('%s is not valid JSON, starting with an empty garage.'):format(FILE))
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
end

local function save()
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

    if not SaveResourceFile(RESOURCE, FILE, encoded, -1) then
        errorf(('Could not write %s — does the "%s" folder exist in the resource? '
            .. 'SaveResourceFile cannot create folders.'):format(FILE, FILE:match('^(.*)/') or 'data'))
        return false
    end

    if Config.Debug then
        log(('saved %d vehicle(s)'):format(count))
    end

    return true
end

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

local function spawnFor(source, identifier, entry)
    if not garageEnabled() then return nil, 'disabled' end
    if type(entry) ~= 'table' then return nil, 'empty' end

    local current = live[source]

    if current and current.entity and current.entity ~= 0 and DoesEntityExist(current.entity) then
        TriggerClientEvent('fk_house:client:garage:spawned', source, current.netId, Garage.publicView(entry))
        return current.netId
    end

    local x, y, z, w = Garage.spawnPoint(entry, garageConfig())

    -- The hash is what the entity actually was, so a car whose display name
    -- differs from its spawn name still comes back as the same model.
    local hash = GetHashKey(entry.model)

    if type(entry.hash) == 'number' and entry.hash > 0 then
        hash = math.floor(entry.hash)
    end

    local entity = CreateVehicle(hash, x, y, z, w or 0.0, true, true)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        warn(('could not create a %s for %s'):format(entry.model, identifier))
        return nil, 'create_failed'
    end

    -- Orphan mode 2 keeps the entity alive when no player is streaming it.
    pcall(function() SetEntityOrphanMode(entity, 2) end)

    local netId = NetworkGetNetworkIdFromEntity(entity)

    live[source] = {
        entity = entity,
        netId = netId,
        identifier = identifier,
        nextTry = 0,
    }

    TriggerClientEvent('fk_house:client:garage:spawned', source, netId, Garage.publicView(entry))
    log(('spawned %s (%s) for %s, net id %s'):format(entry.model, entry.plate, identifier, tostring(netId)))

    return netId
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

--- @return number|nil netId
function SpawnGarageVehicle(source)
    local identifier = playerIdentifier(source)

    if not identifier then return nil end

    return spawnFor(source, identifier, stored[identifier])
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_house:server:garage:request', function()
    local source = source

    if not garageEnabled() then return end

    TriggerClientEvent('fk_house:client:garage:state', source, GetGarageState(source))
end)

--- Bring the saved car out (safe to call repeatedly).
RegisterNetEvent('fk_house:server:garage:spawn', function()
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier or not garageEnabled() then return end

    local entry = stored[identifier]

    if not entry then
        return reply(source, 'You have no car saved in the garage. Park one first.')
    end

    local netId, reason = spawnFor(source, identifier, entry)

    if not netId then
        return reply(source, ('Your %s could not be spawned (%s).'):format(entry.model, tostring(reason)))
    end
end)

--- Park the vehicle the player is next to. The client sends the net id and the
--- model name it thinks it is; the server checks both against the real entity.
RegisterNetEvent('fk_house:server:garage:park', function(netId, modelName, plate)
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier or not garageEnabled() then return end

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

    local model = Garage.normalizeModel(modelName)

    if not model then
        model = ('vehicle_%d'):format(math.floor(hash))
    elseif GetHashKey(model) ~= hash then
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

    live[source] = { entity = entity, netId = math.floor(net), identifier = identifier, nextTry = 0 }
    stored[identifier] = entry

    save()

    TriggerClientEvent('fk_house:client:garage:state', source, Garage.publicView(entry))
    reply(source, ('Parked your %s. It will be waiting in the garage next time you log in.')
        :format(entry.model))
end)

RegisterNetEvent('fk_house:server:garage:forget', function()
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier then return end

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
end)

-- ---------------------------------------------------------------------------
-- Watchdog
-- ---------------------------------------------------------------------------
-- If the entity ever disappears (engine cleanup, a bad stream, someone calling
-- DeleteEntity on it) it is recreated in the garage a few seconds later. While
-- the player is online the car is never simply gone.
CreateThread(function()
    while true do
        Wait(15000)

        if garageEnabled() and garageConfig().respawn ~= false then
            local now = os.time()

            for _, id in ipairs(GetPlayers()) do
                local source = tonumber(id)
                local entry = source and live[source]

                if entry and entry.identifier then
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
