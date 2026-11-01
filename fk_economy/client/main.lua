--[[
    fk_economy — client/main.lua
    ---------------------------------------------------------------------------
    Thin client layer:
      * loads/saves the player's HUD layout (client KVP)
      * pushes state + config into the NUI page
      * opens the customisation / staff menu with the configured key

    No money logic lives here — the server is authoritative.
]]

local RESOURCE = GetCurrentResourceName()
local KVP_SETTINGS = 'fk_economy:settings'

local menuOpen = false
local currentState = nil

-- ---------------------------------------------------------------------------
-- Settings (per player, stored on their machine)
-- ---------------------------------------------------------------------------

local function defaults()
    local d = Config.UI.default
    return {
        visible = d.visible ~= false,
        x       = d.x or 1.0,
        y       = d.y or 78.0,
        scale   = d.scale or 1.0,
        opacity = d.opacity or 1.0,
        compact = d.compact == true,
    }
end

local function clampSettings(s)
    local out = defaults()
    if type(s) ~= 'table' then return out end

    out.visible = s.visible ~= false
    out.compact = s.compact == true
    out.x = Clamp(tonumber(s.x) or out.x, 0.0, 100.0)
    out.y = Clamp(tonumber(s.y) or out.y, 0.0, 100.0)
    out.scale = Clamp(tonumber(s.scale) or out.scale, Config.UI.minScale, Config.UI.maxScale)
    out.opacity = Clamp(tonumber(s.opacity) or out.opacity, Config.UI.minOpacity, Config.UI.maxOpacity)
    return out
end

local function loadSettings()
    local raw = GetResourceKvpString(KVP_SETTINGS)
    if not raw or raw == '' then return defaults() end
    local ok, decoded = pcall(json.decode, raw)
    if not ok then return defaults() end
    return clampSettings(decoded)
end

local function saveSettings(settings)
    local clean = clampSettings(settings)
    SetResourceKvp(KVP_SETTINGS, json.encode(clean))
    return clean
end

local settings = loadSettings()

-- ---------------------------------------------------------------------------
-- NUI plumbing
-- ---------------------------------------------------------------------------

local function send(payload)
    SendNUIMessage(payload)
end

local function configPayload()
    local accounts = {}
    for _, key in ipairs(EnabledAccounts()) do
        accounts[#accounts + 1] = { id = key, label = Config.Accounts[key].label or key }
    end

    return {
        resource = RESOURCE,
        currency = Config.Currency,
        locale   = Config.Locale,
        accent   = Config.UI.accent,
        accounts = accounts,
        items    = Config.Items,
        limits   = {
            minScale   = Config.UI.minScale,
            maxScale   = Config.UI.maxScale,
            minOpacity = Config.UI.minOpacity,
            maxOpacity = Config.UI.maxOpacity,
            maxPerAction = Config.Staff.maxPerAction,
        },
        staff = {
            reasons = Config.Staff.reasons,
            quickAmounts = Config.Staff.quickAmounts,
            enabled = currentState and currentState.staff or false,
        },
        key       = Config.Keys.menu,
        animations = Config.UI.animateChanges ~= false,
        tweenMs   = Config.UI.numberTweenMs or 650,
        edgeSnapPx = Config.UI.edgeSnapPx or 0,
        showDeltaFloat = Config.UI.showDeltaFloat ~= false,
        hideWhenDead = Config.UI.hideWhenDead == true,
    }
end

local function pushState()
    if not currentState then return end
    send({
        action   = 'state',
        balances = currentState.balances,
        staff    = currentState.staff,
        name     = currentState.name,
    })
end

local function pushSettings()
    send({ action = 'settings', settings = settings })
end

local function requestState()
    TriggerServerEvent('fk_economy:server:requestState')
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local function setMenu(open)
    open = open == true
    menuOpen = open
    SetNuiFocus(open, open)
    send({ action = 'menu', open = open })

    if open then
        pushSettings()
        pushState()
        if currentState and currentState.staff then
            TriggerServerEvent('fk_economy:server:requestPlayers')
        end
    end
end

RegisterCommand('economyMenu', function()
    if IsPauseMenuActive() then return end
    setMenu(not menuOpen)
end, false)

RegisterKeyMapping('economyMenu', 'Open Economy Menu / HUD Customiser', 'keyboard', Config.Keys.menu)

-- Showing the menu via a command is handy for other scripts / keybinds.
RegisterCommand('economy', function()
    setMenu(true)
end, false)

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_economy:client:state', function(payload)
    if type(payload) ~= 'table' then return end
    currentState = payload
    pushState()
    send({ action = 'staffAccess', staff = payload.staff == true })
end)

RegisterNetEvent('fk_economy:client:playerList', function(players)
    send({ action = 'players', players = players or {} })
end)

RegisterNetEvent('fk_economy:client:staffResult', function(result)
    send({ action = 'staffResult', result = result })
end)

RegisterNetEvent('fk_economy:client:notify', function(notification)
    send({ action = 'notify', notification = notification })
    if type(notification) == 'table' and notification.title then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(('%s — %s'):format(notification.title, notification.message or ''))
        EndTextCommandThefeedPostTicker(false, true)
    end
end)

--- Force a refresh (other resources can call this after granting money).
exports('Refresh', requestState)
exports('OpenMenu', function() setMenu(true) end)
exports('CloseMenu', function() setMenu(false) end)

-- ---------------------------------------------------------------------------
-- NUI callbacks
-- ---------------------------------------------------------------------------

RegisterNUICallback('ready', function(_, cb)
    send({ action = 'init', config = configPayload(), settings = settings })
    pushState()
    requestState()
    cb({ ok = true })
end)

RegisterNUICallback('close', function(_, cb)
    setMenu(false)
    cb({ ok = true })
end)

--- Re-arm focus/state if the page (re)claims the menu.
RegisterNUICallback('menuOpened', function(_, cb)
    if not menuOpen then
        setMenu(true)
    end
    cb({ ok = true })
end)

--- Lightweight balance refresh (no UI rebuild).
RegisterNUICallback('refresh', function(_, cb)
    requestState()
    cb({ ok = true })
end)

RegisterNUICallback('saveSettings', function(data, cb)
    settings = saveSettings(data and data.settings or {})
    pushSettings()
    cb({ ok = true, settings = settings })
end)

RegisterNUICallback('resetSettings', function(_, cb)
    settings = saveSettings(defaults())
    pushSettings()
    cb({ ok = true, settings = settings })
end)

RegisterNUICallback('requestPlayers', function(_, cb)
    TriggerServerEvent('fk_economy:server:requestPlayers')
    cb({ ok = true })
end)

RegisterNUICallback('staffAction', function(data, cb)
    if type(data) ~= 'table' then
        return cb({ ok = false })
    end
    TriggerServerEvent('fk_economy:server:staffAction', {
        mode    = data.mode,
        account = data.account,
        amount  = data.amount,
        target  = data.target,
        reason  = data.reason,
    })
    cb({ ok = true })
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

CreateThread(function()
    Wait(250)
    requestState()

    -- If the server never answers (resource restarted, script error, slow join)
    -- keep asking, so the HUD appears as soon as it can instead of staying
    -- hidden until the player reconnects.
    for _ = 1, 8 do
        Wait(5000)
        if currentState then return end
        requestState()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    if menuOpen then
        SetNuiFocus(false, false)
    end
end)

AddEventHandler('playerSpawned', function()
    requestState()
end)

-- Hide the HUD while the game's own pause menu is up.
CreateThread(function()
    local wasOpen = false
    while true do
        local pause = IsPauseMenuActive()
        if pause ~= wasOpen then
            wasOpen = pause
            send({ action = 'pause', open = pause })
        end
        Wait(300)
    end
end)

-- Optional: hide the HUD while the player is dead (Config.UI.hideWhenDead).
CreateThread(function()
    local wasDead = false
    while true do
        if Config.UI.hideWhenDead then
            local dead = IsEntityDead(PlayerPedId())
            if dead ~= wasDead then
                wasDead = dead
                send({ action = 'dead', dead = dead })
            end
            Wait(500)
        else
            Wait(2000)
        end
    end
end)
