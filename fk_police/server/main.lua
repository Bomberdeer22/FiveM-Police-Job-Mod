--[[
    fk_police — server/main.lua
    ---------------------------------------------------------------------------
    The authority for the police job: who is on duty, the MDT records, dispatch,
    traffic stops, citations, arrests, jail and backup.

    Everything the client sends is a request. The client never decides a fine, a
    sentence, an XP amount or a payout, and it cannot invent a charge id - every
    one is looked up in config.lua here, and the money moves through fk_economy.
]]

local RESOURCE = GetCurrentResourceName()
local FILE = (Config.Records and Config.Records.file) or 'data/records.json'

local records = {
    version = 1,
    people = {},
    vehicles = {},
    citations = {},
    arrests = {},
    officers = {},
}

local officers = {}      -- [source] = { identifier, onDuty, xp, citations, arrests, callsign }
local stops = {}         -- [source] = { plate, vehicle, person, at }
local activeCallout = nil -- single-player: one callout at a time
local nextCalloutAt = 0

local limits = {
    search = RateLimit.new(Config.RateLimit.search),
    stop = RateLimit.new(Config.RateLimit.stop),
    cite = RateLimit.new(Config.RateLimit.cite),
    arrest = RateLimit.new(Config.RateLimit.arrest),
    backup = RateLimit.new(Config.RateLimit.backup),
    callout = RateLimit.new(Config.RateLimit.callout),
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(...) print('^2[fk_police]^0 ' .. table.concat({ ... }, ' ')) end
local function warn(...) print('^3[fk_police]^0 ' .. table.concat({ ... }, ' ')) end
local function errorf(...) print('^1[fk_police]^0 ' .. table.concat({ ... }, ' ')) end

local function now() return GetGameTimer() end

local function reply(target, message)
    if not target or target == 0 then
        log(tostring(message))
        return
    end

    TriggerClientEvent('fk_police:client:notify', target, message)
end

--- Rate limits are pointless on a single-player server: they exist to stop other
--- players flooding an event.
local function allow(name, source)
    if Config.Singleplayer then return true end

    local limiter = limits[name]

    if not limiter then return true end

    return limiter:allow(source)
end

local function playerIdentifier(source)
    local identifiers = GetPlayerIdentifiers(source) or {}

    for _, identifier in ipairs(identifiers) do
        if identifier:sub(1, 8) == 'license:' then return identifier end
    end

    return identifiers[1]
end

local function isoNow() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

local function newId(prefix)
    return ('%s-%d-%04d'):format(prefix, os.time(), math.random(0, 9999))
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function seedRecords()
    records.people = {}
    records.vehicles = {}

    for _, person in ipairs(Config.Seed.people or {}) do
        local clean = Mdt.normalizePerson(person)
        local key = clean and Mdt.personKey(clean.name)

        if key then records.people[key] = clean end
    end

    for _, vehicle in ipairs(Config.Seed.vehicles or {}) do
        local clean = Mdt.normalizeVehicle(vehicle)
        local key = clean and Mdt.vehicleKey(clean.plate)

        if key then records.vehicles[key] = clean end
    end

    records.citations = records.citations or {}
    records.arrests = records.arrests or {}
    records.officers = records.officers or {}
end

local function load()
    records = {
        version = 1,
        people = {},
        vehicles = {},
        citations = {},
        arrests = {},
        officers = {},
    }

    local data, source = Persist.decodeAny(FILE, 3)

    if not data then
        if Config.Records.seed ~= false then seedRecords() end
        save()
        log(('no %s yet - seeded %d person(s) and %d vehicle(s).')
            :format(FILE, (function()
                local count = 0
                for _ in pairs(records.people) do count = count + 1 end
                return count
            end)(), (function()
                local count = 0
                for _ in pairs(records.vehicles) do count = count + 1 end
                return count
            end)()))
        return
    end

    if source and source ~= FILE then
        warn(('%s was unreadable - restored %s instead.'):format(FILE, source))
    end

    for key, person in pairs(data.people or {}) do
        local clean = Mdt.normalizePerson(person)

        if clean and type(key) == 'string' then records.people[key] = clean end
    end

    for key, vehicle in pairs(data.vehicles or {}) do
        local clean = Mdt.normalizeVehicle(vehicle)

        if clean and type(key) == 'string' then records.vehicles[key] = clean end
    end

    records.citations = type(data.citations) == 'table' and data.citations or {}
    records.arrests = type(data.arrests) == 'table' and data.arrests or {}
    records.officers = type(data.officers) == 'table' and data.officers or {}

    if next(records.people) == nil and Config.Records.seed ~= false then
        seedRecords()
    end
end

function save()
    local ok, encoded = pcall(json.encode, records, { indent = true })

    if not ok or not encoded then
        errorf('could not encode the records')
        return false
    end

    local written = Persist.write(FILE, encoded)

    if written then Persist.snapshot(FILE, encoded, os.time() % 3 + 1, 3) end

    return written
end

-- ---------------------------------------------------------------------------
-- Officer state
-- ---------------------------------------------------------------------------

local function officerFor(source, create)
    local entry = officers[source]

    if entry or not create then return entry end

    local identifier = playerIdentifier(source)

    if not identifier then return nil end

    local saved = records.officers[identifier] or {}

    entry = {
        identifier = identifier,
        onDuty = false,
        xp = tonumber(saved.xp) or 0,
        citations = tonumber(saved.citations) or 0,
        arrests = tonumber(saved.arrests) or 0,
        callsign = saved.callsign or '1-ADAM-12',
    }

    officers[source] = entry

    return entry
end

local function persistOfficer(entry)
    if not entry or not entry.identifier then return end

    records.officers[entry.identifier] = {
        xp = entry.xp,
        citations = entry.citations,
        arrests = entry.arrests,
        callsign = entry.callsign,
        updatedAt = isoNow(),
    }
end

local function statusOf(source)
    local entry = officerFor(source, true)

    if not entry then return Mdt.publicStatus({}, Config) end

    return Mdt.publicStatus(entry, Config)
end

--- Money comes from fk_economy and nowhere else.
local function pay(source, amount, reason)
    if not amount or amount <= 0 then return false end

    local ok, economy = pcall(function() return exports['fk_economy'] end)

    if not ok or not economy or not economy.AddMoney then
        warn('fk_economy is not running - the officer was not paid.')
        return false
    end

    local paid, result = pcall(function()
        return economy:AddMoney(source, 'bank', math.floor(amount), reason or 'police pay')
    end)

    return paid and result == true
end

local sendStatus

local function addXp(source, amount, reason)
    local entry = officerFor(source, true)

    if not entry or not amount or amount <= 0 then return nil end

    local before = Mdt.rankFor(Config, entry.xp)
    entry.xp = entry.xp + math.floor(amount)
    local after = Mdt.rankFor(Config, entry.xp)

    persistOfficer(entry)

    if after.name ~= before.name then
        reply(source, ('Promoted to %s (%d XP).'):format(after.name, entry.xp))
    end

    if reason then
        reply(source, ('+%d XP (%s).'):format(math.floor(amount), reason))
    end

    sendStatus(source)

    return entry.xp
end

sendStatus = function(source)
    TriggerClientEvent('fk_police:client:status', source, statusOf(source), Config.Stations)
end

exports('GetStatus', function(source)
    return statusOf(source)
end)

exports('GetRecords', function()
    return records
end)

exports('IsOnDuty', function(source)
    local entry = officers[source]
    return entry ~= nil and entry.onDuty == true
end)

-- ---------------------------------------------------------------------------
-- Duty, locker, armoury, garage
-- ---------------------------------------------------------------------------

local function setDuty(source, on)
    local entry = officerFor(source, true)

    if not entry then return false, 'no_identifier' end

    entry.onDuty = on == true

    local player = Player(source)

    if player and player.state then
        player.state.fkPoliceDuty = entry.onDuty
        player.state.fkPoliceRank = Mdt.rankFor(Config, entry.xp).name
    end

    if entry.onDuty then
        nextCalloutAt = now() + (tonumber(Config.Dispatch.firstAfter) or 25) * 1000
        TriggerClientEvent('fk_police:client:duty', source, true)
        reply(source, ('You are on duty as %s. Dispatch will call you.')
            :format(Mdt.rankFor(Config, entry.xp).name))
    else
        TriggerClientEvent('fk_police:client:duty', source, false)

        if activeCallout and activeCallout.source == source then
            activeCallout = nil
            TriggerClientEvent('fk_police:client:callout', source, nil)
        end

        reply(source, 'You are off duty.')
    end

    sendStatus(source)

    return true
end

RegisterNetEvent('fk_police:server:duty', function(on)
    local source = source

    setDuty(source, on == true)
end)

exports('SetDuty', function(source, on)
    return setDuty(source, on)
end)

--- The client's last position, used to place callouts. Updated on a slow
--- heartbeat (nothing here is time-critical).
RegisterNetEvent('fk_police:server:pos', function(coords)
    local source = source
    local entry = officerFor(source, true)

    if not entry or type(coords) ~= 'table' then return end

    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)

    if not x or not y or not z then return end

    entry.coords = { x = x, y = y, z = z }
end)

RegisterNetEvent('fk_police:server:ready', function()
    local source = source

    officerFor(source, true)
    sendStatus(source)
end)

RegisterNetEvent('fk_police:server:locker', function()
    local source = source
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return reply(source, 'Go on duty first.')
    end

    TriggerClientEvent('fk_police:client:uniform', source, true)
    reply(source, 'Uniform on. E again with the locker to change back.')
end)

RegisterNetEvent('fk_police:server:armoury', function()
    local source = source
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return reply(source, 'Go on duty first.')
    end

    TriggerClientEvent('fk_police:client:uniform', source, false)
    TriggerClientEvent('fk_police:client:loadout', source, Config.Loadout)
    reply(source, 'Loadout issued: sidearm, taser, baton, torch, armour.')
end)

RegisterNetEvent('fk_police:server:garage', function(model)
    local source = source
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return reply(source, 'Go on duty first.')
    end

    local allowed = false

    for _, vehicle in ipairs(Config.Vehicles or {}) do
        if vehicle.model == model then allowed = true end
    end

    if not allowed then
        return reply(source, 'That vehicle is not in the police garage.')
    end

    -- Single player: the client is the only one who can see it, and there is no
    -- other client to stream it to, so it spawns locally. Validated above.
    TriggerClientEvent('fk_police:client:garage', source, model)
end)

-- ---------------------------------------------------------------------------
-- MDT
-- ---------------------------------------------------------------------------

--- @return table result
local function search(source, kind, query)
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return { ok = false, reason = 'off_duty' }
    end

    if not allow('search', source) then
        return { ok = false, reason = 'rate_limited' }
    end

    if kind == 'person' then
        local people = Mdt.findPeople(records, query)
        local out = {}

        for _, person in ipairs(people) do
            out[#out + 1] = {
                name = person.name,
                dob = person.dob,
                license = person.license,
                warrants = person.warrants,
                flags = Mdt.personFlags(person),
            }
        end

        return { ok = true, kind = 'person', results = out }
    end

    if kind == 'vehicle' then
        local vehicle = Mdt.findVehicle(records, query)

        if not vehicle then return { ok = true, kind = 'vehicle', results = {} } end

        local owner = Mdt.findPerson(records, vehicle.owner)

        return {
            ok = true,
            kind = 'vehicle',
            results = {
                {
                    plate = vehicle.plate,
                    model = vehicle.model,
                    owner = vehicle.owner,
                    stolen = vehicle.stolen,
                    registration = vehicle.registration,
                    insurance = vehicle.insurance,
                    flags = Mdt.vehicleFlags(vehicle),
                    ownerFlags = Mdt.personFlags(owner),
                },
            },
        }
    end

    return { ok = false, reason = 'unknown_kind' }
end

RegisterNetEvent('fk_police:server:search', function(kind, query)
    local source = source

    TriggerClientEvent('fk_police:client:search', source, search(source, kind, query))
end)

exports('Search', function(source, kind, query)
    return search(source, kind, query)
end)

-- ---------------------------------------------------------------------------
-- Traffic stops
-- ---------------------------------------------------------------------------

--- @return table result
local function startStop(source, plate, model)
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return { ok = false, reason = 'off_duty' }
    end

    if not allow('stop', source) then
        return { ok = false, reason = 'rate_limited' }
    end

    local normalized = Mdt.normalizePlate(plate)

    if not normalized then
        return { ok = false, reason = 'bad_plate' }
    end

    local vehicle = Mdt.findVehicle(records, normalized)
    local person = vehicle and Mdt.findPerson(records, vehicle.owner) or nil

    stops[source] = {
        plate = normalized,
        vehicle = vehicle,
        person = person,
        model = model,
        at = now(),
    }

    return {
        ok = true,
        plate = normalized,
        model = vehicle and vehicle.model or model,
        known = vehicle ~= nil,
        owner = vehicle and vehicle.owner or nil,
        stolen = vehicle and vehicle.stolen or false,
        vehicleFlags = Mdt.vehicleFlags(vehicle),
        ownerFlags = Mdt.personFlags(person),
        warrant = Mdt.hasWarrant(person),
    }
end

RegisterNetEvent('fk_police:server:stop', function(plate, model)
    local source = source

    TriggerClientEvent('fk_police:client:stop', source, startStop(source, plate, model))
end)

exports('StartStop', function(source, plate, model)
    return startStop(source, plate, model)
end)

--- @return table|nil stop
local function currentStop(source)
    local stop = stops[source]

    if not stop then return nil end

    -- A stop is good for five minutes; after that the officer is patrolling again.
    if stop.at and (now() - stop.at) > 300000 then
        stops[source] = nil
        return nil
    end

    return stop
end

--- @return table result
local function cite(source, chargeIds)
    local entry = officerFor(source, true)
    local stop = currentStop(source)

    if not entry or not stop then return { ok = false, reason = 'no_stop' } end
    if not allow('cite', source) then return { ok = false, reason = 'rate_limited' } end

    local fine, _, charges = Mdt.sentence(Config, chargeIds)

    if #charges == 0 then return { ok = false, reason = 'no_charge' } end

    local citation = {
        id = newId('CIT'),
        plate = stop.plate,
        person = stop.vehicle and stop.vehicle.owner or nil,
        charges = {},
        fine = fine,
        officer = entry.identifier,
        at = isoNow(),
    }

    for _, charge in ipairs(charges) do citation.charges[#citation.charges + 1] = charge.id end

    records.citations[#records.citations + 1] = citation

    local max = Config.Records.maxCitations or 200

    while #records.citations > max do table.remove(records.citations, 1) end

    entry.citations = entry.citations + 1
    persistOfficer(entry)
    save()

    local share = math.floor(fine * (Config.Pay.fineShare or 0.25))
    local payAmount = (Config.Pay.citation or 0) + share

    pay(source, payAmount, 'citation')
    addXp(source, 25, 'citation')

    return {
        ok = true,
        id = citation.id,
        fine = fine,
        charges = citation.charges,
        paid = payAmount,
    }
end

RegisterNetEvent('fk_police:server:cite', function(chargeIds)
    local source = source
    local result = cite(source, chargeIds)

    reply(source, result.ok
        and ('Citation %s written: %d charge(s), $%d fine.'):format(result.id, #result.charges, result.fine)
        or ('Could not write that citation (%s).'):format(tostring(result.reason)))

    TriggerClientEvent('fk_police:client:cite', source, result)
end)

exports('Cite', function(source, chargeIds)
    return cite(source, chargeIds)
end)

--- @return table result
local function arrest(source, chargeIds)
    local entry = officerFor(source, true)
    local stop = currentStop(source)

    if not entry or not stop then return { ok = false, reason = 'no_stop' } end
    if not allow('arrest', source) then return { ok = false, reason = 'rate_limited' } end

    local fine, jail, charges = Mdt.sentence(Config, chargeIds)

    if #charges == 0 then return { ok = false, reason = 'no_charge' } end

    jail = math.min(jail, Config.Jail.maxSeconds or 600)

    local person = stop.person

    -- An arrest clears the warrant it was made for.
    if person then
        person.warrants = {}
        records.people[Mdt.personKey(person.name)] = person
    end

    local arrestRecord = {
        id = newId('ARR'),
        person = person and person.name or ('Unknown driver of ' .. stop.plate),
        plate = stop.plate,
        charges = {},
        fine = fine,
        jail = jail,
        officer = entry.identifier,
        at = isoNow(),
    }

    for _, charge in ipairs(charges) do arrestRecord.charges[#arrestRecord.charges + 1] = charge.id end

    records.arrests[#records.arrests + 1] = arrestRecord

    local max = Config.Records.maxArrests or 200

    while #records.arrests > max do table.remove(records.arrests, 1) end

    entry.arrests = entry.arrests + 1
    persistOfficer(entry)
    save()

    local share = math.floor(fine * (Config.Pay.fineShare or 0.25))
    local payAmount = (Config.Pay.arrest or 0) + share

    pay(source, payAmount, 'arrest')
    addXp(source, 60, 'arrest')

    stops[source] = nil

    return {
        ok = true,
        id = arrestRecord.id,
        fine = fine,
        jail = jail,
        charges = arrestRecord.charges,
        paid = payAmount,
        person = arrestRecord.person,
    }
end

RegisterNetEvent('fk_police:server:arrest', function(chargeIds)
    local source = source
    local result = arrest(source, chargeIds)

    reply(source, result.ok
        and ('Booked %s: %d charge(s), $%d fine, %d s sentence.'):format(
            result.person, #result.charges, result.fine, result.jail)
        or ('Could not book that arrest (%s).'):format(tostring(result.reason)))

    TriggerClientEvent('fk_police:client:arrest', source, result)
end)

exports('Arrest', function(source, chargeIds)
    return arrest(source, chargeIds)
end)

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function randomPointAround(source)
    -- The server cannot read a client's position, so the client reports it and
    -- this only ever uses that (or the station's own coordinates as a fallback).
    local entry = officers[source]
    local coords = entry and entry.coords

    if not coords then
        local station = Config.Stations and Config.Stations[1]

        if not station then return nil end

        coords = station.coords
    end

    local min = tonumber(Config.Dispatch.minDistance) or 120.0
    local max = tonumber(Config.Dispatch.maxDistance) or 550.0
    local distance = min + math.random() * (max - min)
    local angle = math.random() * math.pi * 2

    return {
        x = coords.x + math.cos(angle) * distance,
        y = coords.y + math.sin(angle) * distance,
        z = coords.z,
    }
end

local function issueCallout(source)
    local callout = Mdt.pickCallout(Config, math.random())

    if not callout then return nil end

    local coords = randomPointAround(source)

    if not coords then return nil end

    activeCallout = {
        id = callout.id,
        code = callout.code,
        label = callout.label,
        xp = callout.xp,
        charges = callout.charges,
        suspects = callout.suspects,
        source = source,
        coords = coords,
        issuedAt = now(),
        expiresAt = now() + (tonumber(Config.Dispatch.expireAfter) or 420) * 1000,
        state = 'offered',
    }

    TriggerClientEvent('fk_police:client:callout', source, activeCallout)

    return activeCallout
end

RegisterNetEvent('fk_police:server:callout:accept', function()
    local source = source

    if not activeCallout or activeCallout.source ~= source then
        return reply(source, 'There is no callout to accept.')
    end

    activeCallout.state = 'accepted'
    activeCallout.acceptedAt = now()

    TriggerClientEvent('fk_police:client:callout', source, activeCallout)
    reply(source, ('Callout accepted: %s (%s).'):format(activeCallout.label, activeCallout.code))
end)

RegisterNetEvent('fk_police:server:callout:decline', function()
    local source = source

    if not activeCallout or activeCallout.source ~= source then return end

    activeCallout = nil
    nextCalloutAt = now() + (tonumber(Config.Dispatch.minGap) or 60) * 1000

    TriggerClientEvent('fk_police:client:callout', source, nil)
    reply(source, 'Callout declined. Dispatch will find you another.')
end)

--- Resolving requires actually being there: the client sends its position and
--- the server compares it with the callout. Nothing else is trusted.
--- @return table result
local function resolveCallout(source, coords)
    if not activeCallout or activeCallout.source ~= source then
        return { ok = false, reason = 'no_callout' }
    end

    if activeCallout.state ~= 'accepted' then
        return { ok = false, reason = 'not_accepted' }
    end

    if type(coords) ~= 'table' then return { ok = false, reason = 'bad_coords' } end

    local dx = (tonumber(coords.x) or 0) - activeCallout.coords.x
    local dy = (tonumber(coords.y) or 0) - activeCallout.coords.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local radius = tonumber(Config.Dispatch.sceneRadius) or 12.0

    if distance > radius then
        return { ok = false, reason = 'too_far', distance = distance }
    end

    local callout = activeCallout
    activeCallout = nil

    local entry = officerFor(source, true)
    local payAmount = Config.Pay.callout or 0

    pay(source, payAmount, 'callout')
    addXp(source, callout.xp, 'callout resolved')

    local gap = tonumber(Config.Dispatch.minGap) or 60
    local maxGap = tonumber(Config.Dispatch.maxGap) or 150

    nextCalloutAt = now() + (gap + math.random() * math.max(0, maxGap - gap)) * 1000

    return {
        ok = true,
        id = callout.id,
        label = callout.label,
        xp = callout.xp,
        paid = payAmount,
        officer = entry and entry.identifier or nil,
    }
end

RegisterNetEvent('fk_police:server:callout:resolve', function(coords)
    local source = source
    local result = resolveCallout(source, coords)

    if not result.ok then
        if result.reason == 'too_far' then
            reply(source, ('Get to the scene first (%.0f m away).'):format(result.distance or 0))
        elseif result.reason == 'not_accepted' then
            reply(source, 'Accept the callout (Y) before closing it.')
        end

        return
    end

    reply(source, ('Callout closed: %s. +%d XP, $%d.'):format(result.label, result.xp, result.paid))
    TriggerClientEvent('fk_police:client:callout', source, nil)
    TriggerClientEvent('fk_police:client:calloutDone', source, result)
    sendStatus(source)
end)

exports('ResolveCallout', function(source, coords)
    return resolveCallout(source, coords)
end)

--- Single-player convenience: ask dispatch for a call now.
RegisterNetEvent('fk_police:server:callout:force', function()
    local source = source
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return reply(source, 'Go on duty first.')
    end

    if not allow('callout', source) then
        return reply(source, 'Dispatch is busy, give it a moment.')
    end

    if activeCallout then
        return reply(source, 'You already have a callout.')
    end

    if issueCallout(source) then
        reply(source, 'Dispatch: copy, sending you a call.')
    end
end)

CreateThread(function()
    while true do
        Wait(5000)

        local onDutySource

        for _, id in ipairs(GetPlayers()) do
            local source = tonumber(id)
            local entry = source and officers[source]

            if entry and entry.onDuty then
                onDutySource = source
                break
            end
        end

        if not onDutySource then
            if activeCallout then
                activeCallout = nil
            end
        elseif activeCallout then
            if now() > activeCallout.expiresAt then
                local source = activeCallout.source
                activeCallout = nil
                nextCalloutAt = now() + (tonumber(Config.Dispatch.minGap) or 60) * 1000
                TriggerClientEvent('fk_police:client:callout', source, nil)
                reply(source, 'Dispatch withdrew the call - no unit responded.')
            end
        elseif now() >= nextCalloutAt then
            issueCallout(onDutySource)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Backup
-- ---------------------------------------------------------------------------

local function requestBackup(source, kind)
    local entry = officerFor(source, true)

    if not entry or not entry.onDuty then
        return { ok = false, reason = 'off_duty' }
    end

    if not allow('backup', source) then
        return { ok = false, reason = 'rate_limited' }
    end

    local option = (Config.Backup or {})[kind]

    if type(option) ~= 'table' or type(option.units) ~= 'number' then
        return { ok = false, reason = 'unknown_kind' }
    end

    TriggerClientEvent('fk_police:client:backup', source, kind, option)

    return { ok = true, kind = kind, units = option.units, delay = option.delay }
end

RegisterNetEvent('fk_police:server:backup', function(kind)
    local source = source
    local result = requestBackup(source, kind)

    if not result.ok then
        return reply(source, ('Backup request failed (%s).'):format(tostring(result.reason)))
    end

    reply(source, ('%s requested - %d unit(s) en route, ETA %ds.')
        :format(kind, result.units, result.delay or 10))
end)

exports('RequestBackup', function(source, kind)
    return requestBackup(source, kind)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

RegisterCommand('pdstatus', function(source)
    local src = tonumber(source)

    if not src or src < 1 then
        local onDuty, total = 0, 0

        for _, entry in pairs(officers) do
            total = total + 1
            if entry.onDuty then onDuty = onDuty + 1 end
        end

        return log(('%d officer(s) tracked, %d on duty, callout: %s')
            :format(total, onDuty, activeCallout and activeCallout.label or 'none'))
    end

    local status = statusOf(src)

    reply(src, ('%s | %s | %d XP | citations %d | arrests %d')
        :format(status.onDuty and 'ON DUTY' or 'off duty', status.rank, status.xp,
            status.citations, status.arrests))
end, false)

-- Console: pdxp <player id> <amount> - a commendation, for testing the ranks.
RegisterCommand('pdxp', function(source, args)
    local src = tonumber(source)

    if src and src > 0 then
        return reply(src, 'pdxp is a console command.')
    end

    local target = tonumber(args and args[1])
    local amount = tonumber(args and args[2])

    if not target or not amount then
        return log('Usage: pdxp <player id> <amount>')
    end

    if not officers[target] then
        return log(('No officer is tracked for player %d.'):format(target))
    end

    addXp(target, amount, 'commendation')
    log(('Gave %d XP to player %d.'):format(math.floor(amount), target))
end, true)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local source = tonumber(source) or source

    officers[source] = nil
    stops[source] = nil

    if activeCallout and activeCallout.source == source then activeCallout = nil end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end

    for source, entry in pairs(officers) do persistOfficer(entry) end

    save()
end)

load()

CreateThread(function()
    Wait(1000)

    local people, vehicles = 0, 0

    for _ in pairs(records.people) do people = people + 1 end
    for _ in pairs(records.vehicles) do vehicles = vehicles + 1 end

    log(('ready (v%s). %d person record(s), %d vehicle record(s), %d callout type(s).%s')
        :format(
            GetResourceMetadata(RESOURCE, 'version', 0) or '?',
            people, vehicles, #(Config.Callouts or {}),
            Config.Singleplayer and ' Single-player mode: rate limits off.' or ''))
end)
