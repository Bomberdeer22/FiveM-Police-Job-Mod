--[[
    fk_house — client/garage.lua
    ---------------------------------------------------------------------------
    The player's side of the garage: the card options, parking detection, the
    "personal vehicle" flags that stop the car being culled at distance, and the
    garage door.

    The vehicle itself is created by the server (server/garage.lua); this file
    only decorates it once it is streamed in.
]]

local saved = nil          -- { model, plate, appearance, savedAt } from the server
local liveNet = nil        -- net id of the car we are tracking
local liveEntity = 0
local lastVehicle = 0      -- vehicle we last sat in
local wasInGarage = false  -- were we inside the garage when we got in?
local spawnAskedAt = 0     -- GetGameTimer() of the last automatic spawn request
local announceSpawned = false -- has the player been told the car is out this session
local doorOpen = nil

local function cfg()
    return Config.Garage or {}
end

local function notify(message)
    message = tostring(message)

    if GetResourceState('chat') == 'started' then
        TriggerEvent('chat:addMessage', {
            color = { 120, 200, 255 },
            args = { Config.UI.title, message },
        })
        return
    end

    SetNotificationTextEntry('STRING')
    AddTextComponentSubstringPlayerName(('[%s] %s'):format(Config.UI.title, message))
    DrawNotification(false, true)
end

local function garageCoords()
    return cfg().coords
end

--- Inside the garage (or within `extra` metres of it)?
local function nearGarage(coords, extra)
    return Garage.inZone(coords, garageCoords(), (cfg().radius or 6.0) + (extra or 0.0))
end

-- ---------------------------------------------------------------------------
-- Personal vehicle flags
-- ---------------------------------------------------------------------------

--- Marks the car as ours so the engine never treats it as an abandoned prop:
--- mission entity + owned by player + a huge culling radius.
local function applyPersonalFlags(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    -- One pcall each: if a native is missing on an older build, the others
    -- still run. Losing the mission-entity flag would be the bad one.
    pcall(function() SetEntityAsMissionEntity(veh, true, true) end)
    pcall(function() SetVehicleHasBeenOwnedByPlayer(veh, true) end)
    pcall(function() SetVehicleNeedsToBeHotwired(veh, false) end)
    pcall(function() SetVehicleDirtLevel(veh, 0.0) end)
    pcall(function() SetEntityDistanceCullingRadius(veh, cfg().cullDistance or 4000.0) end)

    if saved and saved.plate then
        pcall(function() SetVehicleNumberPlateText(veh, saved.plate) end)
    end
end

-- ---------------------------------------------------------------------------
-- Appearance: paint, wheels, mods and extras
-- ---------------------------------------------------------------------------
-- Read off the real car when it is parked and put back when it is created
-- again, so the car that returns is the one you left, not a showroom model.

local MOD_SLOTS = 48 -- 0..47 are normal mods; 18/bool and 20 are toggles

local function collectAppearance(veh)
    local appearance = {}

    local ok = pcall(function()
        local primary, secondary = GetVehicleColours(veh)
        appearance.colors = { primary = primary, secondary = secondary }

        local r, g, b = GetVehicleCustomPrimaryColour(veh)

        if r and g and b and (r > 0 or g > 0 or b > 0) then
            appearance.colors.custom = { r = r, g = g, b = b }
        end

        appearance.tint = GetVehicleWindowTint(veh)
        appearance.wheelType = GetVehicleWheelType(veh)

        local mods = {}

        for slot = 0, MOD_SLOTS do
            local index = GetVehicleMod(veh, slot)

            if slot == 18 or slot == 20 then
                mods[slot] = IsToggleModOn(veh, slot) and 1 or 0
            elseif index and index >= 0 then
                mods[slot] = index
            end
        end

        if next(mods) then appearance.mods = mods end

        local extras = {}

        for extra = 1, 20 do
            if DoesExtraExist(veh, extra) then
                extras[extra] = IsVehicleExtraTurnedOn(veh, extra) and 1 or 0
            end
        end

        if next(extras) then appearance.extras = extras end
    end)

    if not ok then return nil end

    return appearance
end

local function applyAppearance(veh, appearance)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if type(appearance) ~= 'table' then return end

    pcall(function()
        if type(appearance.colors) == 'table' then
            SetVehicleColours(veh, appearance.colors.primary or 0, appearance.colors.secondary or 0)

            local custom = appearance.colors.custom

            if type(custom) == 'table' then
                SetVehicleCustomPrimaryColour(veh, custom.r or 0, custom.g or 0, custom.b or 0)
                SetVehicleCustomSecondaryColour(veh, custom.r or 0, custom.g or 0, custom.b or 0)
            end
        end

        if appearance.wheelType then SetVehicleWheelType(veh, appearance.wheelType) end

        if type(appearance.mods) == 'table' then
            SetVehicleModKit(veh, 0)

            for slot, index in pairs(appearance.mods) do
                if slot == 18 or slot == 20 then
                    ToggleVehicleMod(veh, slot, index ~= 0)
                else
                    SetVehicleMod(veh, slot, index, false)
                end
            end
        end

        if type(appearance.extras) == 'table' then
            for extra, on in pairs(appearance.extras) do
                SetVehicleExtra(veh, extra, on == 0)
            end
        end

        if appearance.tint then SetVehicleWindowTint(veh, appearance.tint) end
    end)
end

--- Resolve the net id into an entity, or nil while it is not streamed (which is
--- normal when the player is on the other side of the map - the server keeps
--- the car alive either way).
local function resolveVehicle()
    if not liveNet then return nil end
    if not NetworkDoesNetworkIdExist(liveNet) then return nil end

    local veh = NetToVeh(liveNet)

    if veh == 0 or not DoesEntityExist(veh) then return nil end

    return veh
end

local function trackVehicle(netId)
    liveNet = netId
    liveEntity = 0

    CreateThread(function()
        local deadline = GetGameTimer() + 15000

        while GetGameTimer() < deadline do
            local veh = resolveVehicle()

            if veh then
                -- If the car was created before the garage interior finished
                -- streaming it can end up under the floor: put it back.
                local spawn = cfg().spawn or {}
                local coords = GetEntityCoords(veh)

                if spawn.z and coords.z < (spawn.z - 2.0) then
                    SetEntityCoords(veh, spawn.x, spawn.y, spawn.z + 0.2, false, false, false, false)
                end

                pcall(function() SetVehicleOnGroundProperly(veh) end)
                applyAppearance(veh, saved and saved.appearance)
                applyPersonalFlags(veh)

                return
            end

            Wait(200)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Card options (called from client/main.lua)
-- ---------------------------------------------------------------------------

--- @return table array of { label, hint, action }
function GarageMenuOptions()
    local options = {}

    if saved then
        options[#options + 1] = {
            label = 'Bring my car out',
            hint = ('%s · %s'):format(saved.model, saved.plate or ''),
            action = 'garage_spawn',
        }
        options[#options + 1] = {
            label = 'Park a different car here',
            hint = 'Replaces the saved one',
            action = 'garage_park',
        }
        options[#options + 1] = {
            label = 'Forget this car',
            hint = 'Removes it from the garage',
            action = 'garage_forget',
        }
    else
        options[#options + 1] = {
            label = 'Park the car I am next to',
            hint = 'The model is saved for next login',
            action = 'garage_park',
        }
    end

    options[#options + 1] = {
        label = 'Where is my car?',
        hint = saved and ('%s in the garage'):format(saved.model) or 'Nothing stored',
        action = 'garage_info',
    }

    return options
end

local function nearestVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    if veh ~= 0 then return veh end

    local coords = GetEntityCoords(ped)
    local closest = GetClosestVehicle(coords.x, coords.y, coords.z, 8.0, 0, 70)

    return closest or 0
end

local function parkVehicle(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return notify('Stand next to a car (or sit in it) and try again.')
    end

    local coords = GetEntityCoords(veh)

    if not nearGarage(coords) then
        return notify('That car is not inside the garage.')
    end

    local model = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    local plate = GetVehicleNumberPlateText(veh)
    local appearance = cfg().appearance ~= false and collectAppearance(veh) or nil

    TriggerServerEvent('fk_house:server:garage:park', VehToNet(veh), model, plate, appearance)
end

--- Runs a garage card action. Called from selectOption in client/main.lua.
function GarageAction(option)
    local action = type(option) == 'table' and option.action or nil

    if action == 'garage_spawn' then
        -- The server confirms with the net id a moment later; say so now so the
        -- card never looks like it did nothing.
        if saved and not liveNet then
            notify(('Bringing your %s out…'):format(saved.model or 'car'))
        end

        TriggerServerEvent('fk_house:server:garage:spawn')
    elseif action == 'garage_park' then
        parkVehicle(nearestVehicle())
    elseif action == 'garage_forget' then
        TriggerServerEvent('fk_house:server:garage:forget')
    elseif action == 'garage_info' then
        if not saved then
            notify('No car is stored yet — drive one into the garage, get out, and it saves itself.')
            return
        end

        local state = liveNet and 'It is out in the world with you.'
            or 'It is waiting in the garage.'

        notify(('Your %s (%s). %s'):format(saved.model, saved.plate or 'no plate', state))
    end
end

-- ---------------------------------------------------------------------------
-- Forklift duties: notice when a car is left in the garage
-- ---------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(800)

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local coords = GetEntityCoords(ped)
        local inside = nearGarage(coords)

        if veh ~= 0 then
            lastVehicle = veh
            wasInGarage = inside
        elseif lastVehicle ~= 0 then
            local candidate = lastVehicle

            lastVehicle = 0

            if wasInGarage and DoesEntityExist(candidate) and nearGarage(GetEntityCoords(candidate)) then
                local model = GetDisplayNameFromVehicleModel(GetEntityModel(candidate))

                -- Only save when it is a different car from the stored one, so
                -- getting in and out repeatedly does not spam the server.
                if not saved or Garage.normalizeModel(model) ~= saved.model then
                    parkVehicle(candidate)
                    Wait(2000)
                end
            end

            wasInGarage = false
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Ask the server for the car once we are near the house
-- ---------------------------------------------------------------------------

CreateThread(function()
    Wait(4000)
    TriggerServerEvent('fk_house:server:garage:request')

    while true do
        Wait(60000)
        TriggerServerEvent('fk_house:server:garage:request')
    end
end)

CreateThread(function()
    while true do
        Wait(3000)

        -- Ask at most every 30 s. The server answers with the net id when the
        -- car is out (or with a one-off message when it truly failed), so a
        -- retry loop here must not turn into a wall of red chat.
        if saved and (GetGameTimer() - spawnAskedAt) > 30000 then
            local coords = GetEntityCoords(PlayerPedId())
            local distance = House.distance(coords, garageCoords())

            if distance and distance <= (cfg().spawnDistance or 80.0) then
                spawnAskedAt = GetGameTimer()
                TriggerServerEvent('fk_house:server:garage:spawn')
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Keep the flags on the car
-- ---------------------------------------------------------------------------

CreateThread(function()
    local lastFlags = 0
    local raised = false
    local missingSince = 0

    while true do
        Wait(2000)

        local veh = resolveVehicle()

        if veh then
            missingSince = 0

            if not raised then
                raised = true

                local spawn = cfg().spawn or {}
                local coords = GetEntityCoords(veh)

                if spawn.z and coords.z < (spawn.z - 2.0) then
                    SetEntityCoords(veh, spawn.x, spawn.y, spawn.z + 0.2, false, false, false, false)
                    pcall(function() SetVehicleOnGroundProperly(veh) end)
                end
            end

            if veh ~= liveEntity or (GetGameTimer() - lastFlags) > 10000 then
                liveEntity = veh
                lastFlags = GetGameTimer()
                applyPersonalFlags(veh)
            end
        elseif liveNet then
            -- Not streamed (normal when you are across the map). Only give up
            -- on the net id after a full minute, then ask what is stored now.
            if missingSince == 0 then missingSince = GetGameTimer() end

            if (GetGameTimer() - missingSince) > 60000 then
                missingSince = 0
                liveNet = nil
                liveEntity = 0
                TriggerServerEvent('fk_house:server:garage:request')
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Garage door
-- ---------------------------------------------------------------------------

CreateThread(function()
    local door = cfg().door

    if not door or door.enabled == false or type(door.coords) ~= 'table' then return end

    local model = GetHashKey(door.model or 'prop_ld_garaged_01')
    local x, y, z = door.coords.x, door.coords.y, door.coords.z
    local openWithin = House.toNumber(door.openWithin) or 12.0

    while true do
        Wait(1000)

        local coords = GetEntityCoords(PlayerPedId())
        local distance = House.distance(coords, { x = x, y = y, z = z })
        local wantOpen = distance ~= nil and distance <= openWithin

        if wantOpen ~= doorOpen then
            doorOpen = wantOpen

            pcall(function()
                SetStateOfClosestDoorOfType(model, x, y, z, not wantOpen, 0.0, wantOpen)
            end)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Server data
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_house:client:garage:state', function(state)
    local previous = saved
    saved = type(state) == 'table' and state or nil

    if not saved then
        liveNet = nil
        liveEntity = 0
        spawnAskedAt = 0
    elseif not previous or previous.model ~= saved.model or previous.plate ~= saved.plate then
        -- A different car is stored now, so it is worth bringing it out at once.
        spawnAskedAt = 0
    end

    -- Keep an open garage card in step with what the server just said.
    if type(HouseRefreshMenu) == 'function' then HouseRefreshMenu() end
end)

RegisterNetEvent('fk_house:client:garage:spawned', function(netId, state)
    if type(state) == 'table' then saved = state end

    spawnAskedAt = GetGameTimer()

    if type(netId) == 'number' then
        trackVehicle(netId)

        if not announceSpawned then
            announceSpawned = true
            notify(('Your %s is in the garage.'):format(saved and saved.model or 'car'))
        end
    end

    if type(HouseRefreshMenu) == 'function' then HouseRefreshMenu() end
end)

-- ---------------------------------------------------------------------------
-- /mycar — no F8 needed, everything lands in chat
-- ---------------------------------------------------------------------------

RegisterCommand('mycar', function()
    if not saved then
        return notify('No car saved. Drive one into Michael\'s garage, get out, and it saves itself.')
    end

    local line = ('Saved: %s (%s).'):format(saved.model, saved.plate or 'no plate')

    if liveNet and NetworkDoesNetworkIdExist(liveNet) then
        local veh = NetToVeh(liveNet)

        if veh ~= 0 and DoesEntityExist(veh) then
            local distance = House.distance(GetEntityCoords(PlayerPedId()), GetEntityCoords(veh))
            line = ('%s It is %.0f m away.'):format(line, distance or -1)
        end
    else
        line = ('%s It is in the garage (walk up to the garage to bring it out).'):format(line)
    end

    notify(line)
end, false)
