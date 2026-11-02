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

--- Explain the player's staff access. Useful when someone cannot see the
--- staff tab and you need to know whether vMenu (or the ACE) is the problem.
local function describeAccess(src)
    local allowed, source, matched = CheckStaff(src)

    if allowed then
        if source == 'roster' then
            return true, ('YES — on the staff list (%s)'):format(matched)
        elseif source == 'vmenu' then
            return true, ('YES — vMenu admin (%s)'):format(matched)
        elseif source == 'ace' then
            return true, ('YES — %s permission'):format(matched)
        elseif source == 'identifier' then
            return true, ('YES — identifier allowlist (%s)'):format(matched)
        end
        return true, 'YES — console'
    end

    return false, ('NO — not on the staff list and no %s permission was found.')
        :format(Config.Staff.ace)
end

RegisterCommand('ecoaccess', function(src)
    src = tonumber(src) or 0
    local allowed, description = describeAccess(src)
    reply(src, ('Staff access: %s'):format(description),
        allowed and { 52, 211, 153 } or { 239, 68, 68 })
end, false)

RegisterCommand('eco_check', function(src, args)
    if src ~= 0 then return deny(src, 'eco_check') end
    local target = tonumber(args[1])
    if not target or not GetPlayerName(target) then
        return reply(src, 'Usage: eco_check <playerId> (player must be online)')
    end

    local allowed, description = describeAccess(target)
    reply(src, ('%s (%d) — staff access: %s'):format(GetPlayerName(target), target, description),
        allowed and { 52, 211, 153 } or { 239, 68, 68 })
end, true)

-- ---------------------------------------------------------------------------
-- Staff list management
--   /ecostaff claim | add <id> | remove <id> | list
--   eco_staff  same, from the server console
-- ---------------------------------------------------------------------------

--- Push the staff flag to everyone (roster changes are rare, and a player may
--- have gained/lost the Staff tab).
local function refreshStaffFlags()
    for _, id in ipairs(GetPlayers()) do
        local serverId = tonumber(id)
        if serverId then
            pcall(PushState, serverId)
        end
    end
end

local function actorName(src)
    if src == 0 then return 'console' end
    return ('%s (%d)'):format(GetPlayerName(src) or 'unknown', src)
end

--- Work out which identifier a staff target refers to.
--- @param input string|number server id or identifier
--- @return string|nil identifier, string|nil name, number|nil onlineSrc
local function resolveStaffTarget(input)
    local asNumber = tonumber(input)

    if asNumber and asNumber >= 1 and GetPlayerName(asNumber) then
        return StaffPrimaryIdentifier(asNumber), GetPlayerName(asNumber), asNumber
    end

    if type(input) == 'string' and input ~= '' then
        return input, nil, nil
    end

    if asNumber then
        return nil, nil, asNumber -- offline/unknown server id
    end

    return nil
end

local function staffAdd(src, input, reasonLabel)
    if not input then
        return reply(src, 'Usage: /ecostaff add <playerId|license:...>', { 250, 204, 21 })
    end

    local identifier, name, onlineSrc = resolveStaffTarget(input)

    if not identifier then
        return reply(src, ('No player with id %s is online. Use their license identifier instead.')
            :format(tostring(input)), { 239, 68, 68 })
    end

    if StaffIsRegistered(identifier) then
        return reply(src, ('%s is already on the staff list.'):format(name or identifier), { 250, 204, 21 })
    end

    local ok, err = StaffRegister(identifier, name, actorName(src), reasonLabel or 'staff')
    if not ok then
        return reply(src, ('Could not save the staff list (%s).'):format(tostring(err)), { 239, 68, 68 })
    end

    reply(src, ('Added %s to the staff list. They can open the staff tools with %s.')
        :format(name or identifier, Config.Keys.menu), { 52, 211, 153 })

    if onlineSrc then
        TriggerClientEvent('fk_economy:client:notify', onlineSrc, {
            title   = 'Staff access granted',
            message = 'You can now use the staff tools in the economy menu.',
            kind    = 'success',
        })
    end

    print(('[fk_economy] staff add: %s -> %s'):format(actorName(src), identifier))
    refreshStaffFlags()
end

local function staffRemove(src, input)
    if not input then
        return reply(src, 'Usage: /ecostaff remove <playerId|license:...>', { 250, 204, 21 })
    end

    local identifier, name, onlineSrc = resolveStaffTarget(input)

    if not identifier then
        return reply(src, ('No player with id %s is online. Use their license identifier instead.')
            :format(tostring(input)), { 239, 68, 68 })
    end

    if not StaffIsRegistered(identifier) then
        return reply(src, ('%s is not on the staff list.'):format(name or identifier), { 239, 68, 68 })
    end

    -- Never let the list be emptied by accident: an empty list re-opens
    -- /ecostaff claim to anyone.
    if StaffCount() <= 1 then
        return reply(src, 'That is the last staff member — add someone else first.', { 239, 68, 68 })
    end

    local ok, err = StaffUnregister(identifier)
    if not ok then
        return reply(src, ('Could not save the staff list (%s).'):format(tostring(err)), { 239, 68, 68 })
    end

    reply(src, ('Removed %s from the staff list.'):format(name or identifier), { 250, 204, 21 })

    if onlineSrc then
        TriggerClientEvent('fk_economy:client:notify', onlineSrc, {
            title   = 'Staff access removed',
            message = 'You no longer have access to the staff tools.',
            kind    = 'error',
        })
    end

    print(('[fk_economy] staff remove: %s -> %s'):format(actorName(src), identifier))
    refreshStaffFlags()
end

local function staffList(src)
    local list = StaffList()
    if #list == 0 then
        return reply(src, 'The staff list is empty.', { 250, 204, 21 })
    end

    reply(src, ('Staff list (%d):'):format(#list))
    for _, entry in ipairs(list) do
        reply(src, ('  %s  [%s]  %s'):format(entry.name or 'Unknown', entry.role or 'staff',
            entry.identifier or '?'))
    end
end

local function staffHelp(src)
    local allowed, description = describeAccess(src)
    reply(src, ('Your staff access: %s'):format(description),
        allowed and { 52, 211, 153 } or { 239, 68, 68 })
    reply(src, 'Staff list commands:')
    reply(src, '  /ecostaff claim            become staff while the list is empty')
    reply(src, '  /ecostaff add <id>         add an online player')
    reply(src, '  /ecostaff remove <id>      remove a player')
    reply(src, '  /ecostaff list             show the staff list')
    reply(src, '  /ecoaccess                 explain your own access')
end

local function handleStaffCommand(src, args)
    local sub = string.lower(tostring(args[1] or 'help'))

    if sub == 'claim' then
        if src == 0 then
            return reply(src, 'Run /ecostaff claim in game, or use eco_staff add <id> in the console.')
        end

        if not StaffClaimAllowed() then
            return reply(src, 'Claiming is disabled in config.lua. Ask the console to run eco_staff add <yourId>.',
                { 239, 68, 68 })
        end

        if not StaffRosterIsEmpty() then
            return reply(src, 'The staff list is not empty — ask an existing staff member to add you.',
                { 239, 68, 68 })
        end

        local identifier = StaffPrimaryIdentifier(src)
        if not identifier then
            return reply(src, 'Could not read your identifiers yet — try again in a few seconds.',
                { 239, 68, 68 })
        end

        local ok, err = StaffRegister(identifier, GetPlayerName(src), 'claim', 'owner')
        if not ok then
            return reply(src, ('Could not save the staff list (%s).'):format(tostring(err)),
                { 239, 68, 68 })
        end

        reply(src, 'You are now staff (owner). Open the menu with ' .. Config.Keys.menu .. '.',
            { 52, 211, 153 })
        TriggerClientEvent('fk_economy:client:notify', src, {
            title   = 'Staff access granted',
            message = 'You are registered as staff. Press ' .. Config.Keys.menu .. ' to open the menu.',
            kind    = 'success',
        })

        print(('[fk_economy] staff claim: %s -> %s'):format(actorName(src), identifier))
        refreshStaffFlags()
        return
    end

    if sub == 'add' or sub == 'remove' or sub == 'list' then
        if not IsStaff(src) then
            return reply(src, 'You need staff access for that. See /ecostaff for help.', { 239, 68, 68 })
        end

        if sub == 'add' then
            return staffAdd(src, args[2])
        elseif sub == 'remove' then
            return staffRemove(src, args[2])
        end
        return staffList(src)
    end

    return staffHelp(src)
end

RegisterCommand('ecostaff', function(src, args)
    handleStaffCommand(tonumber(src) or 0, args)
end, false)

RegisterCommand('eco_staff', function(src, args)
    if src ~= 0 then return deny(src, 'eco_staff') end

    local sub = string.lower(tostring(args[1] or 'help'))

    if sub == 'online' then
        local players = GetPlayers()
        if #players == 0 then
            return reply(src, 'Nobody is online.')
        end
        reply(src, ('Online players (%d):'):format(#players))
        for _, id in ipairs(players) do
            local serverId = tonumber(id)
            local entry = StaffIsRegistered(StaffPrimaryIdentifier(serverId) or '')
            reply(src, ('  %s  %s%s'):format(id, GetPlayerName(serverId) or '?',
                entry and '  [staff]' or ''))
        end
        return
    end

    return handleStaffCommand(0, args)
end, true)

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

RegisterCommand('items', function(src)
    if src == 0 then return reply(src, 'Use /items in game.') end

    local items = GetItems(src)
    local keys = {}

    for key, count in pairs(items) do
        keys[#keys + 1] = ('%s x%d'):format(Config.Items[key] and Config.Items[key].label or key, count)
    end

    if #keys == 0 then
        return reply(src, 'You are not carrying anything yet.')
    end

    table.sort(keys)
    reply(src, 'You own: ' .. table.concat(keys, ', '))
end, false)

--- /econstatus — one line per fact, in chat (no F8 needed) or in the console.
RegisterCommand('econstatus', function(src)
    if src ~= 0 and not IsStaff(src) then return deny(src, 'econstatus') end

    local status = AccountStore.status()
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'

    local saved = status.lastSave > 0
        and ('last save %ds ago'):format(os.time() - status.lastSave)
        or 'no save yet'

    reply(src, ('v%s | %d account(s) | %s | %s%s')
        :format(version, status.accounts, saved,
            status.dirty and 'dirty ' or 'clean',
            status.lastError and (' | ERROR: ' .. status.lastError) or ''))

    local blocked = 0

    for _, count in pairs(RateLimitStats()) do
        blocked = blocked + count
    end

    reply(src, ('rate limit: %d request(s) dropped | file: %s')
        :format(blocked, status.file))
end, true)

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

    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'

    print(('^2[fk_economy] Ready (v%s). Staff menu key: %s | staff list: %s^0')
        :format(version, Config.Keys.menu, StaffRosterFile()))

    print(('^2[fk_economy] Staff list: %d member(s) in %s^0')
        :format(StaffCount(), StaffRosterFile()))

    local vmenu = Config.Staff.vmenu
    if vmenu and vmenu.enabled == true then
        local installed = type(GetResourceState) == 'function'
            and GetResourceState('vMenu') ~= 'missing'

        print(('^2[fk_economy] vMenu admin detection: ON (%d permission node(s))%s^0')
            :format(#StaffVMenuPermissions(), installed and ' — vMenu is running.' or ' — vMenu not detected, checks are skipped automatically.'))
    end
end)
