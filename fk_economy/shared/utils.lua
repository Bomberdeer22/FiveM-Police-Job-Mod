--[[
    fk_economy — shared/utils.lua
    Helper functions safe to run on both client and server.
]]

--- Round a number to an integer when Config.Limits.wholeNumbers is enabled.
--- @param value number
--- @return number
function RoundMoney(value)
    value = tonumber(value) or 0
    if Config.Limits.wholeNumbers then
        return math.floor(value + 0.5)
    end
    return math.floor(value * 100 + 0.5) / 100
end

--- Group the integer part of a number with thousands separators.
--- @param value number
--- @return string
local function groupDigits(value)
    local formatted = tostring(value)
    local sign = ''
    if formatted:sub(1, 1) == '-' then
        sign = '-'
        formatted = formatted:sub(2)
    end

    local intPart, decPart = formatted:match('^(%d+)%.?(%d*)$')
    if not intPart then return sign .. formatted end

    local out = intPart:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    out = out:gsub('^,', '')
    if decPart and decPart ~= '' then
        out = out .. '.' .. decPart
    end
    return sign .. out
end

--- Format money for chats / logs / 3D text.
--- @param value number
--- @param withSymbol boolean|nil  (default true)
--- @return string
function FormatMoney(value, withSymbol)
    value = tonumber(value) or 0
    local decimals = Config.Currency.decimals or 0
    local text = ('%.' .. decimals .. 'f'):format(math.abs(value))
    text = groupDigits(text)
    if value < 0 then text = '-' .. text end

    if withSymbol == false then
        return text
    end

    local symbol = Config.Currency.symbol or '$'
    if Config.Currency.symbolFirst then
        return symbol .. text
    end
    return text .. symbol
end

--- Is this a valid account key that exists in the config?
--- @param account string
--- @return boolean
function IsValidAccount(account)
    return type(account) == 'string'
        and Config.Accounts[account] ~= nil
        and Config.Accounts[account].enabled ~= false
end

--- Ordered list of enabled account keys (cash, bank, ...).
--- @return table
function EnabledAccounts()
    local list = {}
    for key, data in pairs(Config.Accounts) do
        if data.enabled ~= false then
            list[#list + 1] = key
        end
    end
    table.sort(list)
    return list
end

--- Look up a configured item, returning its price (0 when unknown).
--- @param item string
--- @return number
function GetItemPrice(item)
    local entry = Config.Items[item]
    if not entry then
        return 0
    end
    return tonumber(entry.price) or 0
end

--- Clamp a number between min and max.
function Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end
