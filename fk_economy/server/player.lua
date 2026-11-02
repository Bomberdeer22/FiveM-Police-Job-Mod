--[[
    fk_economy — server/player.lua
    ---------------------------------------------------------------------------
    The vPlayer class: one object per player account, and the only place a
    balance or an item count is ever changed.

    Why a class: the police mod, shops and the staff menu all move money. One
    choke point means one place to validate an amount, apply the ceiling, update
    the earned/spent totals, keep the owner's statebag in sync and write the
    audit line. Nothing calls account[key] = x directly any more.

    It holds a reference to the account table owned by AccountStore, so a
    VPlayer is always live — never take a copy and write it back.
]]

VPlayer = {}
VPlayer.__index = VPlayer

--- @param identifier string
--- @param account table from AccountStore
--- @return table vPlayer
function VPlayer.new(identifier, account)
    return setmetatable({
        identifier = identifier,
        account = account,
    }, VPlayer)
end

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

--- @return number
function VPlayer:Get(key)
    return self.account[key] or 0
end

--- @return table { cash = 0, bank = 0 }
function VPlayer:Balances()
    local out = {}

    for _, key in ipairs(EnabledAccounts()) do
        out[key] = self.account[key] or 0
    end

    return out
end

--- @return boolean
function VPlayer:CanAfford(key, amount)
    amount = tonumber(amount)

    if not amount or amount <= 0 then return false end

    return self:Get(key) >= amount
end

--- Apply a signed delta to one account.
--- @return boolean ok, number|string balanceOrError
function VPlayer:Apply(key, delta, reason)
    if not IsValidAccount(key) then return false, 'invalid_account' end

    delta = tonumber(delta)

    if not delta or delta ~= delta or delta == 0 then return false, 'invalid_amount' end

    local newBalance = RoundMoney(self:Get(key) + delta)

    if newBalance < 0 then return false, 'insufficient_funds' end

    if newBalance > Config.Limits.maxBalance then
        newBalance = Config.Limits.maxBalance
    end

    self.account[key] = newBalance

    if delta > 0 then
        self.account.earned = (self.account.earned or 0) + math.abs(delta)
    else
        self.account.spent = (self.account.spent or 0) + math.abs(delta)
    end

    AccountStore.markDirty()
    return true, newBalance
end

--- Force a balance (corrections, staff tools).
--- @return boolean ok, number|string balanceOrError
function VPlayer:SetBalance(key, value, reason)
    if not IsValidAccount(key) then return false, 'invalid_account' end

    value = tonumber(value)

    if not value or value < 0 then return false, 'invalid_amount' end

    local newBalance = Clamp(RoundMoney(value), 0, Config.Limits.maxBalance)
    local delta = newBalance - self:Get(key)

    self.account[key] = newBalance

    if delta > 0 then
        self.account.earned = (self.account.earned or 0) + delta
    elseif delta < 0 then
        self.account.spent = (self.account.spent or 0) + math.abs(delta)
    end

    AccountStore.markDirty()
    return true, newBalance
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

--- @return table items
function VPlayer:Items()
    return AccountStore.items(self.account)
end

--- @return number
function VPlayer:ItemCount(item)
    return self:Items()[item] or 0
end

--- @return boolean
function VPlayer:HasItem(item, quantity)
    return self:ItemCount(item) >= math.max(1, math.floor(tonumber(quantity) or 1))
end

--- @return number maxStack
function VPlayer:MaxStack()
    local owned = Config.ItemsOwned or {}

    return math.max(1, math.floor(tonumber(owned.maxStack) or 99))
end

--- Give an item. Used by purchases and by staff/other resources.
--- @return boolean ok, number|string countOrError
function VPlayer:AddItem(item, quantity)
    if type(item) ~= 'string' or item == '' then return false, 'invalid_item' end

    quantity = math.floor(tonumber(quantity) or 1)

    if quantity < 1 then return false, 'invalid_amount' end

    local items = self:Items()
    local newCount = math.min(self:MaxStack(), (items[item] or 0) + quantity)

    items[item] = newCount
    AccountStore.markDirty()

    return true, newCount
end

--- Take an item away. Fails when the player does not have that many.
--- @return boolean ok, number|string countOrError
function VPlayer:RemoveItem(item, quantity)
    if type(item) ~= 'string' or item == '' then return false, 'invalid_item' end

    quantity = math.floor(tonumber(quantity) or 1)

    if quantity < 1 then return false, 'invalid_amount' end

    local items = self:Items()
    local current = items[item] or 0

    if current < quantity then return false, 'not_owned' end

    local newCount = current - quantity

    if newCount <= 0 then
        items[item] = nil
    else
        items[item] = newCount
    end

    AccountStore.markDirty()
    return true, newCount
end

--- Should buying this item put it in the player's inventory?
--- Services and vehicles are consumed at the till; equipment and licences are
--- things you own. Categories are set in Config.Items.
--- @return boolean
function VPlayer.StoresItem(item)
    local owned = Config.ItemsOwned

    if not owned or owned.enabled == false then return false end

    local entry = Config.Items[item]

    if type(entry) ~= 'table' then return false end
    if entry.ownable == false then return false end
    if entry.ownable == true then return true end

    local skip = owned.skipCategories

    if type(skip) == 'table' and skip[entry.category] then return false end

    return true
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

--- A read-only view for the client, the staff menu or another resource.
--- @return table
function VPlayer:Snapshot()
    local items = {}

    for key, quantity in pairs(self:Items()) do
        items[key] = quantity
    end

    return {
        identifier = self.identifier,
        balances   = self:Balances(),
        items      = items,
        earned     = self.account.earned or 0,
        spent      = self.account.spent or 0,
        firstSeen  = self.account.firstSeen,
        lastSeen   = self.account.lastSeen,
    }
end
