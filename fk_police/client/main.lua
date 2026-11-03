--[[
    fk_police — client/main.lua
    ---------------------------------------------------------------------------
    The gameplay half: station marker and menu, uniform/loadout, police garage,
    dispatch callouts with their blips and scene marker, traffic stops, the MDT
    (NUI), backup units and the chat interaction menu.

    Single-player server: there is one officer, so everything here talks to the
    server only for validation and money. AI units and vehicles are spawned
    locally - there is nobody else to stream them to.
]]

local status = { onDuty = false, rank = 'Cadet', xp = 0 }
local stations = {}
local callout = nil
local currentStop = nil
local uniformOn = false
local savedOutfit = nil
local blips = {}

-- Declared here, not at the bottom of the file: a Lua local declared *after* a
-- closure is not visible inside it, and these are written by event handlers that
-- appear earlier in the file.
local backupState = nil
local scenePeds = {}
local sceneBlips = {}
local clearScene, populateScene
local bodycam = false
local radarOn = (Config.Radar or {}).enabled ~= false
local radar = { plate = nil, speed = 0, on = radarOn }
local anpr = nil
local pursuit = { active = false }
local lastAnprPlate = nil
local pursuitBlip = nil
local hudPayload

-- ---------------------------------------------------------------------------
-- Chat helpers
-- ---------------------------------------------------------------------------

local function chatRunning()
    return GetResourceState('chat') == 'started'
end

local function notify(message)
    message = tostring(message)

    if chatRunning() then
        TriggerEvent('chat:addMessage', {
            color = { 120, 200, 255 },
            args = { 'LSPD', message },
        })

        return
    end

    SetNotificationTextEntry('STRING')
    AddTextComponentSubstringPlayerName('[LSPD] ' .. message)
    DrawNotification(false, true)
end

local function radio(message)
    if chatRunning() then
        TriggerEvent('chat:addMessage', {
            color = { 255, 190, 90 },
            args = { 'DISPATCH', message },
        })

        return
    end

    notify(message)
end

-- ---------------------------------------------------------------------------
-- Status from the server
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_police:client:status', function(nextStatus, nextStations)
    status = type(nextStatus) == 'table' and nextStatus or status

    if type(nextStations) == 'table' and #nextStations > 0 then
        stations = nextStations
    end

    stationBlips()
end)

RegisterNetEvent('fk_police:client:notify', function(message)
    notify(message)
end)

RegisterNetEvent('fk_police:client:duty', function(on)
    status.onDuty = on == true

    if not on and uniformOn then
        TriggerEvent('fk_police:client:uniform', false)
    end
end)

-- ---------------------------------------------------------------------------
-- Stations, markers and the station menu
-- ---------------------------------------------------------------------------

local function stationBlips()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end

    blips = {}

    for _, station in ipairs(stations) do
        local blip = AddBlipForCoord(station.coords.x, station.coords.y, station.coords.z)

        SetBlipSprite(blip, 60)
        SetBlipColour(blip, 38)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(station.label or 'Police station')
        EndTextCommandSetBlipName(blip)

        blips[#blips + 1] = blip
    end
end

local function nearestStation()
    local coords = GetEntityCoords(PlayerPedId())
    local best, bestDistance = nil, nil

    for _, station in ipairs(stations) do
        local dx = coords.x - station.coords.x
        local dy = coords.y - station.coords.y
        local dz = coords.z - station.coords.z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

        if distance <= (station.radius or 30.0) and (not bestDistance or distance < bestDistance) then
            best, bestDistance = station, distance
        end
    end

    return best, bestDistance
end

local function showMenu()
    local lines = {
        'Interaction menu',
        ('  1. Duty: %s  (/duty)'):format(status.onDuty and 'ON' or 'off'),
        '  2. Police computer  (/pc)',
        '  3. Locker (uniform)  (/pd locker)',
        '  4. Armoury (loadout)  (/pd armoury)',
        '  5. Police garage  (/pd garage)',
        '  6. Backup  (/backup <code2|code3|air|k9|swat|ems|fire>)',
        '  7. Traffic stop  (/stop)',
        '  8. Charges and fines  (/pd charges)',
    }

    if callout then
        lines[#lines + 1] = ('  Callout: %s (%s) - /callout to accept, drive to the marker.')
            :format(callout.label, callout.code)
    end

    for _, line in ipairs(lines) do notify(line) end
end

--- The station menu: every service is a command, and E near the station opens
--- the same list, so nothing depends on a key that a Mac keyboard cannot send.
RegisterCommand(Config.Commands.menu or 'pd', function(_, args)
    local action = type(args) == 'table' and args[1] or nil

    if action == 'charges' then
        for _, charge in ipairs(Config.Charges or {}) do
            notify(('  %s - %s ($%d%s)'):format(
                charge.id, charge.label, charge.fine,
                (charge.jail or 0) > 0 and (', %ds'):format(charge.jail) or ''))
        end

        return notify('Use /cite <id...> or /arrest <id...> at a traffic stop.')
    end

    if action == 'locker' then return TriggerServerEvent('fk_police:server:locker') end
    if action == 'armoury' then return TriggerServerEvent('fk_police:server:armoury') end

    if action == 'garage' then
        local _, distance = nearestStation()

        if not distance then
            return notify('Drive to a police station to use the garage.')
        end

        notify('Police garage:')
        for index, vehicle in ipairs(Config.Vehicles or {}) do
            notify(('  %d. %s (%s)'):format(index, vehicle.label, vehicle.model))
        end

        return notify('Use /pd car <model>, e.g. /pd car police3')
    end

    if action == 'car' then
        local model = type(args) == 'table' and args[2] or nil

        if not model then return notify('Usage: /pd car <model>') end

        return TriggerServerEvent('fk_police:server:garage', tostring(model))
    end

    showMenu()
end, false)

-- ---------------------------------------------------------------------------
-- Uniform and loadout
-- ---------------------------------------------------------------------------

local function saveOutfit()
    if savedOutfit then return end

    savedOutfit = {
        model = GetEntityModel(PlayerPedId()),
        components = {},
    }

    for component = 0, 11 do
        savedOutfit.components[component] = {
            drawable = GetPedDrawableVariation(PlayerPedId(), component),
            texture = GetPedTextureVariation(PlayerPedId(), component),
            palette = GetPedPaletteVariation(PlayerPedId(), component),
        }
    end
end

RegisterNetEvent('fk_police:client:uniform', function(on)
    local ped = PlayerPedId()

    if on then
        saveOutfit()

        local female = GetEntityModel(ped) == GetHashKey('mp_f_freemode_01')
        local set = female and Config.Uniform.female or Config.Uniform.male

        for _, piece in ipairs(set or {}) do
            SetPedComponentVariation(ped, piece.component, piece.drawable, piece.texture, 0)
        end

        uniformOn = true
        notify('Uniform on.')
        return
    end

    if savedOutfit then
        for component, piece in pairs(savedOutfit.components) do
            SetPedComponentVariation(ped, component, piece.drawable, piece.texture, piece.palette or 0)
        end
    end

    uniformOn = false
    notify('Uniform off.')
end)

RegisterNetEvent('fk_police:client:loadout', function(loadout)
    local ped = PlayerPedId()

    for _, item in ipairs((loadout or {}).weapons or {}) do
        GiveWeaponToPed(ped, GetHashKey(item.weapon), item.ammo or 0, false, true)
    end

    SetPedArmour(ped, (loadout or {}).armour or 0)
    notify('Armoury: loadout issued.')
end)

-- ---------------------------------------------------------------------------
-- Police garage
-- ---------------------------------------------------------------------------

local function spawnPoliceVehicle(model)
    local hash = GetHashKey(model)

    RequestModel(hash)

    local waited = 0

    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    if not HasModelLoaded(hash) then
        return notify(('Could not load %s - is that vehicle installed?'):format(model))
    end

    local coords = GetEntityCoords(PlayerPedId())
    local heading = GetEntityHeading(PlayerPedId())
    local vehicle = CreateVehicle(hash, coords.x + 4.0, coords.y + 4.0, coords.z, heading, true, false)

    SetVehicleNumberPlateText(vehicle, 'LSPD' .. math.random(100, 999))
    SetVehicleDirtLevel(vehicle, 0.0)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetModelAsNoLongerNeeded(hash)
    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)

    -- Single-player: the vehicle is fine as a client entity; there is nobody to
    -- stream it to and nothing to persist.
    notify(('%s is ready.'):format(model))
end

RegisterNetEvent('fk_police:client:garage', function(model)
    spawnPoliceVehicle(model)
end)

-- ---------------------------------------------------------------------------
-- Dispatch callouts
-- ---------------------------------------------------------------------------

local calloutBlip = nil

local function clearCalloutBlip()
    if calloutBlip and DoesBlipExist(calloutBlip) then RemoveBlip(calloutBlip) end
    calloutBlip = nil
end

RegisterNetEvent('fk_police:client:callout', function(nextCallout)
    callout = type(nextCallout) == 'table' and nextCallout or nil
    clearCalloutBlip()

    if not callout then
        if clearScene then clearScene() end
        return
    end

    if callout.coords then
        calloutBlip = AddBlipForCoord(callout.coords.x, callout.coords.y, callout.coords.z)
        SetBlipSprite(calloutBlip, 161)
        SetBlipColour(calloutBlip, 1)
        SetBlipScale(calloutBlip, 1.1)
        SetBlipAsShortRange(calloutBlip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(('%s - %s'):format(callout.code or 'CALL', callout.label or 'Callout'))
        EndTextCommandSetBlipName(calloutBlip)
        SetBlipRoute(calloutBlip, true)
    end

    radio(('%s: %s. Press Y to accept.'):format(callout.code or 'CALL', callout.label or 'Callout'))

    -- Accepted: the scene now has people on it.
    if callout.state == 'accepted' and populateScene then populateScene(callout) end
end)

RegisterNetEvent('fk_police:client:calloutDone', function(result)
    radio(('Call closed: %s. +%d XP, $%d.'):format(result.label, result.xp or 0, result.paid or 0))
end)

RegisterCommand(Config.Commands.callout or 'callout', function()
    TriggerServerEvent('fk_police:server:callout:accept')
end, false)

RegisterCommand(Config.Commands.forceCallout or 'callout_force', function()
    TriggerServerEvent('fk_police:server:callout:force')
end, false)

-- ---------------------------------------------------------------------------
-- Traffic stops
-- ---------------------------------------------------------------------------

local function vehicleAhead(distance)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local maxDistance = distance or (Config.Traffic or {}).maxDistance or 25.0
    local best, bestDistance = 0, nil

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) then
            local target = GetEntityCoords(vehicle)
            local dx = target.x - coords.x
            local dy = target.y - coords.y
            local distance = math.sqrt(dx * dx + dy * dy)

            if distance > 2.0 and distance <= maxDistance then
                local dot = ((target.x - coords.x) / distance) * forward.x
                    + ((target.y - coords.y) / distance) * forward.y

                -- In front of the officer, at all.
                if dot > 0.35 and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = vehicle, distance
                end
            end
        end
    end

    return best
end

RegisterNetEvent('fk_police:client:stop', function(result)
    if not result or not result.ok then
        local reason = result and result.reason or 'failed'

        if reason == 'off_duty' then
            return notify('Go on duty first (/duty).')
        end

        if reason == 'bad_plate' then
            return notify('That vehicle has no readable plate.')
        end

        return notify(('Traffic stop failed (%s).'):format(reason))
    end

    currentStop = result

    radio(('10-38 on %s (%s).'):format(result.plate, result.model or 'unknown'))

    if not result.known then
        return notify('That plate is not in the vehicle database.')
    end

    notify(('Owner: %s.'):format(result.owner))

    if result.stolen then notify('*** STOLEN VEHICLE ***') end

    for _, flag in ipairs(result.vehicleFlags or {}) do notify('  ' .. flag) end
    for _, flag in ipairs(result.ownerFlags or {}) do notify('  ' .. flag) end

    if result.warrant then notify('The registered owner has an outstanding warrant.') end
end)

RegisterCommand(Config.Commands.stop or 'stop', function()
    local vehicle = vehicleAhead()

    if not vehicle or vehicle == 0 then
        return notify('Get behind a vehicle first (within 25 m, in front of you).')
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    local model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))

    -- Pull them over: the AI driver stops and waits.
    local driver = GetPedInVehicleSeat(vehicle, -1)

    if driver and driver ~= 0 then
        TaskVehicleTempAction(driver, vehicle, 27, 8000)
    end

    TriggerServerEvent('fk_police:server:stop', plate, tostring(model):lower())
end, false)

local function chargeArgs(args)
    local ids = {}

    for _, value in ipairs(args or {}) do ids[#ids + 1] = tostring(value) end

    return ids
end

RegisterCommand(Config.Commands.cite or 'cite', function(_, args)
    if not currentStop then return notify('Run /stop on a vehicle first.') end

    TriggerServerEvent('fk_police:server:cite', chargeArgs(args))
end, false)

RegisterCommand(Config.Commands.arrest or 'arrest', function(_, args)
    if not currentStop then return notify('Run /stop on a vehicle first.') end

    local ped = PlayerPedId()
    local vehicle = vehicleAhead()

    if vehicle and vehicle ~= 0 then
        local driver = GetPedInVehicleSeat(vehicle, -1)

        if driver and driver ~= 0 then
            -- Hands up, then cuffed; the AI stays put.
            TaskHandsUp(driver, 8000, PlayerPedId(), -1, true)
            Wait(1200)
            ClearPedTasks(driver)
            SetEnableHandcuffs(driver, true)
            SetPedCanRagdoll(driver, false)
            SetPedCanPlayGestureAnims(driver, false)
        end
    end

    TriggerServerEvent('fk_police:server:arrest', chargeArgs(args))
end, false)

RegisterNetEvent('fk_police:client:cite', function(result)
    if result and result.ok then
        notify(('Citation %s: $%d, %d charge(s). Paid $%d.')
            :format(result.id, result.fine, #(result.charges or {}), result.paid or 0))
    end
end)

RegisterNetEvent('fk_police:client:arrest', function(result)
    if result and result.ok then
        -- The server closes the stop when the arrest is booked; drop the local
        -- copy too, so /cite does not offer a citation on a car that has gone.
        currentStop = nil

        notify(('Arrest %s: %s, %d s, $%d fine. Paid $%d.')
            :format(result.id, tostring(result.person), result.jail or 0, result.fine, result.paid or 0))
    end
end)

-- ---------------------------------------------------------------------------
-- Backup
-- ---------------------------------------------------------------------------

local function spawnBackupUnit(kind, option, index)
    local model = option.model or (Config.Backup and Config.Backup.policeModel) or 'police3'
    local hash = GetHashKey(model)

    RequestModel(hash)

    local waited = 0

    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    if not HasModelLoaded(hash) then return end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local angle = math.random() * math.pi * 2
    local distance = (Config.Backup and Config.Backup.spawnDistance) or 120.0
    local x = coords.x + math.cos(angle) * distance
    local y = coords.y + math.sin(angle) * distance

    local vehicle = CreateVehicle(hash, x, y, coords.z, 0.0, true, false)
    local driver = CreatePedInsideVehicle(vehicle, 4, GetHashKey('s_m_y_cop_01'), -1, true, true)

    SetEntityAsMissionEntity(vehicle, true, true)
    SetEntityAsMissionEntity(driver, true, true)
    SetModelAsNoLongerNeeded(hash)

    if kind == 'ems' then
        SetVehicleSiren(vehicle, false)
    else
        SetVehicleSiren(vehicle, kind ~= 'code2')
        SetVehicleHasMutedSirens(vehicle, kind == 'code2')
    end

    TaskVehicleDriveToCoordLongRange(driver, vehicle, coords.x, coords.y, coords.z, 22.0, 447, 10.0)

    notify(('Backup unit %d (%s) en route.'):format(index, kind))
end

RegisterNetEvent('fk_police:client:backup', function(kind, option)
    local units = (option and option.units) or 1

    backupState = { kind = kind, eta = (option and option.delay) or 10, at = GetGameTimer() }

    CreateThread(function()
        for index = 1, units do
            spawnBackupUnit(kind, option or {}, index)
            Wait(700)
        end
    end)
end)

RegisterCommand(Config.Commands.backup or 'backup', function(_, args)
    local kind = type(args) == 'table' and args[1] or nil

    if not kind then
        return notify('Backup: /backup code2, code3, air, k9, swat, ems, fire')
    end

    TriggerServerEvent('fk_police:server:backup', tostring(kind))
end, false)

-- ---------------------------------------------------------------------------
-- Duty toggle and position heartbeat
-- ---------------------------------------------------------------------------

RegisterCommand(Config.Commands.duty or 'duty', function()
    TriggerServerEvent('fk_police:server:duty', not status.onDuty)
end, false)

CreateThread(function()
    Wait(1500)
    TriggerServerEvent('fk_police:server:ready')

    while true do
        Wait(15000)

        local coords = GetEntityCoords(PlayerPedId())

        TriggerServerEvent('fk_police:server:pos', { x = coords.x, y = coords.y, z = coords.z })
    end
end)

-- ---------------------------------------------------------------------------
-- MDT (NUI police computer)
-- ---------------------------------------------------------------------------

local function openComputer()
    if not status.onDuty and not Config.Singleplayer then
        return notify('Go on duty first (/duty).')
    end

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        status = status,
        charges = Config.Charges,
        calls = callout and { callout } or {},
        keys = Config.Commands,
    })

    -- Everything else the page lists (BOLOs, reports, fines, impounds, shifts,
    -- warrants, the court fund) comes from the server in one bundle.
    TriggerServerEvent('fk_police:server:mdt')
end

local function closeComputer()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterCommand(Config.Commands.computer or 'pc', function()
    openComputer()
end, false)

RegisterNUICallback('close', function(_, cb)
    closeComputer()
    cb({ ok = true })
end)

RegisterNUICallback('search', function(data, cb)
    TriggerServerEvent('fk_police:server:search', tostring(data.kind or 'person'), tostring(data.query or ''))
    cb({ ok = true })
end)

RegisterNUICallback('callout', function(data, cb)
    local action = tostring(data.action or 'accept')

    if action == 'accept' then
        TriggerServerEvent('fk_police:server:callout:accept')
    elseif action == 'decline' then
        TriggerServerEvent('fk_police:server:callout:decline')
    end

    cb({ ok = true })
end)

RegisterNUICallback('backup', function(data, cb)
    TriggerServerEvent('fk_police:server:backup', tostring(data.kind or 'code2'))
    cb({ ok = true })
end)

RegisterNetEvent('fk_police:client:search', function(result)
    SendNUIMessage({ action = 'results', result = result })
end)

-- ---------------------------------------------------------------------------
-- E prompt: station services and the callout scene
-- ---------------------------------------------------------------------------

CreateThread(function()
    while true do
        local sleep = 400
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        -- Station services
        local station = nearestStation()

        if station then
            sleep = 0

            local vehicle = GetVehiclePedIsIn(ped, false)

            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(
                (vehicle ~= 0)
                    and 'Press ~INPUT_CONTEXT~ to open the police computer.'
                    or 'Press ~INPUT_CONTEXT~ for station services.')
            EndTextCommandDisplayHelp(0, false, true, -1)

            if IsControlJustReleased(0, Config.Keys.interact) then
                if vehicle ~= 0 then
                    openComputer()
                else
                    showMenu()
                end
            end
        elseif callout and callout.coords then
            local dx = coords.x - callout.coords.x
            local dy = coords.y - callout.coords.y
            local distance = math.sqrt(dx * dx + dy * dy)
            local radius = (Config.Dispatch and Config.Dispatch.sceneRadius) or 12.0

            if callout.state == 'accepted' and distance <= radius then
                sleep = 0

                BeginTextCommandDisplayHelp('STRING')
                AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to close this callout.')
                EndTextCommandDisplayHelp(0, false, true, -1)

                if IsControlJustReleased(0, Config.Keys.interact) then
                    TriggerServerEvent('fk_police:server:callout:resolve',
                        { x = coords.x, y = coords.y, z = coords.z })
                end
            end
        end

        Wait(sleep)
    end
end)

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

RegisterKeyMapping('pd', 'Police interaction menu', 'keyboard', 'M')
RegisterKeyMapping('pc', 'Police computer', 'keyboard', 'F9')
RegisterKeyMapping('stop', 'Traffic stop', 'keyboard', 'F10')
RegisterKeyMapping('duty', 'Go on / off duty', 'keyboard', 'F11')
RegisterKeyMapping('callout', 'Accept callout', 'keyboard', 'Y')
RegisterKeyMapping('callout_force', 'Ask dispatch for a call now', 'keyboard', 'X')
RegisterKeyMapping('cite', 'Cite the current stop', 'keyboard', 'F6')
RegisterKeyMapping('arrest', 'Arrest the current stop', 'keyboard', 'F7')
RegisterKeyMapping('radar', 'Toggle the radar', 'keyboard', 'F5')
RegisterKeyMapping('bodycam', 'Toggle the bodycam', 'keyboard', 'L')

RegisterCommand('backup_code3', function()
    TriggerServerEvent('fk_police:server:backup', 'code3')
end, false)

RegisterKeyMapping('backup_code3', 'Request backup (code 3)', 'keyboard', 'G')

CreateThread(function()
    Wait(3000)
    stationBlips()
end)

-- ---------------------------------------------------------------------------
-- HUD, radar and the ANPR
-- ---------------------------------------------------------------------------

hudPayload = function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local progress = nil

    -- The rank maths also lives in shared/mdt.lua; the client only needs the
    -- percentage, and the server already sends the rank name.
    if status.nextRankXp and status.xp then
        local span = math.max(1, (status.nextRankXp or 0) - (status.rankXp or 0))
        progress = math.max(0, math.min(100, math.floor(((status.xp - (status.rankXp or 0)) / span) * 100)))
    end

    local calloutHud = nil

    if callout and callout.coords then
        local dx = coords.x - callout.coords.x
        local dy = coords.y - callout.coords.y
        local dz = coords.z - callout.coords.z

        calloutHud = {
            code = callout.code,
            label = callout.label,
            state = callout.state,
            distance = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz)),
            xp = callout.xp,
        }
    end

    return {
        onDuty = status.onDuty == true,
        rank = status.rank,
        xp = status.xp or 0,
        percent = progress,
        nextRank = status.nextRank,
        citations = status.citations or 0,
        arrests = status.arrests or 0,
        callsign = status.callsign,
        shiftSeconds = status.shiftSeconds or 0,
        callout = calloutHud,
        radar = (radarOn and (Config.Hud or {}).showRadar ~= false)
            and { plate = radar.plate, speed = radar.speed, alert = anpr and anpr.alert or false }
            or nil,
        anpr = anpr,
        pursuit = pursuit.active and pursuit or nil,
        custody = (status.custodySeconds or 0) > 0
            and { seconds = status.custodySeconds, person = status.custodyPerson }
            or nil,
        backup = backupState,
        bodycam = bodycam,
        pursuitActive = pursuit.active == true,
    }
end

CreateThread(function()
    if Config.Hud and Config.Hud.enabled == false then return end

    Wait(2000)

    local interval = math.max(200, tonumber(Config.Hud and Config.Hud.interval) or 500)

    while true do
        SendNUIMessage({ action = 'hud', hud = hudPayload() })
        Wait(interval)
    end
end)

--- Radar: read the car in front, in mph, and ask the server what is known
--- about the plate (that is the ANPR half).
CreateThread(function()
    while true do
        Wait(250)

        local reading = nil

        if radarOn and status.onDuty then
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)

            if vehicle ~= 0 then
                local target = vehicleAhead((Config.Radar or {}).maxDistance or 60.0)

                if target and target ~= 0 then
                    local speed = GetEntitySpeed(target) * 2.23694
                    local plate = GetVehicleNumberPlateText(target)

                    reading = {
                        speed = math.floor(speed + 0.5),
                        plate = plate and plate:gsub('%s+$', '') or nil,
                        moving = speed >= ((Config.Radar or {}).minSpeed or 4.0),
                    }
                end
            end
        end

        if reading then
            radar.speed = reading.speed
            radar.plate = reading.plate

            if (Config.Radar or {}).autoAnpr ~= false and reading.moving
                and reading.plate and #reading.plate > 1 and reading.plate ~= lastAnprPlate then
                lastAnprPlate = reading.plate
                TriggerServerEvent('fk_police:server:anpr', reading.plate)
            end
        else
            radar.speed, radar.plate, lastAnprPlate = 0, nil, nil
        end
    end
end)

RegisterNetEvent('fk_police:client:anpr', function(report)
    anpr = {
        plate = report.plate,
        known = report.known == true,
        stolen = report.stolen == true,
        flags = report.flags or {},
        ownerFlags = report.ownerFlags or {},
        bolos = report.bolos or {},
        impounded = report.impounded == true,
        alert = report.stolen == true or #(report.bolos or {}) > 0
            or #(report.flags or {}) > 0 or #(report.ownerFlags or {}) > 0,
    }

    if anpr.alert then
        TriggerEvent('chat:addMessage', {
            color = { 255, 90, 90 },
            args = { 'ANPR', ('%s: %s'):format(anpr.plate, table.concat(
                (function()
                    local list = {}

                    if anpr.stolen then list[#list + 1] = 'STOLEN' end
                    for _, bolo in ipairs(anpr.bolos) do list[#list + 1] = 'BOLO: ' .. tostring(bolo.reason) end
                    for _, flag in ipairs(anpr.flags) do list[#list + 1] = flag end
                    for _, flag in ipairs(anpr.ownerFlags) do list[#list + 1] = flag end

                    return list
                end)(), ', ')) },
        })
    end
end)

RegisterCommand(Config.Commands.radar or 'radar', function()
    radarOn = not radarOn
    radar.on = radarOn
    notify(radarOn and 'Radar on.' or 'Radar off.')
end, false)

RegisterCommand('shift', function(_, args)
    local action = type(args) == 'table' and tostring(args[1] or '') or ''
    TriggerServerEvent('fk_police:server:shift', action)
end, false)

RegisterCommand(Config.Commands.bodycam or 'bodycam', function()
    bodycam = not bodycam

    if bodycam then
        notify('Bodycam recording.')
    else
        notify('Bodycam stopped.')
    end
end, false)

-- ---------------------------------------------------------------------------
-- Callout scenes: suspects, and tidying them up again
-- ---------------------------------------------------------------------------

function clearScene()
    for _, blip in ipairs(sceneBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end

    sceneBlips = {}

    for _, ped in ipairs(scenePeds) do
        if DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, false, true)
            DeleteEntity(ped)
        end
    end

    scenePeds = {}
end

function populateScene(activeCallout)
    clearScene()

    local suspects = tonumber(activeCallout.suspects) or 0

    if suspects <= 0 or not activeCallout.coords then return end

    local model = GetHashKey('g_m_y_lost_01')

    RequestModel(model)

    local waited = 0

    while not HasModelLoaded(model) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    if not HasModelLoaded(model) then return end

    local group = GetHashKey('COP')

    for index = 1, suspects do
        local angle = (index / math.max(1, suspects)) * math.pi * 2
        local x = activeCallout.coords.x + math.cos(angle) * (3.0 + index)
        local y = activeCallout.coords.y + math.sin(angle) * (3.0 + index)

        local ped = CreatePed(4, model, x, y, activeCallout.coords.z, angle * 57.2958, true, true)

        if DoesEntityExist(ped) then
            SetPedFleeAttributes(ped, 0, false)
            SetPedCombatAttributes(ped, 46, true)
            SetPedCombatAbility(ped, 2)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedAlertness(ped, 3)

            if activeCallout.weapon then
                local weapon = GetHashKey(activeCallout.weapon)
                GiveWeaponToPed(ped, weapon, 250, false, true)
            end

            SetPedRelationshipGroupHash(ped, group)
            TaskCombatPed(ped, PlayerPedId(), 0, 16)

            local blip = AddBlipForEntity(ped)
            SetBlipSprite(blip, 84)
            SetBlipColour(blip, 1)
            SetBlipScale(blip, 0.8)
            SetBlipAsShortRange(blip, true)

            sceneBlips[#sceneBlips + 1] = blip
            scenePeds[#scenePeds + 1] = ped
        end
    end

    SetModelAsNoLongerNeeded(model)
end

RegisterNetEvent('fk_police:client:calloutScene', function(activeCallout)
    if not activeCallout then return clearScene() end

    populateScene(activeCallout)
end)

-- ---------------------------------------------------------------------------
-- Custody: walk the suspect into the cell
-- ---------------------------------------------------------------------------

local custodyPed = nil

local function suspectNearby()
    local vehicle = vehicleAhead(35.0)

    if vehicle and vehicle ~= 0 then
        local driver = GetPedInVehicleSeat(vehicle, -1)

        if driver and driver ~= 0 then return driver end
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local best, bestDistance = nil, nil

    for _, candidate in ipairs(scenePeds) do
        if DoesEntityExist(candidate) then
            local target = GetEntityCoords(candidate)
            local dx, dy, dz = target.x - coords.x, target.y - coords.y, target.z - coords.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

            if distance < 40.0 and (not bestDistance or distance < bestDistance) then
                best, bestDistance = candidate, distance
            end
        end
    end

    return best
end

RegisterNetEvent('fk_police:client:custody', function(booking)
    if not booking or not booking.cell then return end

    custodyPed = suspectNearby()

    if not custodyPed then
        return notify(('%s booked. There was nobody nearby to walk to the cell.'):format(tostring(booking.person)))
    end

    SetEntityCoords(custodyPed, booking.cell.x, booking.cell.y, booking.cell.z, false, false, false, true)
    SetEntityHeading(custodyPed, booking.cell.w or 0.0)
    ClearPedTasks(custodyPed)
    SetBlockingOfNonTemporaryEvents(custodyPed, true)
    SetPedCanRagdoll(custodyPed, false)
    FreezeEntityPosition(custodyPed, true)
    SetEntityAsMissionEntity(custodyPed, true, true)

    notify(('%s is in the cell for %s.'):format(tostring(booking.person), tostring(booking.seconds) .. 's'))
end)

RegisterNetEvent('fk_police:client:custodyEnded', function(result)
    if custodyPed and DoesEntityExist(custodyPed) then
        FreezeEntityPosition(custodyPed, false)
        SetEntityAsMissionEntity(custodyPed, false, true)
        DeleteEntity(custodyPed)
    end

    custodyPed = nil

    if result and result.person then
        notify(('%s released.'):format(tostring(result.person)))
    end
end)

-- The tow truck takes the car away: the impounded car is deleted locally so the
-- lot means something. Anything further than 60 m is left alone.
RegisterNetEvent('fk_police:client:impound', function(record)
    if not record or not record.plate then return end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local wanted = tostring(record.plate):upper():gsub('%s+', '')
    local removed = false

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) and not IsPedInVehicle(ped, vehicle, false) then
            local plate = GetVehicleNumberPlateText(vehicle) or ''
            local target = GetEntityCoords(vehicle)
            local distance = #(target - coords)

            if plate:upper():gsub('%s+', '') == wanted and distance <= 60.0 then
                SetEntityAsMissionEntity(vehicle, true, true)
                DeleteVehicle(vehicle)
                removed = true
                break
            end
        end
    end

    if removed then
        notify(('%s towed to the impound lot.'):format(wanted))
    else
        notify(('%s logged as impounded (the car is not nearby).'):format(wanted))
    end
end)

-- ---------------------------------------------------------------------------
-- Pursuits, PIT and spike strips
-- ---------------------------------------------------------------------------

local function clearPursuitBlip()
    if pursuitBlip and DoesBlipExist(pursuitBlip) then RemoveBlip(pursuitBlip) end
    pursuitBlip = nil
end

local function addPursuitBlip()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    pursuitBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(pursuitBlip, 143)
    SetBlipColour(pursuitBlip, 1)
    SetBlipScale(pursuitBlip, 1.0)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Pursuit')
    EndTextCommandSetBlipName(pursuitBlip)
end

RegisterNetEvent('fk_police:client:pursuit', function(state)
    pursuit = type(state) == 'table' and state or { active = false }

    if pursuit.active then
        if not pursuitBlip then addPursuitBlip() end

        notify('Pursuit running. /pit to spin a car, /spikes to deploy.')
    else
        clearPursuitBlip()
    end
end)

RegisterCommand('pit', function()
    if not pursuit.active then return notify('Start a pursuit first (/pursuit).') end

    local target = vehicleAhead()

    if not target or target == 0 then return notify('No car in front to PIT.') end

    local driver = GetPedInVehicleSeat(target, -1)

    if driver and driver ~= 0 then
        -- A PIT spins the rear quarter: heading changes, speed drops, the game
        -- takes over from there.
        SetEntityHeading(target, GetEntityHeading(target) + 35.0)
        SetVehicleForwardSpeed(target, math.max(2.0, GetEntitySpeed(target) * 0.55))
        notify('PIT.')
    end
end, false)

RegisterCommand('spikes', function()
    if not Config.Field or not Config.Field.spikes then return notify('Spike strips are disabled.') end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local x = coords.x + forward.x * 4.0
    local y = coords.y + forward.y * 4.0
    local model = GetHashKey('p_ld_stinger_s')

    RequestModel(model)

    local waited = 0

    while not HasModelLoaded(model) and waited < 3000 do
        Wait(100)
        waited = waited + 100
    end

    if not HasModelLoaded(model) then return notify('Could not load the spike strip.') end

    local object = CreateObject(model, x, y, coords.z - 0.9, true, true, false)

    SetModelAsNoLongerNeeded(model)

    if DoesEntityExist(object) then SetEntityHeading(object, GetEntityHeading(ped)) end

    if not DoesEntityExist(object) then return notify('Could not place the spike strip.') end

    notify('Spikes deployed. They will burst tyres for two minutes.')

    CreateThread(function()
        local expires = GetGameTimer() + (tonumber(Config.Field.spikeSeconds) or 120) * 1000

        while GetGameTimer() < expires do
            Wait(300)

            local strip = GetEntityCoords(object)

            for _, vehicle in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(vehicle) then
                    local target = GetEntityCoords(vehicle)
                    local dx = target.x - strip.x
                    local dy = target.y - strip.y

                    if math.sqrt(dx * dx + dy * dy) < 2.6 and GetEntitySpeed(vehicle) > 2.0 then
                        for wheel = 0, 7 do
                            if not IsVehicleTyreBurst(vehicle, wheel, false) then
                                SetVehicleTyreBurst(vehicle, wheel, true, 1000.0)
                            end
                        end
                    end
                end
            end
        end

        if DoesEntityExist(object) then
            SetEntityAsMissionEntity(object, false, true)
            DeleteEntity(object)
        end
    end)
end, false)

-- ---------------------------------------------------------------------------
-- MDT: bundle, drafts and the new callbacks
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_police:client:mdt', function(bundle)
    SendNUIMessage({ action = 'mdt', bundle = bundle })
end)

RegisterNetEvent('fk_police:client:reportDraft', function(title)
    openComputer()

    SendNUIMessage({ action = 'reportDraft', title = title })
end)

RegisterNetEvent('fk_police:client:field', function(kind, result)
    SendNUIMessage({ action = 'field', kind = kind, result = result })
end)

RegisterNUICallback('refresh', function(_, cb)
    TriggerServerEvent('fk_police:server:mdt')
    cb({ ok = true })
end)

RegisterNUICallback('bolo', function(data, cb)
    TriggerServerEvent('fk_police:server:bolo:add', tostring(data.kind or 'vehicle'), tostring(data.value or ''),
        tostring(data.reason or ''), tonumber(data.minutes))
    cb({ ok = true })
end)

RegisterNUICallback('boloClear', function(data, cb)
    TriggerServerEvent('fk_police:server:bolo:clear', tostring(data.id or ''))
    cb({ ok = true })
end)

RegisterNUICallback('report', function(data, cb)
    TriggerServerEvent('fk_police:server:report:file', {
        kind = data.kind,
        title = data.title,
        body = data.body,
        subjects = data.subjects,
        plate = data.plate,
        charges = data.charges,
    })
    cb({ ok = true })
end)

RegisterNUICallback('fineCollect', function(data, cb)
    TriggerServerEvent('fk_police:server:fine:collect', tostring(data.id or ''), tonumber(data.amount))
    cb({ ok = true })
end)

RegisterNUICallback('fineContest', function(data, cb)
    TriggerServerEvent('fk_police:server:fine:contest', tostring(data.id or ''))
    cb({ ok = true })
end)

RegisterNUICallback('fineWaive', function(data, cb)
    TriggerServerEvent('fk_police:server:fine:waive', tostring(data.id or ''), tostring(data.reason or ''))
    cb({ ok = true })
end)

RegisterNUICallback('impoundRelease', function(data, cb)
    TriggerServerEvent('fk_police:server:impound:release', tostring(data.id or ''))
    cb({ ok = true })
end)

RegisterNUICallback('warrantIssue', function(data, cb)
    TriggerServerEvent('fk_police:server:warrant:issue', {
        person = data.person,
        charge = data.charge,
        note = data.note,
        days = tonumber(data.days),
    })
    cb({ ok = true })
end)

RegisterNUICallback('warrantRevoke', function(data, cb)
    TriggerServerEvent('fk_police:server:warrant:revoke', tostring(data.id or ''))
    cb({ ok = true })
end)

RegisterNUICallback('pursuit', function(data, cb)
    if data.action == 'end' then
        TriggerServerEvent('fk_police:server:pursuit:end', tostring(data.outcome or 'terminated'))
    else
        TriggerServerEvent('fk_police:server:pursuit:start')
    end

    cb({ ok = true })
end)

RegisterNUICallback('field', function(data, cb)
    TriggerServerEvent('fk_police:server:field', tostring(data.tool or 'frisk'), data.name)
    cb({ ok = true })
end)

RegisterNUICallback('impound', function(data, cb)
    TriggerServerEvent('fk_police:server:impound', tostring(data.reason or ''))
    cb({ ok = true })
end)

RegisterNUICallback('labSubmit', function(data, cb)
    TriggerServerEvent('fk_police:server:lab', tostring(data.kind or 'dna'), data.person)
    cb({ ok = true })
end)

RegisterNUICallback('bailPost', function(data, cb)
    TriggerServerEvent('fk_police:server:bail', tonumber(data.amount), tostring(data.note or ''))
    cb({ ok = true })
end)

RegisterNUICallback('courtAttend', function(data, cb)
    TriggerServerEvent('fk_police:server:court', 'attend', tostring(data.id or ''))
    cb({ ok = true })
end)

RegisterNUICallback('hotlistAdd', function(data, cb)
    TriggerServerEvent('fk_police:server:hotlist', 'add', tostring(data.plate or ''), tonumber(data.minutes),
        tostring(data.reason or ''))
    cb({ ok = true })
end)

RegisterNUICallback('hotlistClear', function(data, cb)
    TriggerServerEvent('fk_police:server:hotlist', 'clear', tostring(data.id or data.plate or ''))
    cb({ ok = true })
end)

-- ---------------------------------------------------------------------------
-- Speed cameras: the patrol car reports its position and speed to the server
-- ---------------------------------------------------------------------------
-- The server owns the camera list, the cooldown and the ticket; this thread
-- only says "I am here, going this fast, in this plate".
CreateThread(function()
    while true do
        Wait(1000)

        if status.onDuty then
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)

            if vehicle and vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
                local coords = GetEntityCoords(vehicle)

                TriggerServerEvent('fk_police:server:camera', {
                    x = coords.x,
                    y = coords.y,
                    z = coords.z,
                    speed = GetEntitySpeed(vehicle),
                    plate = GetVehicleNumberPlateText(vehicle),
                })
            end
        end
    end
end)

RegisterNetEvent('fk_police:client:camera', function(result)
    if not result or not result.ticketed then return end

    notify(('Camera %s: %d km/h in a %d zone. Ticket %s ($%d) is on the fine ledger.'):format(
        tostring(result.label or result.camera), tonumber(result.kmh) or 0, tonumber(result.limitKmh) or 0,
        tostring(result.fine), math.floor(tonumber(result.amount) or 0)))

    SendNUIMessage({ action = 'camera', result = result })
end)

RegisterNetEvent('fk_police:client:lab', function(sample)
    if not sample or not sample.result then return end

    notify(('Lab: %s - %s'):format(tostring(sample.label or sample.kind), tostring(sample.result.detail)))
    SendNUIMessage({ action = 'labResult', sample = sample })
end)

CreateThread(function()
    while true do
        Wait(1000)

        if backupState and backupState.at then
            local left = math.max(0, (backupState.eta or 10) - math.floor((GetGameTimer() - backupState.at) / 1000))

            backupState.remaining = left

            if left <= 0 then backupState = nil end
        end
    end
end)
