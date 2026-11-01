--[[
    fk_house — server/main.lua
    ---------------------------------------------------------------------------
    Spot overrides, personal outfits and food purchases.
]]

local RESOURCE = GetCurrentResourceName()
local SPOTS_FILE = Config.Persistence.spotsFile or 'data/spots.json'
local OUTFITS_FILE = Config.Persistence.outfitsFile or 'data/outfits.json'

local spotOverrides = {} -- [name] = { x, y, z }
local outfits = {}       -- [identifier] = { [slot] = outfit }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log(...)
    print('^2[fk_house]^0 ' .. table.concat({ ... }, ' '))
end

local function warn(...)
    print('^3[fk_house]^0 ' .. table.concat({ ... }, ' '))
end

local function errorf(...)
    print('^1[fk_house]^0 ' .. table.concat({ ... }, ' '))
end

local function isoNow()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function reply(target, message)
    if target == 0 then
        log(message)
    else
        TriggerClientEvent('fk_house:client:notify', target, message)
    end
end

local function playerIdentifier(source)
    local identifiers = GetPlayerIdentifiers(source) or {}

    for _, identifier in ipairs(identifiers) do
        if identifier:sub(1, 8) == 'license:' then return identifier end
    end

    return identifiers[1]
end

-- ---------------------------------------------------------------------------
-- Spots
-- ---------------------------------------------------------------------------

local function loadSpots()
    spotOverrides = {}

    local raw = LoadResourceFile(RESOURCE, SPOTS_FILE)
    if not raw or raw == '' then return end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then
        errorf(('%s is not valid JSON, using config.lua positions.'):format(SPOTS_FILE))
        return
    end

    for name, entry in pairs(data.spots or {}) do
        local key = House.sanitizeName(name)
        local x, y, z = House.toNumber(entry.x), House.toNumber(entry.y), House.toNumber(entry.z)

        if key and x and y and z then
            spotOverrides[key] = { x = x, y = y, z = z }
        else
            warn(('Skipped saved spot %s.'):format(tostring(name)))
        end
    end
end

local function saveSpots()
    local ok, encoded = pcall(json.encode, {
        version = 1,
        savedAt = isoNow(),
        spots = spotOverrides,
    }, { indent = true })

    if not ok or not encoded then
        errorf('Could not encode spots.')
        return false
    end

    if not SaveResourceFile(RESOURCE, SPOTS_FILE, encoded, -1) then
        errorf(('Could not write %s.'):format(SPOTS_FILE))
        return false
    end

    return true
end

--- Config spots with any saved positions applied.
--- @return table array of normalized spots
function GetHouseSpots()
    local spots = House.normalizeSpots(Config.Spots)

    for _, spot in ipairs(spots) do
        House.applyOverride(spot, spotOverrides[spot.name])
    end

    return spots
end

--- @return boolean ok, string|nil reason
function SetHouseSpot(name, x, y, z, by)
    local key = House.sanitizeName(name)

    if not key then return false, 'missing_name' end

    local configured = false

    for _, spot in ipairs(GetHouseSpots()) do
        if spot.name == key then configured = true break end
    end

    if not configured then return false, 'unknown_spot' end

    local nx, ny, nz = House.toNumber(x), House.toNumber(y), House.toNumber(z)

    if not nx or not ny or not nz then return false, 'invalid_coords' end
    if math.abs(nx) > 12000.0 or math.abs(ny) > 12000.0 or math.abs(nz) > 3000.0 then
        return false, 'out_of_bounds'
    end

    spotOverrides[key] = {
        x = math.floor(nx * 100 + 0.5) / 100,
        y = math.floor(ny * 100 + 0.5) / 100,
        z = math.floor(nz * 100 + 0.5) / 100,
        by = by or 'console',
        at = isoNow(),
    }

    saveSpots()
    broadcastSpots()

    return true
end

--- @return boolean ok, string|nil reason
function ResetHouseSpot(name)
    local key = House.sanitizeName(name)

    if not key then return false, 'missing_name' end
    if not spotOverrides[key] then return false, 'not_overridden' end

    spotOverrides[key] = nil
    saveSpots()
    broadcastSpots()

    return true
end

function broadcastSpots()
    local spots = GetHouseSpots()

    for _, id in ipairs(GetPlayers()) do
        TriggerClientEvent('fk_house:client:spots', tonumber(id), spots)
    end
end

-- ---------------------------------------------------------------------------
-- Outfits
-- ---------------------------------------------------------------------------

local function loadOutfits()
    outfits = {}

    local raw = LoadResourceFile(RESOURCE, OUTFITS_FILE)
    if not raw or raw == '' then return end

    local ok, data = pcall(json.decode, raw)

    if not ok or type(data) ~= 'table' then
        errorf(('%s is not valid JSON.'):format(OUTFITS_FILE))
        return
    end

    for identifier, slots in pairs(data.players or {}) do
        if type(identifier) == 'string' and type(slots) == 'table' then
            local clean = {}

            for slot, outfit in pairs(slots) do
                local slotNumber = House.toNumber(slot)

                if slotNumber and slotNumber >= 1 and slotNumber <= (Config.Wardrobe.slots or 3) then
                    local okOutfit, _, normalized = House.normalizeOutfit(outfit)

                    if okOutfit then
                        clean[math.floor(slotNumber)] = normalized
                    end
                end
            end

            outfits[identifier] = clean
        end
    end
end

local function saveOutfits()
    local ok, encoded = pcall(json.encode, {
        version = 1,
        savedAt = isoNow(),
        players = outfits,
    }, { indent = true })

    if not ok or not encoded then
        errorf('Could not encode outfits.')
        return false
    end

    if not SaveResourceFile(RESOURCE, OUTFITS_FILE, encoded, -1) then
        errorf(('Could not write %s.'):format(OUTFITS_FILE))
        return false
    end

    return true
end

--- @return table|nil
function GetPlayerOutfits(identifier)
    if type(identifier) ~= 'string' then return nil end
    return outfits[identifier]
end

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------

function IsHouseStaff(source)
    if source == 0 or source == nil then return true end

    if Config.Staff.useEconomy ~= false and GetResourceState('fk_economy') == 'started' then
        local ok, allowed = pcall(function()
            return exports.fk_economy:IsStaff(source)
        end)

        if ok and allowed then return true end
    end

    local ace = Config.Staff.ace

    if ace and IsPlayerAceAllowed and IsPlayerAceAllowed(source, ace) then return true end

    return false
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

RegisterNetEvent('fk_house:server:requestSpots', function()
    local source = source
    TriggerClientEvent('fk_house:client:spots', source, GetHouseSpots())
end)

RegisterNetEvent('fk_house:server:setSpot', function(name, x, y, z)
    local source = source

    if not IsHouseStaff(source) then
        return reply(source, 'You need staff access to move a house spot.')
    end

    local ok, reason = SetHouseSpot(name, x, y, z, ('player:%d'):format(source))

    if not ok then
        local messages = {
            unknown_spot = ('There is no spot called "%s". See /housespots.'):format(tostring(name)),
            out_of_bounds = 'Those coordinates are not on the map.',
            missing_name = 'Usage: /housespot <name>',
        }

        return reply(source, messages[reason] or ('Could not save that spot (%s).'):format(tostring(reason)))
    end

    reply(source, ('Saved %s at %.2f, %.2f, %.2f.'):format(House.sanitizeName(name), x, y, z))
end)

RegisterNetEvent('fk_house:server:resetSpot', function(name)
    local source = source

    if not IsHouseStaff(source) then
        return reply(source, 'You need staff access to reset a house spot.')
    end

    local ok, reason = ResetHouseSpot(name)

    if not ok then
        return reply(source, reason == 'not_overridden'
            and 'That spot already uses the config.lua position.'
            or 'Could not reset that spot.')
    end

    reply(source, ('%s reset to config.lua.'):format(tostring(name)))
end)

RegisterNetEvent('fk_house:server:requestOutfits', function()
    local source = source
    local identifier = playerIdentifier(source)

    TriggerClientEvent('fk_house:client:outfits', source, GetPlayerOutfits(identifier) or {})
end)

RegisterNetEvent('fk_house:server:saveOutfit', function(slot, outfit)
    local source = source
    local identifier = playerIdentifier(source)

    if not identifier then
        return reply(source, 'Could not identify your licence, outfit not saved.')
    end

    local slotNumber = House.toNumber(slot)
    local maxSlots = Config.Wardrobe.slots or 3

    if not slotNumber or slotNumber < 1 or slotNumber > maxSlots then
        return reply(source, 'That wardrobe slot does not exist.')
    end

    local ok, reason, clean = House.normalizeOutfit(outfit)

    if not ok then
        return reply(source, ('That outfit could not be saved (%s).'):format(tostring(reason)))
    end

    clean.savedAt = isoNow()
    outfits[identifier] = outfits[identifier] or {}
    outfits[identifier][math.floor(slotNumber)] = clean

    saveOutfits()
    TriggerClientEvent('fk_house:client:outfits', source, outfits[identifier])
    reply(source, ('Outfit saved to slot %d.'):format(math.floor(slotNumber)))
end)

--- Food is paid for through the economy when it is running.
RegisterNetEvent('fk_house:server:buy', function(item)
    local source = source

    if type(item) ~= 'string' then return end

    -- Only items that are actually on a kitchen menu may be bought.
    local allowed = false

    for _, spot in ipairs(Config.Spots) do
        for _, option in ipairs(spot.options or {}) do
            if option.item == item then allowed = true break end
        end
    end

    if not allowed then return end

    if Config.Food.chargeItems == false or GetResourceState('fk_economy') ~= 'started' then
        return TriggerClientEvent('fk_house:client:buyResult', source, true, nil, item)
    end

    local ok, success, detail = pcall(function()
        return exports.fk_economy:TryPurchase(source, item, 1)
    end)

    if not ok then
        return TriggerClientEvent('fk_house:client:buyResult', source, false, 'economy_error', item)
    end

    TriggerClientEvent('fk_house:client:buyResult', source, success == true, success == true and nil or detail, item)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- /housespots — list the spots and where they are.
RegisterCommand('housespots', function(source)
    local lines = { '' }

    for _, spot in ipairs(GetHouseSpots()) do
        lines[#lines + 1] = ('%s%s: %.2f, %.2f, %.2f (%s)')
            :format(spot.name, spot.fromOverride and ' *' or '', spot.x, spot.y, spot.z, spot.type)
    end

    if #lines == 1 then
        lines[#lines + 1] = 'No spots configured.'
    end

    local text = table.concat(lines, '\n')

    if source == 0 then
        print(text)
    else
        TriggerClientEvent('fk_house:client:list', source, text)
    end
end, false)

-- house_spot <name> <x> <y> <z> — console / txAdmin.
RegisterCommand('house_spot', function(source, args)
    local name, x, y, z = args[1], tonumber(args[2]), tonumber(args[3]), tonumber(args[4])

    if not name or not x or not y or not z then
        return reply(source, 'Usage: house_spot <name> <x> <y> <z>')
    end

    if source ~= 0 and not IsHouseStaff(source) then
        return reply(source, 'You need staff access to move a house spot.')
    end

    local ok, reason = SetHouseSpot(name, x, y, z, 'console')

    if not ok then
        return reply(source, ('Could not save that spot (%s).'):format(tostring(reason)))
    end

    reply(source, ('Saved %s.'):format(tostring(name)))
end, true)

RegisterCommand('house_reset', function(source, args)
    if source ~= 0 and not IsHouseStaff(source) then
        return reply(source, 'You need staff access to reset a house spot.')
    end

    if not args[1] then
        return reply(source, 'Usage: house_reset <name>')
    end

    local ok, reason = ResetHouseSpot(args[1])

    if not ok then
        return reply(source, reason == 'not_overridden'
            and 'That spot already uses the config.lua position.'
            or 'Could not reset that spot.')
    end

    reply(source, ('%s reset to config.lua.'):format(args[1]))
end, true)

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('GetSpots', GetHouseSpots)
exports('SetSpot', function(name, coords, by)
    return SetHouseSpot(name, coords and coords.x, coords and coords.y, coords and coords.z, by)
end)
exports('ResetSpot', ResetHouseSpot)
exports('GetPlayerOutfits', GetPlayerOutfits)
exports('IsHouseStaff', IsHouseStaff)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

loadSpots()
loadOutfits()

CreateThread(function()
    Wait(600)

    local spots, errors = House.normalizeSpots(Config.Spots)

    for _, failure in ipairs(errors) do
        warn(('spot %s in config.lua is invalid (%s).')
            :format(tostring(failure.name), tostring(failure.reason)))
    end

    local version = GetResourceMetadata(RESOURCE, 'version', 0) or '?'
    local moved = 0

    for _ in pairs(spotOverrides) do moved = moved + 1 end

    log(('Ready (v%s). %d spot(s)%s.'):format(
        version,
        #spots,
        moved > 0 and (', %d saved position(s)'):format(moved) or ''))

    log('Commands: /housespot <name> (staff), /housespots, /housemarkers, /househelp')
end)
