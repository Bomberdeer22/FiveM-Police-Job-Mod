--[[
    fk_economy — server/commands.lua
    ---------------------------------------------------------------------------
    Chat + console fallbacks for the staff panel. Handy when a staff member is
    in-game without a UI, or when you are working from rcon / txAdmin.

    Chat (staff only):
        /addmoney <id> <cash|bank> <amount> [reason]
        /takemoney <id> <cash|bank> <amount> [reason]
        /setmoney <id> <cash|bank> <amount> [reason]
        /mymoney

    Console / rcon:
        eco_save                       -- flush accounts.json to disk
        eco_count                      -- number of stored accounts
        eco_give <id> <account> <amount> [reason]
]]

local function deny(src, command)
    if src == 0 then return false end
    TriggerClientEvent('chat:addMessage', src, {
        color = { 239, 68, 68 },
        args  = { 'ECONOMY', ('You do not have permission to use /%s.'):format(command) },
    })
    return true
end

local function reply(src, message, colour)
    if src == 0 then
        print(('[fk_economy] %s'):format(message))
        return
    end
    TriggerClientEvent('chat:addMessage', src, {
        color = colour or { 59, 130, 246 },
        args  = { 'ECONOMY', message },
    })
end

--- Shared handler for the three money chat commands.
local function moneyCommand(src, args, mode, commandName)
    src = tonumber(src) or 0
    if src ~= 0 and not IsStaff(src) then
        return deny(src, commandName)
    end

    local targetId = tonumber(args[1])
    local account  = tostring(args[2] or ''):lower()
    local amount   = tonumber(args[3])

    if not targetId or not IsValidAccount(account) or not amount then
        return reply(src, ('Usage: /%s <playerId> <cash|bank> <amount> [reason]'):format(commandName), { 250, 204, 21 })
    end
    if not GetPlayerName(targetId) then
        return reply(src, ('Player %s is not online.'):format(targetId), { 239, 68, 68 })
    end
    if amount <= 0 or amount > Config.Staff.maxPerAction then
        return reply(src, ('Amount must be between 1 and %s.'):format(FormatMoney(Config.Staff.maxPerAction)), { 239, 68, 68 })
    end

    local reason = table.concat(args, ' ', 4, #args)
    if reason == '' then reason = 'Command adjustment' end

    local actor = src == 0 and 'console' or ('%s (%d)'):format(GetPlayerName(src), src)
    local ok, result, err

    if mode == 'add' then
        ok, result, err = AddMoney(targetId, account, amount, reason, actor)
    elseif mode == 'remove' then
        ok, result, err = RemoveMoney(targetId, account, amount, reason, actor)
    else
        ok, result, err = SetMoney(targetId, account, amount, reason, actor)
    end

    if not ok then
        return reply(src, ('Failed: %s'):format(tostring(err)), { 239, 68, 68 })
    end

    local name = GetPlayerName(targetId)
    reply(src, ('%s %s %s — %s %s now has %s.')
        :format(mode == 'add' and 'Added' or mode == 'remove' and 'Removed' or 'Set',
            FormatMoney(amount), account, name, account, FormatMoney(result)))

    TriggerClientEvent('fk_economy:client:notify', targetId, {
        title   = mode == 'remove' and 'Money Taken' or mode == 'add' and 'Money Received' or 'Balance Updated',
        message = ('%s%s (%s)'):format(mode == 'remove' and '-' or mode == 'add' and '+' or '',
            FormatMoney(amount), reason),
        kind    = mode == 'remove' and 'error' or 'success',
    })
end

RegisterCommand('addmoney', function(src, args) moneyCommand(src, args, 'add', 'addmoney') end, false)
RegisterCommand('takemoney', function(src, args) moneyCommand(src, args, 'remove', 'takemoney') end, false)
RegisterCommand('setmoney', function(src, args) moneyCommand(src, args, 'set', 'setmoney') end, false)

RegisterCommand('mymoney', function(src)
    if src == 0 then
        return reply(src, 'This command is for players. Use /addmoney from the console.')
    end
    local money = GetMoney(src)
    if not money then
        return reply(src, 'No account found for you yet.', { 239, 68, 68 })
    end
    reply(src, ('Cash: %s   Bank: %s'):format(FormatMoney(money.cash), FormatMoney(money.bank)))
end, false)

-- Console / rcon -------------------------------------------------------------

RegisterCommand('eco_save', function(src)
    if src ~= 0 then return deny(src, 'eco_save') end
    AccountStore.save(true)
    reply(src, 'Accounts saved to ' .. Config.Persistence.file)
end, true)

RegisterCommand('eco_count', function(src)
    if src ~= 0 then return deny(src, 'eco_count') end
    reply(src, ('%d stored account(s).'):format(AccountStore.count()))
end, true)

RegisterCommand('eco_give', function(src, args)
    if src ~= 0 then return deny(src, 'eco_give') end
    moneyCommand(src, args, 'add', 'eco_give')
end, true)

CreateThread(function()
    Wait(1500)
    print('^2[fk_economy] Ready. Staff menu key: ' .. Config.Keys.menu ..
        ' | ACE: ' .. Config.Staff.ace .. '^0')
end)
