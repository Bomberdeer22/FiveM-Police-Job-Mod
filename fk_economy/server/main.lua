--[[
    fk_economy — server/main.lua
    ---------------------------------------------------------------------------
    The authoritative money API. The client can never set its own balance:
    every read/write goes through these functions, and staff actions are
    re-validated here even though the menu already hides them.

    Exports (call from any other resource):
        local money            = exports.fk_economy:GetMoney(src)            -- { cash = , bank = }
        local cash             = exports.fk_economy:GetBalance(src, 'cash')
        local ok, newBal, err  = exports.fk_economy:AddMoney(src, 'cash', 500, 'Payroll')
        local ok, newBal, err  = exports.fk_economy:RemoveMoney(src, 'bank', 200, 'Fine')
        local ok, newBal, err  = exports.fk_economy:SetMoney(src, 'cash', 1000, 'Correction')
        local price            = exports.fk_economy:GetPrice('bodycam')
        local canAfford        = exports.fk_economy:CanAfford(src, 'bodycam', 2)
        local ok, newBal, err  = exports.fk_economy:TryPurchase(src, 'bodycam', 1, 'cash')
        local prices           = exports.fk_economy:GetPrices()               -- whole item table

    Events fired server-side (listen with AddEventHandler):
        'fk_economy:server:moneyChanged' (src, account, delta, newBalance, reason)
]]

local RESOURCE = GetCurrentResourceName()

local STAFF_IDENTIFIERS = {}
for _, id in ipairs(Config.Staff.identifiers or {}) do
    STAFF_IDENTIFIERS[string.lower(id)] = true
end

-- vMenu grants its staff their powers through ACE permissions, so "is this
-- person a vMenu admin?" is answered with IsPlayerAceAllowed on vMenu's own
-- permission nodes (see Config.Staff.vmenu).
local VMENU_PERMISSIONS = {}
do
    local vmenu = Config.Staff.vmenu
    if vmenu and vmenu.enabled ~= false then
        local seen = {}
        local function add(list)
            for _, node in ipairs(list or {}) do
                if type(node) == 'string' and node ~= '' and not seen[node] then
                    seen[node] = true
                    VMENU_PERMISSIONS[#VMENU_PERMISSIONS + 1] = node
                end
            end
        end

        add(vmenu.permissions)
        if vmenu.includeModerators then
            add(vmenu.moderatorPermissions)
        end
        add(vmenu.extraPermissions)
    end
end

-- ---------------------------------------------------------------------------
-- Player helpers
-- ---------------------------------------------------------------------------

--- Resolve the canonical storage identifier for a player.
--- @param src number server id
--- @return string|nil
local function identifierFor(src)
    local identifiers = GetPlayerIdentifiers(src) or {}
    local fallback
    for _, id in ipairs(identifiers) do
        if id:sub(1, 8) == 'license:' then return id end
        fallback = fallback or id
    end
    -- No identifiers means the player is not connected. Never invent an
    -- account for an offline id, otherwise a typo in a staff command would
    -- silently create a phantom balance.
    return fallback
end

local function displayName(src)
    return GetPlayerName(src) or ('Player %d'):format(src)
end

--- Get the account table for a player.
--- @param src number
--- @return table|nil account
--- @return string|nil identifier
function GetPlayerAccount(src)
    if not src or src < 1 then return nil end
    local identifier = identifierFor(src)
    if not identifier then return nil end
    local account = AccountStore.get(identifier, displayName(src))
    return account, identifier
end

--- Normalise anything a script might pass as "a player" into an account.
--- Accepts a server id (number/numeric string) or an identifier string.
--- @return table|nil account, string|nil identifier, string|nil name, number|nil src
local function resolveTarget(target)
    if type(target) == 'number' or (type(target) == 'string' and target:match('^%d+$')) then
        local src = tonumber(target)
        if src and src > 0 then
            local account, identifier = GetPlayerAccount(src)
            if account then
                return account, identifier, displayName(src), src
            end
        end
        return nil
    end

    if type(target) == 'string' and target ~= '' then
        local account = AccountStore.get(target, nil)
        if account then
            return account, target, account.name or target, nil
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- State sync
-- ---------------------------------------------------------------------------

--- Work out whether a player may use the staff tools, and *why*.
--- Checks, in order: the economy ACE, the identifier allowlist, then vMenu.
--- @param src number|nil
--- @return boolean isStaff
--- @return string|nil source   'console' | 'ace' | 'identifier' | 'vmenu'
--- @return string|nil matched  the permission node / identifier that matched
function CheckStaff(src)
    if not src or src < 1 then
        return Config.Staff.allowConsole == true, 'console', nil
    end

    -- 1. fk_economy's own permission
    if IsPlayerAceAllowed(src, Config.Staff.ace) then
        return true, 'ace', Config.Staff.ace
    end

    -- 2. Hard-coded identifier allowlist (config.lua)
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if STAFF_IDENTIFIERS[string.lower(id)] then
            return true, 'identifier', id
        end
    end

    -- 3. vMenu admins: their staff status is stored as ACE permissions
    for _, node in ipairs(VMENU_PERMISSIONS) do
        if IsPlayerAceAllowed(src, node) then
            return true, 'vmenu', node
        end
    end

    return false, nil, nil
end

--- Is this player allowed to use the staff tools?
--- @param src number
--- @return boolean
function IsStaff(src)
    return CheckStaff(src) == true
end

--- Push the current balances to a player's HUD/menu.
--- @param src number
function PushState(src)
    if not src or src < 1 then return end
    local account = GetPlayerAccount(src)
    if not account then return end

    local balances = {}
    for _, key in ipairs(EnabledAccounts()) do
        balances[key] = account[key] or 0
    end

    TriggerClientEvent('fk_economy:client:state', src, {
        balances = balances,
        staff    = IsStaff(src),
        accounts = EnabledAccounts(),
        name     = displayName(src),
    })
end

-- ---------------------------------------------------------------------------
-- Money API
-- ---------------------------------------------------------------------------

--- Apply a signed delta to one account, honouring limits and stats.
--- @return boolean ok, number|string balanceOrError
local function applyDelta(account, key, delta, reason)
    if not account then return false, 'no_account' end
    if not IsValidAccount(key) then return false, 'invalid_account' end
    if type(delta) ~= 'number' or delta ~= delta or delta == 0 then return false, 'invalid_amount' end

    local current = account[key] or 0
    local newBalance = RoundMoney(current + delta)

    if newBalance < 0 then
        return false, 'insufficient_funds'
    end

    if newBalance > Config.Limits.maxBalance then
        newBalance = Config.Limits.maxBalance
    end

    account[key] = newBalance
    if delta > 0 then
        account.earned = (account.earned or 0) + delta
    else
        account.spent = (account.spent or 0) + math.abs(delta)
    end

    AccountStore.markDirty()
    return true, newBalance
end

--- Add money to a player (or an offline identifier).
--- @param target number|string server id or identifier
--- @param account string 'cash' | 'bank'
--- @param amount number positive amount
--- @param reason string|nil
--- @param actor string|nil who did it (for the audit log)
--- @return boolean ok, number|string newBalanceOrError, string|nil error
function AddMoney(target, account, amount, reason, actor)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false, 'invalid_amount', 'invalid_amount' end
    if not IsValidAccount(account) then return false, 'invalid_account', 'invalid_account' end

    local acc, identifier, name, src = resolveTarget(target)
    if not acc then return false, 'no_target', 'no_target' end

    local ok, result = applyDelta(acc, account, RoundMoney(amount), reason)
    if not ok then return false, result, result end

    if src then PushState(src) end
    TriggerEvent('fk_economy:server:moneyChanged', src, account, amount, result, reason)
    AccountStore.log(actor or 'system', name or identifier, account, amount, reason)
    return true, result
end

--- Remove money from a player (fails if they cannot afford it).
--- @return boolean ok, number|string newBalanceOrError, string|nil error
function RemoveMoney(target, account, amount, reason, actor)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false, 'invalid_amount', 'invalid_amount' end
    if not IsValidAccount(account) then return false, 'invalid_account', 'invalid_account' end

    local acc, identifier, name, src = resolveTarget(target)
    if not acc then return false, 'no_target', 'no_target' end

    local ok, result = applyDelta(acc, account, -RoundMoney(amount), reason)
    if not ok then return false, result, result end

    if src then PushState(src) end
    TriggerEvent('fk_economy:server:moneyChanged', src, account, -amount, result, reason)
    AccountStore.log(actor or 'system', name or identifier, account, -amount, reason)
    return true, result
end

--- Force a balance, used for corrections. Never goes below zero.
--- @return boolean ok, number|string newBalanceOrError, string|nil error
function SetMoney(target, account, amount, reason, actor)
    amount = tonumber(amount)
    if not amount or amount < 0 then return false, 'invalid_amount', 'invalid_amount' end
    if not IsValidAccount(account) then return false, 'invalid_account', 'invalid_account' end

    local acc, identifier, name, src = resolveTarget(target)
    if not acc then return false, 'no_target', 'no_target' end

    local newBalance = Clamp(RoundMoney(amount), 0, Config.Limits.maxBalance)
    local delta = newBalance - (acc[account] or 0)
    acc[account] = newBalance
    if delta > 0 then
        acc.earned = (acc.earned or 0) + delta
    elseif delta < 0 then
        acc.spent = (acc.spent or 0) + math.abs(delta)
    end
    AccountStore.markDirty()

    if src then PushState(src) end
    TriggerEvent('fk_economy:server:moneyChanged', src, account, delta, newBalance, reason)
    AccountStore.log(actor or 'system', name or identifier, account, delta, reason or 'set')
    return true, newBalance
end

--- Read one balance.
--- @return number balance (0 when the player/account is unknown)
function GetBalance(src, account)
    local acc = GetPlayerAccount(src)
    if not acc or not IsValidAccount(account) then return 0 end
    return acc[account] or 0
end

--- Snapshot of every enabled balance for a player.
--- @return table|nil { cash = 0, bank = 0 }
function GetMoney(src)
    local acc = GetPlayerAccount(src)
    if not acc then return nil end
    local out = {}
    for _, key in ipairs(EnabledAccounts()) do
        out[key] = acc[key] or 0
    end
    return out
end

--- Can a player afford a total in the chosen account?
function CanAfford(src, item, quantity, account)
    local price = GetItemPrice(item)
    if price <= 0 then return false end
    local total = price * math.max(1, math.floor(tonumber(quantity) or 1))
    return GetBalance(src, account or 'cash') >= total
end

--- Charge a player for an item, respecting its configured price.
--- The price always comes from config so the client can never spoof it.
--- @param src number
--- @param item string item key from Config.Items
--- @param quantity number|nil
--- @param account string|nil 'cash' (default) or 'bank'
--- @param reason string|nil
--- @return boolean ok, number|string newBalanceOrError, string|nil error
function Purchase(src, item, quantity, account, reason)
    local entry = Config.Items[item]
    if not entry then return false, 'unknown_item', 'unknown_item' end

    local price = tonumber(entry.price) or 0
    if price <= 0 then return false, 'not_for_sale', 'not_for_sale' end

    quantity = math.max(1, math.floor(tonumber(quantity) or 1))
    local total = RoundMoney(price * quantity)

    return RemoveMoney(src, account or 'cash', total, reason or ('purchase:%s x%d'):format(item, quantity))
end

-- ---------------------------------------------------------------------------
-- Exports — the API the main police mod will use
-- ---------------------------------------------------------------------------

exports('GetMoney', GetMoney)
exports('GetBalance', GetBalance)
exports('AddMoney', function(target, account, amount, reason)
    local ok, result = AddMoney(target, account, amount, reason, 'export')
    return ok, result
end)
exports('RemoveMoney', function(target, account, amount, reason)
    local ok, result = RemoveMoney(target, account, amount, reason, 'export')
    return ok, result
end)
exports('SetMoney', function(target, account, amount, reason)
    local ok, result = SetMoney(target, account, amount, reason, 'export')
    return ok, result
end)
exports('CanAfford', function(src, item, quantity, account)
    return CanAfford(src, item, quantity, account)
end)
exports('TryPurchase', function(src, item, quantity, account, reason)
    local ok, result = Purchase(src, item, quantity, account, reason)
    return ok, result
end)
exports('GetPrice', function(item)
    return GetItemPrice(item)
end)
exports('GetPrices', function()
    return Config.Items
end)
exports('GetAccounts', function()
    return EnabledAccounts()
end)
exports('IsStaff', function(src)
    return IsStaff(src)
end)
exports('GetStaffAccess', function(src)
    local allowed, source, matched = CheckStaff(src)
    return {
        staff   = allowed,
        source  = source,
        matched = matched,
    }
end)
exports('GetVMenuPermissions', function()
    return VMENU_PERMISSIONS
end)
exports('GetAccountStats', function(src)
    local acc = GetPlayerAccount(src)
    if not acc then return nil end
    return {
        cash      = acc.cash or 0,
        bank      = acc.bank or 0,
        earned    = acc.earned or 0,
        spent     = acc.spent or 0,
        firstSeen = acc.firstSeen,
        lastSeen  = acc.lastSeen,
    }
end)

-- ---------------------------------------------------------------------------
-- Net events
-- ---------------------------------------------------------------------------

--- Client asks for its state (on spawn / resource restart / menu open).
RegisterNetEvent('fk_economy:server:requestState', function()
    local src = tonumber(source)
    if not src or src < 1 then return end
    PushState(src)
end)

--- Staff menu asks for the online player list.
RegisterNetEvent('fk_economy:server:requestPlayers', function()
    local src = tonumber(source)
    if not src or src < 1 then return end
    if not IsStaff(src) then return end

    local players = {}
    for _, id in ipairs(GetPlayers()) do
        local serverId = tonumber(id)
        if serverId then
            -- Balances are included so staff can see the target's current
            -- money before adjusting it. Only staff ever see this event.
            local account = GetPlayerAccount(serverId)
            local balances = {}
            if account then
                for _, key in ipairs(EnabledAccounts()) do
                    balances[key] = account[key] or 0
                end
            end

            players[#players + 1] = {
                id       = serverId,
                name     = displayName(serverId),
                isMe     = serverId == src,
                balances = balances,
            }
        end
    end
    table.sort(players, function(a, b) return a.id < b.id end)

    TriggerClientEvent('fk_economy:client:playerList', src, players)
end)

--- Staff menu: give or take money. Everything is re-checked here.
RegisterNetEvent('fk_economy:server:staffAction', function(payload)
    local src = tonumber(source)
    if not src or src < 1 then return end

    local function fail(message)
        TriggerClientEvent('fk_economy:client:staffResult', src, { ok = false, message = message })
    end

    if not IsStaff(src) then
        return fail('You do not have permission to do that.')
    end

    if type(payload) ~= 'table' then
        return fail('Malformed request.')
    end

    local mode    = payload.mode
    local account = payload.account
    local amount  = tonumber(payload.amount)
    local target  = tonumber(payload.target)
    local reason  = tostring(payload.reason or 'Staff adjustment'):sub(1, 64)

    if mode ~= 'add' and mode ~= 'remove' then
        return fail('Unknown action.')
    end
    if not IsValidAccount(account) then
        return fail('Unknown account.')
    end
    if not amount or amount <= 0 or amount ~= amount or amount == math.huge then
        return fail('Enter a valid amount.')
    end

    amount = RoundMoney(amount)
    if amount < (Config.Limits.minAmount or 1) then
        return fail('Amount is below the minimum.')
    end
    if amount > Config.Staff.maxPerAction then
        return fail(('Amount is above the %s per-action limit.')
            :format(FormatMoney(Config.Staff.maxPerAction)))
    end
    if not target or target < 1 then
        return fail('Select a player first.')
    end
    if not GetPlayerName(target) then
        return fail('That player is no longer online.')
    end

    local actor = ('%s (%d)'):format(displayName(src), src)
    local ok, result, err

    if mode == 'add' then
        ok, result, err = AddMoney(target, account, amount, reason, actor)
    else
        ok, result, err = RemoveMoney(target, account, amount, reason, actor)
    end

    if not ok then
        if err == 'insufficient_funds' then
            return fail(('%s does not have enough %s.')
                :format(displayName(target), account))
        end
        return fail('That did not work (' .. tostring(err) .. ').')
    end

    local verb = mode == 'add' and 'Added' or 'Removed'
    local message = ('%s %s %s %s'):format(verb, FormatMoney(amount),
        account, mode == 'add' and ('to ' .. displayName(target)) or ('from ' .. displayName(target)))

    TriggerClientEvent('fk_economy:client:staffResult', src, {
        ok      = true,
        message = message,
        target  = target,
    })

    -- Tell the affected player what happened, so nobody is silently taxed.
    TriggerClientEvent('fk_economy:client:notify', target, {
        title   = mode == 'add' and 'Money Received' or 'Money Taken',
        message = ('%s %s (%s)'):format(mode == 'add' and '+' or '-', FormatMoney(amount), reason),
        kind    = mode == 'add' and 'success' or 'error',
    })
end)

-- ---------------------------------------------------------------------------
-- Player lifecycle
-- ---------------------------------------------------------------------------

local lastDropSave = 0

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src or src < 1 then return end

    local account = GetPlayerAccount(src)
    if account then
        account.lastSeen = os.time()
        AccountStore.markDirty()

        -- Flush on drop so a crash cannot lose money, but throttle it so a
        -- wave of disconnects does not rewrite the file dozens of times.
        local now = os.time()
        if now - lastDropSave >= 2 then
            lastDropSave = now
            AccountStore.save()
        end
    end
end)

-- Initialise the account as soon as a player connects so the HUD never has to
-- wait on a lazy create.
AddEventHandler('playerJoining', function()
    local src = tonumber(source)
    if not src or src < 1 then return end
    pcall(GetPlayerAccount, src)
end)
