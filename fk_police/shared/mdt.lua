--[[
    fk_police — shared/mdt.lua
    ---------------------------------------------------------------------------
    Everything the police computer (MDT) needs, as pure functions: keys, lookups,
    validation, fines and ranks. No natives, no state - the server holds the
    records and calls these, and the test suite calls the same functions.

    Records live in one table:

        records.people[<name key>]   = { name, dob, license, warrants = { ... } }
        records.vehicles[<plate key>] = { plate, model, owner, stolen, registration, insurance }
        records.citations            = { [1] = { id, plate, person, charges, fine, officer, at } }
        records.arrests              = { [1] = { id, person, charges, jail, fine, officer, at } }
        records.officers[<license>]  = { xp, rank, callsign, citations, arrests }
]]

Mdt = Mdt or {}

local function toNumber(value)
    local number = tonumber(value)

    if not number or number ~= number then return nil end

    return number
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

--- Plates are compared without spaces or punctuation, in upper case.
--- "ab 12 cde" -> "AB12CDE"
--- @return string|nil
function Mdt.normalizePlate(value)
    if type(value) ~= 'string' then return nil end

    local plate = value:upper():gsub('[^A-Z0-9]', '')

    if plate == '' or #plate > 8 then return nil end

    return plate
end

--- Names are matched case- and whitespace-insensitively.
--- @return string|nil
function Mdt.normalizeName(value)
    if type(value) ~= 'string' then return nil end

    local name = value:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if name == '' or #name > 48 then return nil end

    return name
end

--- @return string|nil
function Mdt.personKey(name)
    local normalized = Mdt.normalizeName(name)

    if not normalized then return nil end

    return 'name:' .. normalized:lower()
end

--- @return string|nil
function Mdt.vehicleKey(plate)
    local normalized = Mdt.normalizePlate(plate)

    if not normalized then return nil end

    return 'plate:' .. normalized
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

--- A stable, JSON-safe person record.
--- @return table|nil
function Mdt.normalizePerson(entry)
    if type(entry) ~= 'table' then return nil end

    local name = Mdt.normalizeName(entry.name)

    if not name then return nil end

    local warrants = {}

    if type(entry.warrants) == 'table' then
        for _, warrant in ipairs(entry.warrants) do
            if type(warrant) == 'table' and type(warrant.charge) == 'string' then
                warrants[#warrants + 1] = {
                    charge = warrant.charge,
                    issued = type(warrant.issued) == 'string' and warrant.issued or nil,
                }
            end
        end
    end

    return {
        name = name,
        dob = type(entry.dob) == 'string' and entry.dob or nil,
        license = entry.license or 'valid',
        warrants = warrants,
    }
end

--- @return table|nil
function Mdt.normalizeVehicle(entry)
    if type(entry) ~= 'table' then return nil end

    local plate = Mdt.normalizePlate(entry.plate)

    if not plate then return nil end

    return {
        plate = plate,
        model = type(entry.model) == 'string' and entry.model:lower() or 'unknown',
        owner = Mdt.normalizeName(entry.owner) or 'Unknown',
        stolen = entry.stolen == true,
        registration = entry.registration or 'valid',
        insurance = entry.insurance or 'valid',
    }
end

--- Every person whose name contains `query` (case-insensitive), or the exact
--- match first when there is one.
--- @return table list of person records
function Mdt.findPeople(records, query)
    local wanted = Mdt.normalizeName(query)

    if not wanted or type(records) ~= 'table' or type(records.people) ~= 'table' then
        return {}
    end

    local needle = wanted:lower()
    local exact, partial = nil, {}

    for key, person in pairs(records.people) do
        local name = type(person) == 'table' and person.name or nil

        if type(name) == 'string' then
            local haystack = name:lower()

            if key == ('name:' .. needle) or haystack == needle then
                exact = person
            elseif haystack:find(needle, 1, true) then
                partial[#partial + 1] = person
            end
        end
    end

    if exact then return { exact } end

    table.sort(partial, function(a, b) return tostring(a.name) < tostring(b.name) end)

    return partial
end

--- @return table|nil vehicle record
function Mdt.findVehicle(records, plate)
    local key = Mdt.vehicleKey(plate)

    if not key or type(records) ~= 'table' or type(records.vehicles) ~= 'table' then
        return nil
    end

    return records.vehicles[key]
end

--- @return table|nil person record
function Mdt.findPerson(records, name)
    local key = Mdt.personKey(name)

    if not key or type(records) ~= 'table' or type(records.people) ~= 'table' then
        return nil
    end

    return records.people[key]
end

--- Warrants are the reason a traffic stop turns into an arrest.
--- @return boolean
function Mdt.hasWarrant(person)
    return type(person) == 'table'
        and type(person.warrants) == 'table'
        and #person.warrants > 0
end

--- Anything wrong with a vehicle record, as short chat-friendly strings.
--- @return table list of reasons
function Mdt.vehicleFlags(vehicle)
    local flags = {}

    if type(vehicle) ~= 'table' then return flags end

    if vehicle.stolen then flags[#flags + 1] = 'STOLEN' end
    if vehicle.registration == 'expired' then flags[#flags + 1] = 'expired registration' end
    if vehicle.insurance == 'expired' or vehicle.insurance == 'none' then
        flags[#flags + 1] = 'insurance ' .. tostring(vehicle.insurance)
    end

    return flags
end

--- @return table list of reasons
function Mdt.personFlags(person)
    local flags = {}

    if type(person) ~= 'table' then return flags end

    if Mdt.hasWarrant(person) then
        for _, warrant in ipairs(person.warrants) do
            flags[#flags + 1] = ('WARRANT: %s'):format(tostring(warrant.charge))
        end
    end

    if person.license == 'expired' then flags[#flags + 1] = 'expired licence' end
    if person.license == 'suspended' then flags[#flags + 1] = 'suspended licence' end
    if person.license == 'none' then flags[#flags + 1] = 'no licence' end

    return flags
end

-- ---------------------------------------------------------------------------
-- Charges, fines, ranks
-- ---------------------------------------------------------------------------

--- @return table|nil charge
function Mdt.charge(config, id)
    if type(id) ~= 'string' then return nil end

    for _, charge in ipairs((config or {}).Charges or {}) do
        if charge.id == id then return charge end
    end

    return nil
end

--- Total fine and sentence for a list of charge ids. Unknown ids are ignored,
--- so a manipulated client cannot invent a charge.
--- @return number fine, number jail, table charges
function Mdt.sentence(config, ids)
    local fine, jail, charges = 0, 0, {}
    local seen = {}

    if type(ids) ~= 'table' then return 0, 0, charges end

    for _, id in ipairs(ids) do
        if not seen[id] then
            seen[id] = true

            local charge = Mdt.charge(config, id)

            if charge then
                fine = fine + (tonumber(charge.fine) or 0)
                jail = jail + (tonumber(charge.jail) or 0)
                charges[#charges + 1] = charge
            end
        end
    end

    return fine, jail, charges
end

--- @return table rank (never nil: falls back to the first rank)
function Mdt.rankFor(config, xp)
    local ranks = (config or {}).Ranks or {}
    local current = ranks[1] or { name = 'Officer', xp = 0, salary = 0 }

    for _, rank in ipairs(ranks) do
        if (tonumber(xp) or 0) >= (tonumber(rank.xp) or 0) then current = rank end
    end

    return current
end

--- The next rank, or nil at the top.
--- @return table|nil
function Mdt.nextRank(config, xp)
    local ranks = (config or {}).Ranks or {}
    local current = Mdt.rankFor(config, xp)

    for _, rank in ipairs(ranks) do
        if (tonumber(rank.xp) or 0) > (tonumber(current.xp) or 0) then return rank end
    end

    return nil
end

--- Pick a callout definition by id.
--- @return table|nil
function Mdt.callout(config, id)
    for _, callout in ipairs((config or {}).Callouts or {}) do
        if callout.id == id then return callout end
    end

    return nil
end

--- Weighted pick. `roll` is 0..1 so the caller (and the tests) stay in control.
--- @return table|nil callout
function Mdt.pickCallout(config, roll)
    local list = (config or {}).Callouts or {}
    local total = 0

    for _, callout in ipairs(list) do total = total + (tonumber(callout.weight) or 1) end

    if total <= 0 then return nil end

    local target = math.max(0, math.min(0.999999, tonumber(roll) or 0)) * total
    local running = 0

    for _, callout in ipairs(list) do
        running = running + (tonumber(callout.weight) or 1)

        if target < running then return callout end
    end

    return list[#list]
end

--- What the officer is allowed to do, for the HUD and the client menu.
--- @return table
function Mdt.publicStatus(entry, config)
    entry = type(entry) == 'table' and entry or {}

    local xp = tonumber(entry.xp) or 0
    local rank = Mdt.rankFor(config, xp)
    local next = Mdt.nextRank(config, xp)

    return {
        onDuty = entry.onDuty == true,
        xp = xp,
        rank = rank.name,
        salary = rank.salary,
        nextRank = next and next.name or nil,
        nextRankXp = next and next.xp or nil,
        citations = tonumber(entry.citations) or 0,
        arrests = tonumber(entry.arrests) or 0,
        callsign = entry.callsign or '1-ADAM-12',
    }
end
