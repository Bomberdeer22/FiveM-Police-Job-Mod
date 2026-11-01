--[[
    fk_spawn — client/main.lua
    ---------------------------------------------------------------------------
    Plays the spawn: fade out, load the interior, teleport, settle on the floor,
    short establishing shot, fade in. Also hosts /spawn, /spawnset and the
    first-join handshake with the server.
]]

local spawns          -- last list received from the server
local defaultName     -- name of the default point
local spawning = false
local lastSpawnAt = 0

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

local function chatRunning()
    return GetResourceState('chat') == 'started'
end

local function notify(message)
    message = tostring(message)

    if Config.Notify.mode ~= 'feed' and chatRunning() then
        TriggerEvent('chat:addMessage', {
            color = { 120, 200, 255 },
            args = { Config.Notify.prefix, message },
        })
        return
    end

    SetNotificationTextEntry('STRING')
    AddTextComponentSubstringPlayerName(('[%s] %s'):format(Config.Notify.prefix, message))
    DrawNotification(false, true)
end

local function notifyLines(text)
    for line in tostring(text):gmatch('[^\n]+') do
        notify(line)
    end
end

-- ---------------------------------------------------------------------------
-- Spawn list from the server
-- ---------------------------------------------------------------------------

local function requestSpawns()
    TriggerServerEvent('fk_spawn:server:requestSpawns')
end

RegisterNetEvent('fk_spawn:client:spawns', function(points, default)
    spawns = type(points) == 'table' and points or {}
    defaultName = default or Config.DefaultSpawn

    if Config.Debug then
        print(('[fk_spawn] received %d spawn point(s), default: %s')
            :format(#spawns, tostring(defaultName)))
    end
end)

RegisterNetEvent('fk_spawn:client:notify', function(message)
    notify(message)
end)

RegisterNetEvent('fk_spawn:client:list', function(text)
    notifyLines(text)
end)

-- nil = the server has not answered yet
local pendingSpawn = nil

RegisterNetEvent('fk_spawn:client:spawnPending', function(pending)
    pendingSpawn = pending == true
end)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Load the interior the spawn point belongs to (Michael's house MLO).
local function loadInterior(point)
    local definition = point.interior and Config.Interiors and Config.Interiors[point.interior]
    local coords = definition and Spawn.parseCoords(definition.coords)

    local x = coords and coords.x or point.x
    local y = coords and coords.y or point.y
    local z = coords and coords.z or point.z

    local interiorId = GetInteriorAtCoords(x, y, z)

    if interiorId ~= 0 then
        LoadInterior(interiorId)
        RefreshInterior(interiorId)
    end

    return interiorId
end

--- Drop the ped onto the floor below/above the configured z.
local function groundZ(point)
    if not Config.Spawn.groundSnap then return point.z end

    local range = Config.Spawn.groundSnapRange or 3.0

    local hit, found = GetGroundZFor_3dCoords(point.x, point.y, point.z + range, false)

    if not hit then
        hit, found = GetGroundZFor_3dCoords(point.x, point.y, point.z - range, false)
    end

    if hit and found and math.abs(found - point.z) <= range then
        return found
    end

    return point.z
end

local function leaveVehicle()
    local ped = PlayerPedId()

    if not IsPedInAnyVehicle(ped, false) then return end

    local vehicle = GetVehiclePedIsIn(ped, false)
    TaskLeaveVehicle(ped, vehicle, 16)

    local waited = 0
    while IsPedInAnyVehicle(ped, false) and waited < 1500 do
        Wait(50)
        waited = waited + 50
    end
end

local function startIntroCamera(point)
    if not Config.Spawn.cinematic then return nil end

    local rad = math.rad(point.w or 0.0)
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        point.x + math.sin(rad) * 2.1,
        point.y - math.cos(rad) * 2.1,
        point.z + 0.95,
        0.0, 0.0, 0.0,
        Config.Spawn.cinematicFov or 55.0,
        false, 0)

    PointCamAtCoord(cam, point.x, point.y, point.z + 0.45)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    return cam
end

local function stopIntroCamera(cam)
    if not cam then return end

    RenderScriptCams(false, true, 900, true, true)
    Wait(900)

    SetCamActive(cam, false)
    DestroyCam(cam, true)
end

--- Clear vehicles and peds sitting on the spawn point.
local function clearArea(point)
    if not Config.Spawn.clearArea then return end

    ClearAreaOfVehicles(point.x, point.y, point.z, 3.0, false, false, false, false, false)
    ClearAreaOfPeds(point.x, point.y, point.z, 1.5, 0)
end

-- ---------------------------------------------------------------------------
-- The spawn itself
-- ---------------------------------------------------------------------------

local function doSpawn(point)
    if type(point) ~= 'table' or spawning then return false end

    spawning = true
    lastSpawnAt = GetGameTimer()

    -- Watchdog: if a native hiccups halfway through, never leave the player
    -- frozen behind a black screen.
    CreateThread(function()
        local startedAt = GetGameTimer()

        while spawning and (GetGameTimer() - startedAt) < 15000 do
            Wait(500)
        end

        if not spawning then return end

        spawning = false
        RenderScriptCams(false, false, 0, true, true)
        DoScreenFadeIn(400)
        FreezeEntityPosition(PlayerPedId(), false)
        SetPlayerControl(PlayerId(), true, false)
        print('[fk_spawn] spawn timed out, controls restored')
    end)

    local playerId = PlayerId()
    local fadeOut = Config.Spawn.fadeOutTime or 500

    DoScreenFadeOut(fadeOut)
    Wait((Config.Spawn.fadeWait or 700))

    SetPlayerControl(playerId, false, false)

    local ped = PlayerPedId()
    if Config.Spawn.freeze then FreezeEntityPosition(ped, true) end

    leaveVehicle()
    clearArea(point)

    if Config.Spawn.shutdownLoadingScreen then
        ShutdownLoadingScreen()

        if type(ShutdownLoadingScreenNui) == 'function' then
            ShutdownLoadingScreenNui()
        end
    end

    loadInterior(point)

    local targetZ = point.z
    local settled = false
    local snapped = false
    local attempts = math.max(1, math.floor((Config.Spawn.freezeTime or 2000) / 60))

    for _ = 1, attempts do
        ped = PlayerPedId()

        if IsEntityDead(ped) then
            NetworkResurrectLocalPlayer(point.x, point.y, targetZ, point.w or 0.0, true, false)
            Wait(100)
            ped = PlayerPedId()
        end

        SetEntityCoordsNoOffset(ped, point.x, point.y, targetZ, false, false, false)
        SetEntityHeading(ped, point.w or 0.0)
        RequestCollisionAtCoord(point.x, point.y, targetZ)
        Wait(60)

        if HasCollisionLoadedAroundEntity(ped) then
            settled = true

            -- The floor is only measurable once the collision is streaming,
            -- so the snap happens after the first successful placement.
            if not snapped and Config.Spawn.groundSnap then
                snapped = true
                local floorZ = groundZ(point)

                if math.abs(floorZ - targetZ) > 0.05 then
                    targetZ = floorZ
                    SetEntityCoordsNoOffset(ped, point.x, point.y, targetZ, false, false, false)
                    Wait(100)
                end
            end

            break
        end
    end

    ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    ClearPedBloodDamage(ped)
    SetEntityCollision(ped, true, true)

    local cam = startIntroCamera(point)

    DoScreenFadeIn(Config.Spawn.fadeInTime or 600)

    if cam then
        Wait(Config.Spawn.cinematicTime or 2200)
        stopIntroCamera(cam)
    else
        Wait(300)
    end

    FreezeEntityPosition(PlayerPedId(), false)
    SetPlayerControl(playerId, true, false)

    TriggerServerEvent('fk_spawn:server:spawned', point.name, point.x, point.y, targetZ)

    if not settled and Config.Debug then
        print('[fk_spawn] collision did not confirm around the spawn point')
    end

    spawning = false
    return true
end

RegisterNetEvent('fk_spawn:client:doSpawn', function(point)
    doSpawn(point)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

RegisterCommand(Config.Commands.spawn or 'spawn', function(_, args)
    if spawning then return end
    TriggerServerEvent('fk_spawn:server:requestSpawn', args and args[1] or nil)
end, false)

RegisterCommand(Config.Commands.spawnSet or 'spawnset', function(_, args)
    if spawning then return end

    local name = args and args[1]
    if not name or name == '' then
        name = defaultName or Config.DefaultSpawn
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    TriggerServerEvent('fk_spawn:server:setSpawn', name, coords.x, coords.y, coords.z, GetEntityHeading(ped))
end, false)

-- ---------------------------------------------------------------------------
-- First join
-- ---------------------------------------------------------------------------

CreateThread(function()
    -- Let the game finish loading the ped before asking for anything.
    while not NetworkIsPlayerActive(PlayerId()) do Wait(200) end
    Wait(500)

    requestSpawns()

    if not Config.Spawn.onJoin then return end

    -- The server tracks who just joined, so restarting this resource never
    -- yanks somebody who is already playing back home.
    TriggerServerEvent('fk_spawn:server:isSpawnPending')

    local waited = 0
    while pendingSpawn == nil and waited < 3000 do
        Wait(150)
        waited = waited + 150
    end

    local shouldSpawn = pendingSpawn

    if shouldSpawn == nil then
        -- No answer (older server, or the event raced the connection).
        shouldSpawn = LocalPlayer.state.fkSpawnPending == true
    end

    if not shouldSpawn then return end

    if LocalPlayer.state and LocalPlayer.state.set then
        LocalPlayer.state:set('fkSpawnPending', false, true)
    end

    if Config.Spawn.shutdownLoadingScreen then
        ShutdownLoadingScreen()

        if type(ShutdownLoadingScreenNui) == 'function' then
            ShutdownLoadingScreenNui()
        end
    end

    TriggerServerEvent('fk_spawn:server:requestSpawn')
end)

-- Optional: bounce back to the spawn point after dying.
if Config.Spawn.respawnOnDeath then
    AddEventHandler('playerSpawned', function()
        if spawning or (GetGameTimer() - lastSpawnAt) < 5000 then return end
        TriggerServerEvent('fk_spawn:server:requestSpawn')
    end)
end
