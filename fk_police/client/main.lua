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

    if not callout then return end

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

local function vehicleAhead()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local maxDistance = (Config.Traffic or {}).maxDistance or 25.0
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
    })
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
RegisterCommand('backup_code3', function()
    TriggerServerEvent('fk_police:server:backup', 'code3')
end, false)

RegisterKeyMapping('backup_code3', 'Request backup (code 3)', 'keyboard', 'F11')
RegisterKeyMapping('callout', 'Accept callout', 'keyboard', 'Y')

CreateThread(function()
    Wait(3000)
    stationBlips()
end)
