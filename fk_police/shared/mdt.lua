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
        rankXp = tonumber(rank.xp) or 0,
        citations = tonumber(entry.citations) or 0,
        arrests = tonumber(entry.arrests) or 0,
        callsign = entry.callsign or '1-ADAM-12',
        medals = Mdt.medalsFor(config, xp),
    }
end

-- ---------------------------------------------------------------------------
-- Justice, shifts, field work
-- ---------------------------------------------------------------------------
-- Everything from here on is pure too: the server owns the tables, these
-- functions decide what a fine owes, whether a BOLO matches, what a frisk finds
-- and what a shift pays. The test suite calls them directly.

--- A stable 0..1 number for a string (djb2). Used where a d20 would be used at
--- the table: the same person always has the same pockets, the same breath test
--- and the same "does the dog sit down" answer.
--- @return number 0..1
function Mdt.hash01(value)
    local text = tostring(value or '')
    local hash = 5381

    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 2147483647
    end

    return hash / 2147483647
end

--- "@1h 04m" / "@4m 20s" / "@12s".
--- @return string
function Mdt.formatDuration(seconds)
    local total = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local rest = total % 60

    if hours > 0 then return ('%dh %02dm'):format(hours, minutes) end
    if minutes > 0 then return ('%dm %02ds'):format(minutes, rest) end

    return ('%ds'):format(rest)
end

--- How far through the current rank the officer is, for the HUD bar.
--- @return table { rank, percent, into, span, next, nextXp }
function Mdt.xpProgress(config, xp)
    local value = tonumber(xp) or 0
    local rank = Mdt.rankFor(config, value)
    local nextRank = Mdt.nextRank(config, value)

    if not nextRank then
        return { rank = rank.name, percent = 100, into = value, span = 0, next = nil, nextXp = nil }
    end

    local floorXp = tonumber(rank.xp) or 0
    local span = math.max(1, (tonumber(nextRank.xp) or 0) - floorXp)

    return {
        rank = rank.name,
        percent = math.max(0, math.min(100, math.floor(((value - floorXp) / span) * 100))),
        into = value - floorXp,
        span = span,
        next = nextRank.name,
        nextXp = nextRank.xp,
    }
end

--- Trim a free-text field and drop control characters.
--- @return string|nil
function Mdt.cleanText(value, maxLength)
    if type(value) ~= 'string' then return nil end

    local text = value:gsub('[%z\1-\31\127]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if text == '' then return nil end
    if maxLength and #text > maxLength then return nil end

    return text
end

--- Validate an incident report before it is stored.
--- @return table|nil clean, string|nil reason
function Mdt.validateReport(config, report)
    local rules = (config or {}).Reports or {}
    local payload = type(report) == 'table' and report or {}

    local title = Mdt.cleanText(payload.title, tonumber(rules.maxTitle) or 80)

    if not title then return nil, 'bad_title' end
    if #title < (tonumber(rules.minTitle) or 3) then return nil, 'title_too_short' end

    local body

    if type(payload.body) == 'string' then
        body = payload.body:gsub('[%z\1-\8\11\12\14-\31\127]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    end

    if not body or body == '' then return nil, 'bad_body' end
    if #body < (tonumber(rules.minBody) or 10) then return nil, 'body_too_short' end
    if #body > (tonumber(rules.maxBody) or 4000) then return nil, 'body_too_long' end

    local kind = tostring(payload.kind or 'incident')
    local kinds = rules.kinds or { 'incident' }

    if not (function()
        for _, candidate in ipairs(kinds) do
            if candidate == kind then return true end
        end

        return false
    end)() then
        kind = 'incident'
    end

    local subjects, seen = {}, {}

    for _, subject in ipairs(type(payload.subjects) == 'table' and payload.subjects or {}) do
        local name = Mdt.normalizeName(subject)

        if name and not seen[name:lower()] and #subjects < (tonumber(rules.maxSubjects) or 6) then
            seen[name:lower()] = true
            subjects[#subjects + 1] = name
        end
    end

    return {
        kind = kind,
        title = title,
        body = body,
        subjects = subjects,
        plate = Mdt.normalizePlate(payload.plate),
        charges = type(payload.charges) == 'table' and payload.charges or {},
    }
end

--- Is this fine past its due date?
--- @return boolean
function Mdt.isOverdue(fine, nowSeconds)
    if type(fine) ~= 'table' then return false end
    if (fine.status or 'unpaid') == 'paid' then return false end
    if tonumber(fine.owed or fine.amount or 0) <= 0 then return false end

    local due = tonumber(fine.dueAt) or 0

    return due > 0 and (tonumber(nowSeconds) or 0) > due
end

--- Ledger maths for one person (or everyone, when `person` is nil).
--- @return table { total, paid, owed, count, overdue, unpaid }
function Mdt.fineTotals(fines, person, nowSeconds)
    local totals = { total = 0, paid = 0, owed = 0, count = 0, overdue = 0, unpaid = 0 }
    local wanted = person and Mdt.normalizeName(person)

    for _, fine in ipairs(type(fines) == 'table' and fines or {}) do
        local matches = not wanted or (Mdt.normalizeName(fine.person) or ''):lower() == wanted:lower()

        if matches then
            local amount = tonumber(fine.amount) or 0
            local paid = tonumber(fine.paid) or 0

            totals.total = totals.total + amount
            totals.paid = totals.paid + paid
            totals.owed = totals.owed + math.max(0, amount - paid)
            totals.count = totals.count + 1

            if (fine.status or 'unpaid') == 'paid' then
                totals.paid = math.max(totals.paid, totals.total)
            else
                totals.unpaid = totals.unpaid + 1

                if Mdt.isOverdue(fine, nowSeconds) then totals.overdue = totals.overdue + 1 end
            end
        end
    end

    return totals
end

--- Active BOLOs for a plate or name. Expired ones are ignored, not deleted:
--- the MDT shows them greyed out and the sweep clears them.
--- @return table list
function Mdt.matchBolos(bolos, kind, value, nowSeconds)
    local matches = {}
    local wanted = kind == 'vehicle' and Mdt.normalizePlate(value) or Mdt.normalizeName(value)

    if not wanted then return matches end

    for _, bolo in ipairs(type(bolos) == 'table' and bolos or {}) do
        if (bolo.kind or 'vehicle') == kind and bolo.active ~= false then
            local target = kind == 'vehicle' and Mdt.normalizePlate(bolo.value) or Mdt.normalizeName(bolo.value)

            local expired = tonumber(bolo.expiresAt or 0) > 0
                and (tonumber(nowSeconds) or 0) > tonumber(bolo.expiresAt)

            if target and target:lower() == wanted:lower() and not expired then
                matches[#matches + 1] = bolo
            end
        end
    end

    return matches
end

--- A frisk is deterministic: same person, same pockets. Items that need a
--- charge in the record only appear when the person has it.
--- @return table { items = { { id, label, qty } }, hasWeapon = boolean }
function Mdt.frisk(config, person)
    local rules = (config or {}).Field or {}
    local name = type(person) == 'table' and person.name or nil
    local key = tostring(name or 'unknown'):lower()
    local bonus = Mdt.hasWarrant(person) and (tonumber(rules.warrantBonus) or 0) or 0
    local items, hasWeapon = {}, false

    for _, entry in ipairs(rules.frisk or {}) do
        local chance = (tonumber(entry.chance) or 0) + bonus
        local roll = Mdt.hash01(key .. ':frisk:' .. tostring(entry.id))

        local allowed = true

        if entry.flag then
            allowed = false

            if type(person) == 'table' and type(person.warrants) == 'table' then
                for _, warrant in ipairs(person.warrants) do
                    if warrant.charge == entry.flag then allowed = true end
                end
            end
        end

        if allowed and roll < chance then
            local range = entry.qty or { 1, 1 }
            local low = tonumber(range[1]) or 1
            local high = math.max(low, tonumber(range[2]) or low)
            local qty = low + math.floor(Mdt.hash01(key .. ':qty:' .. tostring(entry.id)) * (high - low + 1))

            items[#items + 1] = { id = entry.id, label = entry.label or entry.id, qty = qty }

            if entry.id == 'weapon' then hasWeapon = true end
        end
    end

    return { items = items, hasWeapon = hasWeapon }
end

--- The breath test: 0.00 .. Config.Field.breathMax, two decimals, always the
--- same for the same person.
--- @return table { bac, limit, over }
function Mdt.breathalyzer(config, person)
    local rules = (config or {}).Field or {}
    local limit = tonumber(rules.duiLimit) or 0.08
    local ceiling = math.max(limit, tonumber(rules.breathMax) or 0.199)
    local name = type(person) == 'table' and person.name or nil
    local roll = Mdt.hash01(tostring(name or 'unknown'):lower() .. ':bac')
    local bac = math.floor(roll * ceiling * 100 + 0.5) / 100

    return { bac = bac, limit = limit, over = bac >= limit }
end

--- What a shift pays. `counters` is the officer's in-memory tally.
--- @return table { pay, minutes, base, bonus, reasons }
function Mdt.shiftPay(config, counters, rankName, minutes)
    local rules = (config or {}).Shift or {}
    local tally = type(counters) == 'table' and counters or {}
    local spent = math.max(0, tonumber(minutes) or 0)
    local full = math.max(1, tonumber(rules.fullShiftMinutes) or 60)
    local salary = 0

    for _, rank in ipairs((config or {}).Ranks or {}) do
        if rank.name == rankName then salary = tonumber(rank.salary) or 0 end
    end

    local base = math.floor(salary * math.min(1, spent / full))
    local citationBonus = (tonumber(tally.citations) or 0) * (tonumber(rules.citationBonus) or 0)
    local arrestBonus = (tonumber(tally.arrests) or 0) * (tonumber(rules.arrestBonus) or 0)
    local calloutBonus = (tonumber(tally.callouts) or 0) * (tonumber(rules.calloutBonus) or 0)
    local reportBonus = (tonumber(tally.reports) or 0) * (tonumber(rules.reportBonus) or 0)
    local bonus = citationBonus + arrestBonus + calloutBonus + reportBonus
    local pay = base + bonus
    local cap = tonumber(rules.maxPay) or 5000

    return {
        pay = math.min(pay, cap),
        minutes = math.floor(spent),
        base = base,
        bonus = bonus,
        salary = salary,
        capped = pay > cap,
        reasons = {
            citations = citationBonus,
            arrests = arrestBonus,
            callouts = calloutBonus,
            reports = reportBonus,
        },
    }
end

--- Everything the caller knows about a plate, merged: the record, its flags,
--- BOLO hits and whether it is on the impound lot.
--- @return table { vehicle, flags, bolos, impounded }
function Mdt.plateReport(records, plate, nowSeconds)
    local report = { vehicle = nil, flags = {}, bolos = {}, impounded = nil }

    if type(records) ~= 'table' then return report end

    local vehicle = Mdt.findVehicle(records, plate)

    report.vehicle = vehicle
    report.flags = Mdt.vehicleFlags(vehicle)
    report.bolos = Mdt.matchBolos(records.bolos, 'vehicle', plate, nowSeconds)

    for _, entry in ipairs(records.impounds or {}) do
        if not entry.released and Mdt.normalizePlate(entry.plate) == Mdt.normalizePlate(plate) then
            report.impounded = entry
        end
    end

    return report
end

--- Medals earned at this XP level.
--- @return table list of { label, blurb, xp }
function Mdt.medalsFor(config, xp)
    local earned = {}
    local value = tonumber(xp) or 0

    for _, medal in ipairs((config or {}).Medals or {}) do
        if value >= (tonumber(medal.xp) or 0) then
            earned[#earned + 1] = { label = medal.label, blurb = medal.blurb, xp = medal.xp }
        end
    end

    return earned
end

--- The court's decision for a booking. Deterministic: the booking id is the seed,
--- so the same booking always gets the same verdict.
--- @return string 'guilty' | 'acquitted'
function Mdt.verdict(config, bookingId, chance)
    local roll = Mdt.hash01(tostring(bookingId or '') .. ':verdict')
    local odds = tonumber(chance) or tonumber(((config or {}).Justice or {}).verdictChance) or 0.72

    return roll < odds and 'guilty' or 'acquitted'
end

--- A callsign is short, upper case and readable over the radio.
--- @return string|nil
function Mdt.normalizeCallsign(value)
    if type(value) ~= 'string' then return nil end

    local callsign = value:upper()
        :gsub('%s+', '-')
        :gsub('[^A-Z0-9%-]', '')
        :gsub('%-+', '-')
        :gsub('^%-', '')
        :gsub('%-$', '')

    if #callsign < 2 or #callsign > 12 then return nil end

    return callsign
end

-- ---------------------------------------------------------------------------
-- Bail, cameras, hotlist and the lab
-- ---------------------------------------------------------------------------

--- What the court sets as bail for a sentence: a flat sum plus a per-minute
--- rate, capped so a 10 minute sentence does not cost more than a car.
--- @return number
function Mdt.bailAmount(config, seconds)
    local rules = (config or {}).Bail or {}
    local minutes = math.max(0, math.floor((tonumber(seconds) or 0) / 60))
    local amount = (tonumber(rules.base) or 0) + minutes * (tonumber(rules.perMinute) or 0)
    local cap = tonumber(rules.max)

    if cap and cap > 0 then amount = math.min(cap, amount) end

    return math.max(0, math.floor(amount))
end

--- The camera a position is standing in, or nil.
--- @return table|nil camera
function Mdt.cameraAt(config, x, y, z)
    local rules = (config or {}).Cameras or {}
    local px, py, pz = tonumber(x), tonumber(y), tonumber(z)

    if not px or not py or not pz then return nil end

    for _, camera in ipairs(rules.cameras or {}) do
        local coords = camera.coords or {}
        local radius = tonumber(camera.radius) or tonumber(rules.defaultRadius) or 30.0
        local dx = px - (tonumber(coords.x) or 0)
        local dy = py - (tonumber(coords.y) or 0)
        local dz = pz - (tonumber(coords.z) or 0)

        if (dx * dx) + (dy * dy) + (dz * dz) <= radius * radius then return camera end
    end

    return nil
end

--- Is this speed (m/s) over the camera's limit? Returns the reading in km/h too.
--- @return boolean, number
function Mdt.overLimit(camera, speed)
    local limitKmh = tonumber(camera and camera.limitKmh) or 0
    local kmh = math.max(0, (tonumber(speed) or 0) * 3.6)

    return limitKmh > 0 and kmh > limitKmh, kmh
end

--- The live hotlist entry for a plate, if it has not expired.
--- @return table|nil
function Mdt.hotlistEntry(hotlist, plate, nowSeconds)
    local wanted = Mdt.normalizePlate(plate)

    if not wanted then return nil end

    local now = tonumber(nowSeconds) or 0

    for _, entry in ipairs(hotlist or {}) do
        if Mdt.normalizePlate(entry.plate) == wanted then
            if not entry.expiresAt or tonumber(entry.expiresAt) <= now then return nil end

            return entry
        end
    end

    return nil
end

--- The hotlist without the expired entries, newest first.
--- @return table
function Mdt.activeHotlist(hotlist, nowSeconds)
    local now = tonumber(nowSeconds) or 0
    local out = {}

    for index = #(hotlist or {}), 1, -1 do
        local entry = hotlist[index]

        if not entry.expiresAt or tonumber(entry.expiresAt) > now then out[#out + 1] = entry end
    end

    return out
end

--- One lab kind by id.
--- @return table|nil
function Mdt.forensicsKind(config, id)
    local wanted = tostring(id or ''):lower()

    for _, kind in ipairs(((config or {}).Forensics or {}).kinds or {}) do
        if kind.id == wanted then return kind end
    end

    return nil
end

--- The lab's answer for a sample. Deterministic: the sample id seeds the roll,
--- so a result never changes once it has been reported.
--- @return table { hit, label, detail, confidence }
function Mdt.sampleResult(config, sampleId, kindId, person)
    local rules = (config or {}).Forensics or {}
    local kind = Mdt.forensicsKind(config, kindId) or { id = tostring(kindId or 'unknown'), label = 'Sample' }
    local roll = Mdt.hash01(tostring(sampleId or '') .. ':lab:' .. tostring(kind.id))
    local hit = roll < (tonumber(rules.hitChance) or 0.6)
    local who = Mdt.normalizeName(person) or 'the subject'
    local detail

    if kind.id == 'dna' then
        detail = hit and ('DNA profile matches ' .. who) or 'No profile on file for this sample'
    elseif kind.id == 'drugs' then
        detail = hit and 'Positive: cocaine residue, weight consistent with possession' or 'No controlled substance detected'
    elseif kind.id == 'ballistics' then
        detail = hit and 'Casing matches an unsolved shooting in the district' or 'No match in the casings database'
    elseif kind.id == 'prints' then
        detail = hit and ('Latent prints identified: ' .. who) or 'No usable prints lifted'
    else
        detail = hit and 'Sample matched an open case' or 'No match found'
    end

    return {
        kind = kind.id,
        label = kind.label,
        hit = hit,
        detail = detail,
        confidence = math.floor(70 + (roll * 29)),
    }
end
