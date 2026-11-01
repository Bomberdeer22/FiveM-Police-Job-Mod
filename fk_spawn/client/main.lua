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
local joinSpawnDone = false

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

--- Is there a ped we can actually move yet?
local function hasPed()
    local ped = PlayerPedId()
    return ped ~= 0 and DoesEntityExist(ped)
end

local function distanceTo(ped, x, y, z)
    local coords = GetEntityCoords(ped)
    local dx, dy, dz = coords.x - x, coords.y - y, coords.z - z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Move the ped and keep insisting: on join the game is still finishing its own
--- spawn and can drag the player back to the default location a moment later.
local function placePed(point, z)
    for _ = 1, 6 do
        local ped = PlayerPedId()

        if ped ~= 0 and DoesEntityExist(ped) then
            if IsEntityDead(ped) then
                NetworkResurrectLocalPlayer(point.x, point.y, z, point.w or 0.0, true, false)
            else
                SetEntityCoordsNoOffset(ped, point.x, point.y, z, false, false, false)
                SetEntityHeading(ped, point.w or 0.0)
            end

            RequestCollisionAtCoord(point.x, point.y, z)
        end

        Wait(300)

        ped = PlayerPedId()

        if ped ~= 0 and DoesEntityExist(ped) and distanceTo(ped, point.x, point.y, z) < 12.0 then
            return true
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- The spawn itself
-- ---------------------------------------------------------------------------

local function doSpawn(point)
    if type(point) ~= 'table' or spawning then return false end

    spawning = true
    lastSpawnAt = GetGameTimer()

    notify(('Waking you up in %s…'):format(point.label or point.name or 'your spawn point'))

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

    -- Without a ped the teleport goes nowhere at all.
    local waited = 0
    while not hasPed() and waited < 15000 do
        Wait(100)
        waited = waited + 100
    end

    loadInterior(point)

    local targetZ = point.z
    local placed = placePed(point, targetZ)

    -- Wait for the world before measuring the floor.
    local attempts = math.max(1, math.floor((Config.Spawn.freezeTime or 2000) / 60))

    for _ = 1, attempts do
        local current = PlayerPedId()

        if current ~= 0 and DoesEntityExist(current) and HasCollisionLoadedAroundEntity(current) then
            break
        end

        Wait(60)
    end

    if Config.Spawn.groundSnap then
        local floorZ = groundZ(point)

        if math.abs(floorZ - targetZ) > 0.05 then
            targetZ = floorZ
            placePed(point, targetZ)
        end
    end

    -- Hold the spot until the game stops fighting us: the engine's own initial
    -- spawn can land *after* our teleport on slow joins and drag the player
    -- back to the default location. Two clean checks in a row = we won.
    local stable = 0

    for _ = 1, 10 do
        local current = PlayerPedId()
        stable = 0

        if current ~= 0 and DoesEntityExist(current) then
            if distanceTo(current, point.x, point.y, targetZ) > 8.0 then
                placePed(point, targetZ)
            else
                stable = stable + 1
                if stable >= 2 then break end
            end
        end

        Wait(300)
    end

    local finalPed = PlayerPedId()

    if finalPed ~= 0 and DoesEntityExist(finalPed) then
        ClearPedTasksImmediately(finalPed)
        ClearPedBloodDamage(finalPed)
        SetEntityCollision(finalPed, true, true)
    end

    if not placed and Config.Debug then
        print('[fk_spawn] could not confirm the player at the spawn point')
    end

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

    if Config.Debug then
        local current = PlayerPedId()
        print(('[fk_spawn] placed at %.2f, %.2f, %.2f (target %.2f, %.2f, %.2f)')
            :format(GetEntityCoords(current).x, GetEntityCoords(current).y, GetEntityCoords(current).z,
                point.x, point.y, targetZ))
    end

    TriggerServerEvent('fk_spawn:server:spawned', point.name, point.x, point.y, targetZ)

    if not settled and Config.Debug then
        print('[fk_spawn] collision did not confirm around the spawn point')
    end

    spawning = false
    joinSpawnDone = true
    return true
end

RegisterNetEvent('fk_spawn:client:doSpawn', function(point, isJoin)
    -- The server keeps pushing until we confirm; ignore the repeats.
    if isJoin and joinSpawnDone then return end

    if doSpawn(point) and isJoin then
        joinSpawnDone = true
    end
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

--- /spawnstatus — what this client believes, printed to chat (works without
--- the F8 console) and to the F8 console for the record.
RegisterCommand('spawnstatus', function()
    local ped = PlayerPedId()
    local coords = ped ~= 0 and GetEntityCoords(ped) or { x = 0.0, y = 0.0, z = 0.0 }
    local point = defaultName and Spawn and Spawn.resolve(spawns or {}, defaultName) or nil
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'

    local lines = {
        ('fk_spawn v%s | points=%d | default=%s')
            :format(version, #(spawns or {}), tostring(defaultName)),
        ('pending=%s | spawning=%s | done=%s')
            :format(tostring(pendingSpawn), tostring(spawning), tostring(joinSpawnDone)),
        ('you are at %.2f, %.2f, %.2f')
            :format(coords.x, coords.y, coords.z),
    }

    if point then
        lines[#lines + 1] = ('target %s: %.2f, %.2f, %.2f (heading %.0f)')
            :format(point.name, point.x, point.y, point.z, point.w or 0.0)
    end

    for _, line in ipairs(lines) do
        print('[fk_spawn] ' .. line)
        notify(line)
    end
end, false)

-- ---------------------------------------------------------------------------
-- First join
-- ---------------------------------------------------------------------------

CreateThread(function()
    print('[fk_spawn] client ready')

    -- Let the game finish loading the ped before asking for anything.
    while not NetworkIsPlayerActive(PlayerId()) do Wait(200) end
    Wait(Config.Spawn.joinDelay or 1200)

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

    if not shouldSpawn then
        -- The server also pushes the spawn on join, so this is only the fast
        -- path; nothing to do if it says no.
        print('[fk_spawn] no spawn pending (player was already online)')
        return
    end

    print('[fk_spawn] spawning at ' .. tostring(defaultName or Config.DefaultSpawn))

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
