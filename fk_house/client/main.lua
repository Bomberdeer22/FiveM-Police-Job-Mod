--[[
    fk_house — client/main.lua
    ---------------------------------------------------------------------------
    Interaction spots inside Michael's mansion: wardrobe, kitchen, shower, bed
    and living room. Prompts use the native help text, the option list is the
    NUI card in html/.
]]

local spots = {}
local outfits = {}          -- [slot] = outfit, from the server
local menu = nil            -- { spot = spot, options = { ... } }
local busy = false
local markers = false
local tuning = nil          -- { name = spot } while /housetune is live
local sessionOutfit = nil   -- what the player was wearing when they arrived
local lastOutfit = nil      -- last outfit we applied
local pendingPurchase = nil -- food waiting on the economy's answer
local uiReady = false       -- has html/app.js said hello?
local menuOpenedAt = 0      -- GetGameTimer() when the card opened

local COMPONENTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
local PROPS = { 0, 1, 2, 3, 4 }

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

local function chatRunning()
    return GetResourceState('chat') == 'started'
end

local function notify(message)
    message = tostring(message)

    if chatRunning() then
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

local function notifyLines(text)
    for line in tostring(text):gmatch('[^\n]+') do
        notify(line)
    end
end

-- ---------------------------------------------------------------------------
-- Outfits
-- ---------------------------------------------------------------------------

local function captureOutfit()
    local ped = PlayerPedId()
    local outfit = { comps = {}, props = {} }

    for _, component in ipairs(COMPONENTS) do
        outfit.comps[#outfit.comps + 1] = {
            i = component,
            d = GetPedDrawableVariation(ped, component),
            t = GetPedTextureVariation(ped, component),
        }
    end

    for _, prop in ipairs(PROPS) do
        outfit.props[#outfit.props + 1] = {
            i = prop,
            d = GetPedPropIndex(ped, prop),
            t = GetPedPropTextureIndex(ped, prop),
        }
    end

    return outfit
end

local function applyOutfit(outfit)
    if type(outfit) ~= 'table' then return false end

    local ped = PlayerPedId()

    for _, part in ipairs(outfit.comps or {}) do
        SetPedComponentVariation(ped, part.i, part.d, part.t or 0, 0)
    end

    for _, part in ipairs(outfit.props or {}) do
        if part.d and part.d >= 0 then
            SetPedPropIndex(ped, part.i, part.d, part.t or 0, true)
        else
            ClearPedProp(ped, part.i)
        end
    end

    lastOutfit = outfit
    return true
end

-- ---------------------------------------------------------------------------
-- Option lists
-- ---------------------------------------------------------------------------

local function itemPrice(item)
    if type(item) ~= 'string' or GetResourceState('fk_economy') ~= 'started' then return nil end

    local ok, price = pcall(function() return exports.fk_economy:GetPrice(item) end)

    if ok and type(price) == 'number' then return price end

    return nil
end

local function buildOptions(spot)
    local options = {}

    if spot.type == 'wardrobe' then
        local slots = Config.Wardrobe.slots or 3

        for slot = 1, slots do
            local saved = outfits[slot]

            if saved then
                options[#options + 1] = {
                    label = ('Wear outfit %d'):format(slot),
                    hint = House.describeOutfit(saved),
                    action = 'wear',
                    slot = slot,
                }
            else
                options[#options + 1] = {
                    label = ('Save this look to slot %d'):format(slot),
                    hint = 'Empty',
                    action = 'save',
                    slot = slot,
                }
            end
        end

        if sessionOutfit then
            options[#options + 1] = {
                label = 'Put my clothes back on',
                hint = 'What you arrived in',
                action = 'restore',
            }
        end
    elseif spot.type == 'kitchen' then
        for _, option in ipairs(spot.options or {}) do
            local hint = option.description or ''

            if option.item then
                local price = itemPrice(option.item)
                local tag = price and ('$%d'):format(price) or 'paid'

                hint = hint ~= '' and ('%s · %s'):format(hint, tag) or tag
            end

            options[#options + 1] = {
                label = option.label or option.id,
                hint = hint,
                action = 'eat',
                option = option,
            }
        end
    elseif spot.type == 'bed' then
        local sleep = spot.raw and spot.raw.sleep or { hours = 8, health = 100, label = 'Sleep' }
        local nap = spot.raw and spot.raw.nap or { hours = 2, health = 40, label = 'Take a nap' }

        options[#options + 1] = {
            label = sleep.label or ('Sleep %d hours'):format(sleep.hours or 8),
            hint = ('+%d health'):format(sleep.health or 100),
            action = 'sleep',
            config = sleep,
        }
        options[#options + 1] = {
            label = nap.label or 'Take a nap',
            hint = ('+%d health'):format(nap.health or 40),
            action = 'sleep',
            config = nap,
        }
    elseif spot.type == 'shower' then
        options[#options + 1] = {
            label = 'Take a shower',
            hint = 'Clean up and recover',
            action = 'shower',
        }
        options[#options + 1] = {
            label = 'Wash your hands',
            hint = 'Quick freshen up',
            action = 'shower',
            quick = true,
        }
    elseif spot.type == 'sofa' then
        local raw = spot.raw or {}

        options[#options + 1] = {
            label = 'Relax on the sofa',
            hint = ('Recover over %d seconds'):format((raw.regen and raw.regen.seconds) or 30),
            action = 'relax',
            config = raw,
        }
    end

    return options
end

-- ---------------------------------------------------------------------------
-- NUI
-- ---------------------------------------------------------------------------

local function openMenu(spot)
    if spot.type == 'wardrobe' then
        TriggerServerEvent('fk_house:server:requestOutfits')
    end

    local options = buildOptions(spot)

    if #options == 0 then
        return notify('Nothing to do here yet.')
    end

    menu = { spot = spot, options = options }
    menuOpenedAt = GetGameTimer()

    if Config.Debug then
        print(('[fk_house] opening %s with %d option(s)'):format(spot.name, #options))
    end

    local payload = {}

    for index, option in ipairs(options) do
        payload[#payload + 1] = {
            index = index,
            label = option.label,
            hint = option.hint or '',
        }
    end

    SendNUIMessage({
        action = 'show',
        data = {
            title = spot.label,
            subtitle = spot.type == 'wardrobe' and 'Personal wardrobe' or Config.UI.title,
            options = payload,
            footer = Config.UI.footer,
        },
    })
end

local function closeMenu()
    if not menu then return end

    menu = nil
    SendNUIMessage({ action = 'hide' })
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function heal(amount)
    local ped = PlayerPedId()
    local max = GetEntityMaxHealth(ped)
    local current = GetEntityHealth(ped)

    if amount and amount > 0 then
        SetEntityHealth(ped, math.min(max, current + amount))
    else
        SetEntityHealth(ped, max)
    end
end

local function playEatAnimation()
    local food = Config.Food or {}
    local anim = food.animation or { dict = 'mp_player_inteat@burger', clip = 'mp_player_int_eat_burger' }
    local ped = PlayerPedId()

    RequestAnimDict(anim.dict)

    local waited = 0
    while not HasAnimDictLoaded(anim.dict) and waited < 2000 do
        Wait(50)
        waited = waited + 50
    end

    TaskPlayAnim(ped, anim.dict, anim.clip, 4.0, -4.0, (food.duration or 3000), 49, 0.0, false, false, false)
    Wait((food.duration or 3000))

    StopAnimTask(ped, anim.dict, anim.clip, 1.0)
    RemoveAnimDict(anim.dict)
end

local function eat(option)
    local function consume()
        playEatAnimation()
        heal(option.health or 10)
        notify(('That hit the spot. +%d health'):format(option.health or 10))
    end

    if option.item and GetResourceState('fk_economy') == 'started' and Config.Food.chargeItems ~= false then
        pendingPurchase = { option = option }
        TriggerServerEvent('fk_house:server:buy', option.item)
        return
    end

    consume()
end

local function shower(quick, spot)
    local raw = (spot and spot.raw) or {}
    local duration = quick and 2000 or (raw.duration or 5000)

    busy = true
    DoScreenFadeOut(500)
    Wait(600)

    local ped = PlayerPedId()
    ClearPedBloodDamage(ped)

    if ClearPedWetness then
        ClearPedWetness(ped)
    end

    SetEntityHealth(ped, GetEntityMaxHealth(ped))

    Wait(duration - 600)

    DoScreenFadeIn(500)
    Wait(500)
    busy = false

    notify(quick and 'Fresh.' or 'You feel clean again.')
end

local function sleep(config)
    busy = true

    DoScreenFadeOut(Config.Sleep.fade or 1000)
    Wait(Config.Sleep.fade or 1000)

    local hours = config.hours or 8
    local h = GetClockHours() + hours

    if Config.Sleep.timeAdvanceEvent then
        TriggerEvent(Config.Sleep.timeAdvanceEvent, hours)
    else
        NetworkOverrideClockTime(h % 24, 0, 0)
    end

    heal(config.health or 100)

    Wait(1200)
    DoScreenFadeIn(Config.Sleep.fade or 1000)
    Wait(600)

    busy = false
    notify(Config.Sleep.wakeMessage or 'You wake up.')
end

local function relax(config)
    busy = true

    local scene = (config and config.scenario) or 'WORLD_HUMAN_SEAT_BENCH'
    local regen = (config and config.regen) or { seconds = 30 }
    local seconds = regen.seconds or 30
    local ped = PlayerPedId()

    TaskStartScenarioInPlace(ped, scene, 0, true)

    local elapsed = 0

    while elapsed < seconds * 1000 do
        Wait(1000)
        elapsed = elapsed + 1000

        if not IsPedActiveInScenario(PlayerPedId()) then break end

        heal(5)
    end

    ClearPedTasks(PlayerPedId())
    busy = false
    notify('You feel a bit better.')
end

RegisterNetEvent('fk_house:client:buyResult', function(ok, reason, item)
    local purchase = pendingPurchase
    pendingPurchase = nil

    if not purchase then return end

    if not ok then
        local messages = {
            insufficient_funds = 'You cannot afford that.',
            unknown_item = 'That is not for sale.',
            economy_error = 'The till is broken, try again.',
        }

        return notify(messages[reason] or 'You cannot buy that right now.')
    end

    playEatAnimation()
    heal(purchase.option.health or 10)
    notify(('Bought and eaten. +%d health'):format(purchase.option.health or 10))
end)

local function selectOption(index)
    local current = menu
    if not current then return end

    local option = current.options[index]
    if not option then return end

    closeMenu()

    if option.action == 'wear' then
        local outfit = outfits[option.slot]
        if not outfit then return notify('That slot is empty.') end

        busy = true
        DoScreenFadeOut(Config.Wardrobe.fade or 400)
        Wait((Config.Wardrobe.fade or 400) + 100)
        applyOutfit(outfit)
        DoScreenFadeIn(Config.Wardrobe.fade or 400)
        Wait(400)
        busy = false
        notify(('Wearing outfit %d.'):format(option.slot))
    elseif option.action == 'save' then
        local outfit = captureOutfit()
        TriggerServerEvent('fk_house:server:saveOutfit', option.slot, outfit)
    elseif option.action == 'restore' then
        if not sessionOutfit then return notify('You have nothing to change back into.') end

        busy = true
        DoScreenFadeOut(Config.Wardrobe.fade or 400)
        Wait((Config.Wardrobe.fade or 400) + 100)
        applyOutfit(sessionOutfit)
        DoScreenFadeIn(Config.Wardrobe.fade or 400)
        Wait(400)
        busy = false
        notify('Back in your own clothes.')
    elseif option.action == 'eat' then
        eat(option.option or {})
    elseif option.action == 'shower' then
        shower(option.quick, current.spot)
    elseif option.action == 'sleep' then
        sleep(option.config or {})
    elseif option.action == 'relax' then
        relax(option.config)
    end
end

-- ---------------------------------------------------------------------------
-- Help text + markers
-- ---------------------------------------------------------------------------

local function drawHelp(spot)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(('~INPUT_CONTEXT~ %s'):format(spot.label))
    EndTextCommandDisplayHelp(0, false, true, -1)
end

-- ---------------------------------------------------------------------------
-- Floor snapping
-- ---------------------------------------------------------------------------
-- The config coordinates are ped-feet positions taken from the game's own
-- interior data, but floors are not perfectly flat and a couple of centimetres
-- of error makes a marker look like it is floating. Every marker is projected
-- onto the real floor with a short downward probe. Results are cached per spot,
-- so the cost is one probe per spot per 1.5 s.
local floorCache = {}

local function snappedZ(spot)
    local now = GetGameTimer()
    local cached = floorCache[spot.name]

    if cached and (now - cached.at) < 1500 then return cached.z end

    local z = spot.z

    local ok, hit, hitCoords = pcall(function()
        local handle = StartExpensiveSynchronousShapeTestLosProbe(
            spot.x, spot.y, spot.z + 1.5,
            spot.x, spot.y, spot.z - 3.0,
            1, PlayerPedId(), 1)

        local _, didHit, endCoords = GetShapeTestResult(handle)

        return didHit == 1, endCoords
    end)

    if ok and hit and hitCoords and hitCoords.z then
        z = hitCoords.z
    end

    floorCache[spot.name] = { z = z, at = now }

    return z
end

local function roomDebug()
    local ped = PlayerPedId()
    local ok, interior, room = pcall(function()
        return GetInteriorFromEntity(ped), GetRoomKeyFromEntity(ped)
    end)

    if not ok then return 'interior=?, room=?' end

    return ('interior=%s, room=%s'):format(tostring(interior), tostring(room))
end

local function drawSpotLabel(spot)
    local onScreen, x, y = GetScreenCoordFromWorldCoord(spot.x, spot.y, snappedZ(spot) + 1.25)

    if not onScreen then return end

    SetTextScale(0.30, 0.30)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(235, 240, 255, 255)
    SetTextDropshadow(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(('%s  (%s, r%.1f)'):format(spot.name, spot.type, spot.radius))
    DrawText(x, y)
end

local function drawMarkers()
    for _, spot in ipairs(spots) do
        -- Marker sits ON the floor at the spot (the coordinates are ped feet),
        -- so what you see is exactly where you have to stand.
        local floor = snappedZ(spot)

        DrawMarker(1, spot.x, spot.y, floor + 0.02,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            spot.radius, spot.radius, 0.45, 59, 130, 246, 110,
            false, false, 2, false, nil, nil, false)

        DrawMarker(0, spot.x, spot.y, floor + 2.1,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            0.25, 0.25, 0.25, 147, 197, 253, 200,
            false, true, 2, false, nil, nil, false)

        drawSpotLabel(spot)
    end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

CreateThread(function()
    TriggerServerEvent('fk_house:server:requestSpots')
    TriggerServerEvent('fk_house:server:requestOutfits')

    Wait(8000)

    if #spots == 0 then
        notify('fk_house: no spots arrived from the server (see the server console).')
    elseif Config.Debug then
        notify(('fk_house ready: %d spot(s)'):format(#spots))
    end

    -- Re-ask when a player reconnects to the shard mid-session.
    while true do
        Wait(15000)
        TriggerServerEvent('fk_house:server:requestOutfits')
    end
end)

CreateThread(function()
    while true do
        local wait = 500

        if menu then
            wait = 0

            for index = 1, math.min(#menu.options, 9) do
                if IsControlJustPressed(0, 156 + index) then
                    selectOption(index)
                end
            end

            local cancel = false

            for _, control in ipairs(Config.Keys.cancel or { 200 }) do
                if IsControlJustPressed(0, control) then cancel = true break end
            end

            if (GetGameTimer() - menuOpenedAt) > 250 and IsControlJustPressed(0, Config.Keys.interact) then
                cancel = true
            end

            if cancel then closeMenu() end
        end

        if markers then
            wait = 0
            drawMarkers()
        end

        Wait(wait)
    end
end)

-- /housetune: live marker that follows you until you press E.
CreateThread(function()
    while true do
        local wait = 500

        if tuning then
            wait = 0

            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local floor = snappedZ({ name = 'tune', x = coords.x, y = coords.y, z = coords.z })

            DrawMarker(1, coords.x, coords.y, floor + 0.02,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.2, 1.2, 0.5, 250, 204, 21, 140,
                false, false, 2, false, nil, nil, false)

            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(('~INPUT_CONTEXT~ save %s here  ·  ~INPUT_FRONTEND_CANCEL~ cancel')
                :format(tuning.name))
            EndTextCommandDisplayHelp(0, false, true, -1)

            if IsControlJustPressed(0, Config.Keys.interact) then
                TriggerServerEvent('fk_house:server:setSpot', tuning.name, coords.x, coords.y, floor)
                notify(('Saved %s at %.2f, %.2f, %.2f.'):format(tuning.name, coords.x, coords.y, floor))
                tuning = nil
            elseif IsControlJustPressed(0, 194) or IsControlJustPressed(0, 322) then
                notify('Tuning cancelled.')
                tuning = nil
            end
        end

        Wait(wait)
    end
end)

CreateThread(function()
    while true do
        local wait = 750

        if not menu and not busy and not tuning then
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)

            local houseDistance = House.distance(coords, Config.House.coords)

            if houseDistance and houseDistance <= (Config.House.radius or 45.0) then
                local spot = House.nearest(spots, coords, Config.House.zTolerance)

                if spot then
                    wait = 0

                    if Config.UI.showHelp ~= false then
                        drawHelp(spot)
                    end

                    if IsControlJustPressed(0, Config.Keys.interact) then
                        if not sessionOutfit then
                            sessionOutfit = captureOutfit()
                        end

                        if Config.Debug then
                            print(('[fk_house] E pressed at %s'):format(spot.name))
                        end

                        openMenu(spot)
                    end
                end
            end
        end

        Wait(wait)
    end
end)

-- ---------------------------------------------------------------------------
-- NUI handshake
-- ---------------------------------------------------------------------------

RegisterNUICallback('ready', function(_, callback)
    uiReady = true
    print('[fk_house] NUI ready')

    -- Re-open whatever was on screen (the page may have reloaded).
    if menu then
        local spot = menu.spot
        closeMenu()
        openMenu(spot)
    end

    callback({ ok = true })
end)

-- ---------------------------------------------------------------------------
-- Server data
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_house:client:spots', function(incoming)
    spots = type(incoming) == 'table' and incoming or {}
end)

RegisterNetEvent('fk_house:client:outfits', function(incoming)
    outfits = type(incoming) == 'table' and incoming or {}

    -- Keep an open wardrobe in step with what the server just told us.
    if menu and menu.spot and menu.spot.type == 'wardrobe' then
        local spot = menu.spot
        closeMenu()
        openMenu(spot)
    end
end)

RegisterNetEvent('fk_house:client:notify', function(message)
    notify(message)
end)

RegisterNetEvent('fk_house:client:list', function(text)
    notifyLines(text)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

RegisterCommand('housespot', function(_, args)
    local name = args and args[1]

    if not name then
        return notify('Usage: /housespot <name> — stand where you want it first.')
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    TriggerServerEvent('fk_house:server:setSpot', name, coords.x, coords.y, coords.z)
end, false)

RegisterCommand('housemarkers', function()
    markers = not markers
    notify(markers and 'Spot markers on.' or 'Spot markers off.')
end, false)

--- /housedebug — everything needed to work out why a prompt is missing.
RegisterCommand('housedebug', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local houseDistance = House.distance(coords, Config.House.coords)
    local inside = houseDistance ~= nil and houseDistance <= (Config.House.radius or 45.0)
    local tolerance = Config.House.zTolerance or 2.4

    notify(('spots=%d | in house=%s (%.1fm of %.0fm) | ui=%s | menu=%s | busy=%s')
        :format(#spots, tostring(inside), houseDistance or -1, Config.House.radius or 45.0,
            tostring(uiReady), menu and menu.spot.name or 'none', tostring(busy)))

    notify(('you: %.2f, %.2f, %.2f | heading %.0f | %s | floor tolerance %.1fm')
        :format(coords.x, coords.y, coords.z, GetEntityHeading(ped), roomDebug(), tolerance))

    if #spots == 0 then
        return notify('No spots received from the server — check the server console for fk_house errors.')
    end

    local sorted = {}

    for _, spot in ipairs(spots) do
        local distance = House.distance(coords, spot)

        if distance == nil then
            notify(('  %s: coordinates unreadable (%s, %s, %s)')
                :format(spot.name, tostring(spot.x), tostring(spot.y), tostring(spot.z)))
        else
            sorted[#sorted + 1] = { spot = spot, distance = distance, dz = spot.z - coords.z }
        end
    end

    table.sort(sorted, function(a, b) return a.distance < b.distance end)

    for index = 1, math.min(#sorted, 5) do
        local entry = sorted[index]
        local reachable = entry.distance <= entry.spot.radius
            and math.abs(entry.dz) <= tolerance

        notify(('  %s%s — %.1fm away, dz %+.1fm (radius %.1fm)')
            :format(reachable and '> ' or '  ', entry.spot.name, entry.distance,
                entry.dz, entry.spot.radius))
    end

    notify('E inside a radius opens the menu · /housemarkers shows the spots · /housescan prints your position.')
end, false)

--- /housescan — one-line-per-fact report to paste into a message when a spot
--- is still in the wrong place. Nothing here needs the F8 console.
RegisterCommand('housescan', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local floor = snappedZ({ name = 'scan', x = coords.x, y = coords.y, z = coords.z })

    notify(('SCAN pos=%.3f, %.3f, %.3f floor=%.3f heading=%.1f')
        :format(coords.x, coords.y, coords.z, floor, GetEntityHeading(ped)))
    notify(('SCAN %s | house=%.1fm')
        :format(roomDebug(), House.distance(coords, Config.House.coords) or -1))

    for _, spot in ipairs(spots) do
        notify(('SCAN %s=%.1fm (dz %+.1f)')
            :format(spot.name, House.distance(coords, spot) or -1, spot.z - coords.z))
    end
end, false)

--- /housetune <spot> — a marker follows you; press E to save that spot there.
RegisterCommand('housetune', function(_, args)
    local name = args and args[1]

    if not name then
        return notify('Usage: /housetune <spot> — walk to the right place, press E to save.')
    end

    tuning = { name = name:lower() }
    notify(('Tuning %s — stand where you want the marker, press E to save, BACKSPACE to cancel.')
        :format(tuning.name))
end, false)

RegisterCommand('househelp', function()
    notifyLines(table.concat({
        'Walk up to a spot and press E:',
        '  Wardrobe — save and wear your own outfits',
        '  Kitchen — food and drink (paid items come out of your bank)',
        '  Shower — clean up and heal',
        '  Bed — sleep, the clock moves forward',
        '  Living room — relax on the sofa',
        'Staff: /housespot <name> saves your position, /housetune <name> follows you until you press E,',
        '       /housemarkers shows every spot, /housedebug and /housescan explain what the script sees.',
    }, '\n'))
end, false)
