--[[
    fk_police — server/justice.lua
    ---------------------------------------------------------------------------
    Everything that happens after the stop: the fine ledger, warrants, BOLOs,
    incident reports, the impound lot, pursuits, field work (frisk / breath
    test / K9) and the shift that pays for all of it.

    It runs on top of server/main.lua through the FKPolice table (records,
    officers, pay, addXp, the live stop) - there is one record store and one
    officer table, this file never keeps its own copy.

    Same rule as the rest of the job: the client asks, this answers.
]]

local P = FKPolice

local function records() return P.records() end
local function config() return P.config() end
local function epoch() return P.epoch() end

local function notify(source, message) P.reply(source, message) end

--- An on-duty officer entry, or nil plus the reason.
--- @return table|nil entry, string|nil reason
local function onDuty(source)
    local entry = P.officerFor(source, true)

    if not entry then return nil, 'no_identifier' end
    if not entry.onDuty then return nil, 'off_duty' end

    return entry
end

--- The person a request is about: an explicit name, else whoever is stopped.
--- @return table|nil person, string|nil name
local function subjectFor(source, name)
    local store = records()
    local wanted = Mdt.normalizeName(name)

    if not wanted then
        local stop = P.stopFor(source)
        wanted = stop and stop.person and stop.person.name or nil
    end

    if not wanted then return nil, nil end

    return Mdt.findPerson(store, wanted), wanted
end

local function personRecord(name)
    local key = Mdt.personKey(name)

    if not key then return nil end

    return records().people[key]
end

-- ---------------------------------------------------------------------------
-- Shift: the duty session that pays at the end
-- ---------------------------------------------------------------------------

local function ensureShift(entry)
    if entry.shift then return entry.shift end

    entry.shift = {
        startedAt = epoch(),
        citations = 0,
        arrests = 0,
        callouts = 0,
        reports = 0,
        fines = 0,
        backups = 0,
        xp = 0,
    }

    return entry.shift
end

--- @return table shift status for the HUD and the MDT
local function shiftStatus(source)
    local entry = P.officerFor(source, true)

    if not entry then return { active = false } end

    if not entry.shift then
        return { active = false, onDuty = entry.onDuty == true }
    end

    local shift = ensureShift(entry)
    local seconds = math.max(0, epoch() - (shift.startedAt or epoch()))
    local rank = Mdt.rankFor(config(), entry.xp)

    return {
        active = true,
        onDuty = entry.onDuty == true,
        seconds = seconds,
        minutes = math.floor(seconds / 60),
        counters = {
            citations = shift.citations,
            arrests = shift.arrests,
            callouts = shift.callouts,
            reports = shift.reports,
            fines = shift.fines,
            backups = shift.backups,
        },
        projected = Mdt.shiftPay(config(), shift, rank.name, seconds / 60),
        rank = rank.name,
    }
end

--- End the shift: record it, pay it, hand the officer a summary.
--- @return table result
local function endShift(source, reason)
    local entry = P.officerFor(source, true)

    if not entry or not entry.shift then
        return { ok = false, reason = 'no_shift' }
    end

    local shift = ensureShift(entry)
    local seconds = math.max(0, epoch() - (shift.startedAt or epoch()))
    local minutes = seconds / 60
    local rules = config().Shift or {}
    local rank = Mdt.rankFor(config(), entry.xp)
    local pay = Mdt.shiftPay(config(), shift, rank.name, minutes)

    if minutes < (tonumber(rules.minMinutes) or 1) then
        pay.pay = 0
        pay.bonus = 0
        pay.base = 0
    end

    local record = {
        id = P.newId('SHIFT'),
        officer = entry.identifier,
        rank = rank.name,
        startedAt = shift.startedAt,
        endedAt = epoch(),
        seconds = seconds,
        reason = reason or 'off_duty',
        citations = shift.citations,
        arrests = shift.arrests,
        callouts = shift.callouts,
        reports = shift.reports,
        fines = shift.fines,
        backups = shift.backups,
        pay = pay.pay,
    }

    local store = records()

    store.shifts[#store.shifts + 1] = record
    P.trim(store.shifts, rules.maxHistory)

    entry.shift = nil

    if pay.pay > 0 then P.pay(source, pay.pay, 'shift pay') end

    P.persistOfficer(entry)
    P.save()

    return {
        ok = true,
        pay = pay.pay,
        base = pay.base,
        bonus = pay.bonus,
        seconds = seconds,
        counters = record,
        rank = rank.name,
        reason = reason or 'off_duty',
    }
end

--- Called from setDuty in main.lua.
P.hooks.dutyChanged = function(source, on)
    local entry = P.officerFor(source, true)

    if not entry then return end

    if on then
        entry.shift = nil
        ensureShift(entry)

        -- A shift starts with a sweep: fines that went past their due date
        -- suspend licences and put out warrants while the officer is on duty.
        local swept = P.sweepOverdue and P.sweepOverdue()

        if swept and (swept.overdue or 0) > 0 then
            notify(source, ('Court: %d overdue fine(s), %d licence(s) suspended, %d warrant(s) issued.')
                :format(swept.overdue, swept.suspended, swept.warrants))
        end

        notify(source, 'Shift started. Dispatch is listening.')
        return
    end

    local result = endShift(source, 'off_duty')

    if result.ok then
        notify(source, ('Shift over: %s. %d citation(s), %d arrest(s), %d callout(s). Pay $%d.')
            :format(Mdt.formatDuration(result.seconds), result.counters.citations,
                result.counters.arrests, result.counters.callouts, result.pay))
        P.sendStatus(source)
    end
end

--- Extra fields on the status payload (the HUD reads these).
P.hooks.statusExtra = function(source, entry)
    local shift = entry.shift
    local seconds = shift and math.max(0, epoch() - (shift.startedAt or epoch())) or 0
    local live = entry.pursuit and math.max(0, epoch() - (entry.pursuit.startedAt or epoch())) or nil

    local custody = entry.custody and math.max(0, (entry.custody.untilEpoch or 0) - epoch()) or 0

    return {
        shiftSeconds = seconds,
        shiftActive = shift ~= nil,
        pursuitActive = entry.pursuit ~= nil,
        pursuitSeconds = live,
        custodySeconds = custody,
        custodyPerson = entry.custody and entry.custody.person or nil,
    }
end

P.hooks.cited = function(source)
    local entry = P.officerFor(source, true)

    if not entry then return end

    local shift = ensureShift(entry)
    shift.citations = shift.citations + 1
    shift.fines = shift.fines + 1
end

P.hooks.arrested = function(source)
    local entry = P.officerFor(source, true)

    if not entry then return end

    ensureShift(entry).arrests = ensureShift(entry).arrests + 1
end

P.hooks.calloutResolved = function(source)
    local entry = P.officerFor(source, true)

    if not entry then return end

    ensureShift(entry).callouts = ensureShift(entry).callouts + 1
end

P.hooks.backupRequested = function(source)
    local entry = P.officerFor(source, true)

    if not entry then return end

    ensureShift(entry).backups = ensureShift(entry).backups + 1
end

P.shiftStatus = shiftStatus
P.endShift = endShift
exports('GetShift', function(source) return shiftStatus(source) end)
exports('EndShift', function(source, reason) return endShift(source, reason) end)

RegisterNetEvent('fk_police:server:shift', function(action)
    local source = source

    if action == 'end' then
        local entry, reason = onDuty(source)

        if not entry then return notify(source, 'Go on duty first.') end

        local result = endShift(source, 'manual')

        if result.ok then
            notify(source, ('Shift logged: %s, $%d. You are off duty.'):format(
                Mdt.formatDuration(result.seconds), result.pay))

            P.setDuty(source, false)
        end

        return
    end

    local status = shiftStatus(source)
    local entry = P.officerFor(source, true)

    if not status.active then
        return notify(source, entry and entry.onDuty and 'Your shift just started.' or 'You are off duty.')
    end

    notify(source, ('Shift: %s | %d citation(s) | %d arrest(s) | %d callout(s) | %d report(s) | $%d so far.')
        :format(Mdt.formatDuration(status.seconds), status.counters.citations, status.counters.arrests,
            status.counters.callouts, status.counters.reports, status.projected.pay))
end)

-- ---------------------------------------------------------------------------
-- Fines ledger
-- ---------------------------------------------------------------------------

--- Fines, newest first, with their overdue flag worked out now (not at issue).
--- @return table list
local function listFines(filter)
    local options = type(filter) == 'table' and filter or {}
    local person = Mdt.normalizeName(options.person)
    local out = {}
    local nowSeconds = epoch()

    for _, fine in ipairs(records().fines or {}) do
        local matches = true

        if person and (Mdt.normalizeName(fine.person) or ''):lower() ~= person:lower() then matches = false end
        if options.status and (fine.status or 'unpaid') ~= options.status then matches = false end
        if options.overdue and not Mdt.isOverdue(fine, nowSeconds) then matches = false end

        if matches then
            out[#out + 1] = {
                id = fine.id,
                person = fine.person,
                plate = fine.plate,
                charges = fine.charges,
                amount = fine.amount,
                paid = fine.paid or 0,
                owed = math.max(0, (fine.amount or 0) - (fine.paid or 0)),
                status = fine.status or 'unpaid',
                issuedAt = fine.issuedAt,
                dueAt = fine.dueAt,
                overdue = Mdt.isOverdue(fine, nowSeconds),
                citation = fine.citation,
            }
        end
    end

    table.sort(out, function(a, b) return (a.issuedAt or 0) > (b.issuedAt or 0) end)

    return out
end

--- The officer collects a settled fine at the counter. The money goes to the
--- department book, not to the officer - their share was paid at the roadside.
--- @return table result
local function collectFine(source, id, amount)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local store = records()
    local fine

    for _, candidate in ipairs(store.fines or {}) do
        if candidate.id == id then fine = candidate end
    end

    if not fine then return { ok = false, reason = 'unknown_fine' } end
    if (fine.status or 'unpaid') == 'paid' then return { ok = false, reason = 'already_paid' } end
    if (fine.status or 'unpaid') == 'waived' then return { ok = false, reason = 'waived' } end

    local owed = math.max(0, (tonumber(fine.amount) or 0) - (tonumber(fine.paid) or 0))
    local payment = math.floor(tonumber(amount) or owed)

    if payment <= 0 then return { ok = false, reason = 'bad_amount' } end
    if payment > owed then payment = owed end

    fine.paid = (tonumber(fine.paid) or 0) + payment
    fine.status = fine.paid >= (tonumber(fine.amount) or 0) and 'paid' or 'unpaid'
    fine.paidAt = fine.status == 'paid' and epoch() or fine.paidAt

    store.department.balance = (tonumber(store.department.balance) or 0) + payment
    P.save()

    return {
        ok = true,
        id = fine.id,
        amount = payment,
        owed = owed - payment,
        status = fine.status,
        balance = store.department.balance,
        person = fine.person,
    }
end

--- Dismiss a fine (the court waived it, or it was issued in error).
--- @return table result
local function waiveFine(source, id, why)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local fine

    for _, candidate in ipairs(records().fines or {}) do
        if candidate.id == id then fine = candidate end
    end

    if not fine then return { ok = false, reason = 'unknown_fine' } end
    if (fine.status or 'unpaid') == 'paid' then return { ok = false, reason = 'already_paid' } end

    fine.status = 'waived'
    fine.waivedAt = epoch()
    fine.waivedBy = entry.identifier
    fine.waiveReason = Mdt.cleanText(why, 120) or 'waived'
    P.save()

    return { ok = true, id = fine.id, person = fine.person, reason = fine.waiveReason }
end

--- Overdue fines: suspend the licence and put out a warrant, once each.
--- Idempotent - safe to call on every duty start.
--- @return table { overdue, suspended, warrants }
local function sweepOverdue()
    local store = records()
    local rules = config().Justice or {}
    local nowSeconds = epoch()
    local totals = { overdue = 0, suspended = 0, warrants = 0 }
    local touched = {}

    for _, fine in ipairs(store.fines or {}) do
        if Mdt.isOverdue(fine, nowSeconds) then
            totals.overdue = totals.overdue + 1

            local name = Mdt.normalizeName(fine.person)

            if name and not touched[name:lower()] then
                touched[name:lower()] = true

                local person = personRecord(name)

                if person then
                    if rules.suspensionOnOverdue ~= false and person.license ~= 'suspended' then
                        person.license = 'suspended'
                        store.people[Mdt.personKey(name)] = person
                        totals.suspended = totals.suspended + 1
                    end

                    if rules.warrantOnOverdue ~= false then
                        local charge = rules.overdueCharge or 'unpaid_fines'
                        local has = false

                        for _, warrant in ipairs(person.warrants or {}) do
                            if warrant.charge == charge then has = true end
                        end

                        if not has then
                            person.warrants = person.warrants or {}
                            person.warrants[#person.warrants + 1] = {
                                charge = charge,
                                issued = P.isoNow(),
                                amount = Mdt.fineTotals(store.fines, name, nowSeconds).owed,
                            }

                            store.warrants[#store.warrants + 1] = {
                                id = P.newId('WAR'),
                                person = name,
                                charge = charge,
                                note = 'Overdue fines',
                                issuedAt = epoch(),
                                expiresAt = epoch()
                                    + (tonumber((config().Warrants or {}).defaultDays) or 30) * 86400,
                                active = true,
                                auto = true,
                            }

                            totals.warrants = totals.warrants + 1
                        end
                    end
                end
            end
        end
    end

    if totals.suspended > 0 or totals.warrants > 0 then
        P.trim(store.warrants, (config().Warrants or {}).max)
        P.save()
    end

    return totals
end

P.sweepOverdue = sweepOverdue
P.listFines = listFines
exports('ListFines', function(filter) return listFines(filter) end)
exports('CollectFine', function(source, id, amount) return collectFine(source, id, amount) end)
exports('WaiveFine', function(source, id, why) return waiveFine(source, id, why) end)
exports('SweepOverdue', function() return sweepOverdue() end)

RegisterNetEvent('fk_police:server:impound', function(why)
    local source = source
    local result = impoundVehicle(source, why)

    if not result.ok then
        local reasons = {
            no_stop = 'stop a car first',
            already_impounded = 'that car is already on the lot',
        }

        return notify(source, ('Impound failed: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('%s impounded (%s). Fee $%d.'):format(result.plate, result.reason, result.fee))
end)

RegisterNetEvent('fk_police:server:fine:collect', function(id, amount)
    local source = source
    local result = collectFine(source, tostring(id or ''), amount)

    if not result.ok then
        return notify(source, ('Could not collect that fine (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Collected $%d from %s. %s Court fund: $%d.')
        :format(result.amount, tostring(result.person), result.status == 'paid' and 'Paid.' or 'Part-payment.',
            result.balance))
end)

RegisterNetEvent('fk_police:server:fine:waive', function(id, why)
    local source = source
    local result = waiveFine(source, tostring(id or ''), why)

    if not result.ok then
        return notify(source, ('Could not waive that fine (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Fine waived for %s.'):format(tostring(result.person)))
end)

-- ---------------------------------------------------------------------------
-- Warrants
-- ---------------------------------------------------------------------------

--- @return table list
local function listWarrants(filter)
    local options = type(filter) == 'table' and filter or {}
    local out = {}

    for _, warrant in ipairs(records().warrants or {}) do
        local active = warrant.active ~= false
            and (not tonumber(warrant.expiresAt) or tonumber(warrant.expiresAt) > epoch())

        if (not options.active or active) and (not options.person
            or (Mdt.normalizeName(warrant.person) or ''):lower() == (Mdt.normalizeName(options.person) or ''):lower()) then
            out[#out + 1] = {
                id = warrant.id,
                person = warrant.person,
                charge = warrant.charge,
                note = warrant.note,
                issuedAt = warrant.issuedAt,
                expiresAt = warrant.expiresAt,
                active = active,
                auto = warrant.auto == true,
            }
        end
    end

    return out
end

--- @return table result
local function issueWarrant(source, payload)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local data = type(payload) == 'table' and payload or {}
    local name = Mdt.normalizeName(data.person)

    if not name then return { ok = false, reason = 'bad_person' } end

    local charge = Mdt.cleanText(data.charge, 48)

    if not charge then return { ok = false, reason = 'bad_charge' } end

    local person = personRecord(name)

    if not person then return { ok = false, reason = 'unknown_person' } end

    local days = math.max(1, math.floor(tonumber(data.days) or (config().Warrants or {}).defaultDays or 30))
    local store = records()

    for _, warrant in ipairs(person.warrants or {}) do
        if warrant.charge == charge then return { ok = false, reason = 'already_warranted' } end
    end

    person.warrants = person.warrants or {}
    person.warrants[#person.warrants + 1] = { charge = charge, issued = P.isoNow() }
    store.people[Mdt.personKey(name)] = person

    local warrant = {
        id = P.newId('WAR'),
        person = name,
        charge = charge,
        note = Mdt.cleanText(data.note, 120),
        issuedAt = epoch(),
        expiresAt = epoch() + days * 86400,
        active = true,
        officer = entry.identifier,
    }

    store.warrants[#store.warrants + 1] = warrant
    P.trim(store.warrants, (config().Warrants or {}).max)
    P.save()

    return { ok = true, id = warrant.id, person = name, charge = charge, days = days }
end

--- @return table result
local function revokeWarrant(source, id)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local store = records()
    local warrant

    for _, candidate in ipairs(store.warrants or {}) do
        if candidate.id == id then warrant = candidate end
    end

    if not warrant then return { ok = false, reason = 'unknown_warrant' } end
    if warrant.active == false then return { ok = false, reason = 'already_revoked' } end

    warrant.active = false
    warrant.revokedAt = epoch()
    warrant.revokedBy = entry.identifier

    local person = personRecord(warrant.person)

    if person then
        local kept = {}

        for _, item in ipairs(person.warrants or {}) do
            if item.charge ~= warrant.charge then kept[#kept + 1] = item end
        end

        person.warrants = kept
        store.people[Mdt.personKey(warrant.person)] = person
    end

    P.save()

    return { ok = true, id = warrant.id, person = warrant.person, charge = warrant.charge }
end

exports('ListWarrants', function(filter) return listWarrants(filter) end)
exports('IssueWarrant', function(source, payload) return issueWarrant(source, payload) end)
exports('RevokeWarrant', function(source, id) return revokeWarrant(source, id) end)

RegisterNetEvent('fk_police:server:warrant:issue', function(payload)
    local source = source
    local result = issueWarrant(source, payload)

    if not result.ok then
        return notify(source, ('Could not issue that warrant (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Warrant %s issued: %s (%s).'):format(result.id, result.person, result.charge))
end)

RegisterNetEvent('fk_police:server:warrant:revoke', function(id)
    local source = source
    local result = revokeWarrant(source, tostring(id or ''))

    if not result.ok then
        return notify(source, ('Could not revoke that warrant (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Warrant %s revoked for %s.'):format(result.id, result.person))
end)

-- ---------------------------------------------------------------------------
-- BOLOs
-- ---------------------------------------------------------------------------

--- @return table list
local function listBolos()
    local out = {}

    for _, bolo in ipairs(records().bolos or {}) do
        local expired = tonumber(bolo.expiresAt or 0) > 0 and epoch() > tonumber(bolo.expiresAt)

        out[#out + 1] = {
            id = bolo.id,
            kind = bolo.kind or 'vehicle',
            value = bolo.value,
            reason = bolo.reason,
            createdAt = bolo.createdAt,
            expiresAt = bolo.expiresAt,
            active = bolo.active ~= false and not expired,
            expired = expired,
            officer = bolo.officer,
        }
    end

    return out
end

--- @return table result
local function addBolo(source, kind, value, why, minutes)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    kind = kind == 'person' and 'person' or (kind == 'vehicle' and 'vehicle' or nil)

    if not kind then return { ok = false, reason = 'bad_kind' } end

    local normalized = kind == 'vehicle' and Mdt.normalizePlate(value) or Mdt.normalizeName(value)

    if not normalized then return { ok = false, reason = 'bad_value' } end

    local reasonText = Mdt.cleanText(why, 160)

    if not reasonText or #reasonText < 3 then return { ok = false, reason = 'bad_reason' } end

    local rules = config().Bolo or {}
    local lifetime = math.max(1, math.floor(tonumber(minutes) or tonumber(rules.defaultMinutes) or 120))
    local store = records()

    for _, bolo in ipairs(store.bolos or {}) do
        local sameKind = (bolo.kind or 'vehicle') == kind
        local sameValue = tostring(bolo.value):lower() == tostring(normalized):lower()
        local live = bolo.active ~= false and (tonumber(bolo.expiresAt or 0) == 0 or epoch() <= tonumber(bolo.expiresAt))

        if sameKind and sameValue and live then
            return { ok = false, reason = 'already_flagged' }
        end
    end

    local bolo = {
        id = P.newId('BOLO'),
        kind = kind,
        value = normalized,
        reason = reasonText,
        createdAt = epoch(),
        expiresAt = epoch() + lifetime * 60,
        active = true,
        officer = entry.identifier,
    }

    store.bolos[#store.bolos + 1] = bolo
    P.trim(store.bolos, rules.max)
    P.save()

    return { ok = true, id = bolo.id, kind = kind, value = normalized, expiresAt = bolo.expiresAt, minutes = lifetime }
end

--- @return table result
local function clearBolo(source, id)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local bolo

    for _, candidate in ipairs(records().bolos or {}) do
        if candidate.id == id then bolo = candidate end
    end

    if not bolo then return { ok = false, reason = 'unknown_bolo' } end
    if bolo.active == false then return { ok = false, reason = 'already_cleared' } end

    bolo.active = false
    bolo.clearedAt = epoch()
    bolo.clearedBy = entry.identifier
    P.save()

    return { ok = true, id = bolo.id, value = bolo.value }
end

exports('ListBolos', function() return listBolos() end)
exports('AddBolo', function(source, kind, value, why, minutes) return addBolo(source, kind, value, why, minutes) end)
exports('ClearBolo', function(source, id) return clearBolo(source, id) end)

RegisterNetEvent('fk_police:server:bolo:add', function(kind, value, why, minutes)
    local source = source
    local result = addBolo(source, kind, value, why, minutes)

    if not result.ok then
        return notify(source, ('Could not put that BOLO out (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('BOLO %s: %s %s for %d minutes.'):format(result.id, result.kind, result.value, result.minutes))
end)

RegisterNetEvent('fk_police:server:bolo:clear', function(id)
    local source = source
    local result = clearBolo(source, tostring(id or ''))

    if not result.ok then
        return notify(source, ('Could not clear that BOLO (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('BOLO %s cleared (%s).'):format(result.id, result.value))
end)

-- ---------------------------------------------------------------------------
-- Incident reports
-- ---------------------------------------------------------------------------

--- @return table list of summaries, newest first
local function listReports(query)
    local needle = type(query) == 'string' and query:lower() or ''
    local out = {}

    for _, report in ipairs(records().reports or {}) do
        local haystack = ('%s %s %s %s'):format(
            tostring(report.title or ''), tostring(report.body or ''),
            table.concat(report.subjects or {}, ' '), tostring(report.plate or '')):lower()

        if needle == '' or haystack:find(needle, 1, true) then
            out[#out + 1] = {
                id = report.id,
                kind = report.kind,
                title = report.title,
                subjects = report.subjects,
                plate = report.plate,
                charges = report.charges,
                officer = report.officer,
                at = report.at,
                atEpoch = report.atEpoch,
            }
        end
    end

    table.sort(out, function(a, b) return (a.atEpoch or 0) > (b.atEpoch or 0) end)

    return out
end

--- @return table result
local function fileReport(source, payload)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local clean, why = Mdt.validateReport(config(), payload)

    if not clean then return { ok = false, reason = why } end

    local charges = {}

    for _, id in ipairs(clean.charges or {}) do
        local charge = Mdt.charge(config(), id)

        if charge then charges[#charges + 1] = charge.id end
    end

    local store = records()
    local report = {
        id = P.newId('RPT'),
        kind = clean.kind,
        title = clean.title,
        body = clean.body,
        subjects = clean.subjects,
        plate = clean.plate,
        charges = charges,
        officer = entry.identifier,
        officerName = entry.callsign,
        at = P.isoNow(),
        atEpoch = epoch(),
    }

    store.reports[#store.reports + 1] = report
    P.trim(store.reports, (config().Reports or {}).max)
    P.save()

    ensureShift(entry).reports = ensureShift(entry).reports + 1

    local xp = tonumber((config().Reports or {}).xp) or 0

    if xp > 0 then P.addXp(source, xp, 'report filed') end

    return { ok = true, id = report.id, title = report.title, kind = report.kind, xp = xp }
end

exports('ListReports', function(query) return listReports(query) end)
exports('FileReport', function(source, payload) return fileReport(source, payload) end)

RegisterNetEvent('fk_police:server:report:file', function(payload)
    local source = source
    local result = fileReport(source, payload)

    if not result.ok then
        local reasons = {
            bad_title = 'the title is empty or too long',
            title_too_short = 'the title is too short',
            bad_body = 'the report has no body',
            body_too_short = 'the report body is too short',
            body_too_long = 'the report body is too long',
            off_duty = 'go on duty first',
        }

        return notify(source, ('Report not filed: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('Report %s filed: %s (+%d XP).'):format(result.id, result.title, result.xp or 0))
end)

-- ---------------------------------------------------------------------------
-- Impound lot
-- ---------------------------------------------------------------------------

--- @return table list
local function listImpounds(filter)
    local options = type(filter) == 'table' and filter or {}
    local out = {}

    for _, entry in ipairs(records().impounds or {}) do
        if options.released == nil or (entry.released == true) == (options.released == true) then
            out[#out + 1] = {
                id = entry.id,
                plate = entry.plate,
                model = entry.model,
                owner = entry.owner,
                reason = entry.reason,
                fee = entry.fee,
                at = entry.at,
                atEpoch = entry.atEpoch,
                released = entry.released == true,
                releasedAt = entry.releasedAt,
                officer = entry.officer,
            }
        end
    end

    table.sort(out, function(a, b) return (a.atEpoch or 0) > (b.atEpoch or 0) end)

    return out
end

--- Impound the car the officer is actually stopped behind.
--- @return table result
local function impoundVehicle(source, why)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local stop = P.stopFor(source)

    if not stop then return { ok = false, reason = 'no_stop' } end
    if not stop.plate then return { ok = false, reason = 'bad_plate' } end

    local store = records()

    for _, existing in ipairs(store.impounds or {}) do
        if not existing.released and existing.plate == stop.plate then
            return { ok = false, reason = 'already_impounded' }
        end
    end

    local rules = config().Impound or {}
    local stolen = stop.vehicle and stop.vehicle.stolen == true
    local fee = (tonumber(rules.fee) or 500) + (stolen and (tonumber(rules.stolenSurcharge) or 0) or 0)

    local impound = {
        id = P.newId('IMP'),
        plate = stop.plate,
        model = stop.model or (stop.vehicle and stop.vehicle.model) or 'unknown',
        owner = stop.vehicle and stop.vehicle.owner or nil,
        reason = Mdt.cleanText(why, 120) or (stolen and 'stolen vehicle' or 'police seizure'),
        fee = fee,
        at = P.isoNow(),
        atEpoch = epoch(),
        released = false,
        officer = entry.identifier,
    }

    store.impounds[#store.impounds + 1] = impound
    P.trim(store.impounds, rules.max)

    local vehicle = Mdt.findVehicle(store, stop.plate)

    if vehicle then
        vehicle.impounded = true
        store.vehicles[Mdt.vehicleKey(vehicle.plate)] = vehicle
    end

    P.save()

    return {
        ok = true,
        id = impound.id,
        plate = impound.plate,
        fee = fee,
        reason = impound.reason,
        stolen = stolen,
    }
end

--- Release a car from the lot. The fee is taken from the officer's bank - it is
--- the citizen's money in the fiction, and the only account this mod can move.
--- @return table result
local function releaseImpound(source, id)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local store = records()
    local impound

    for _, candidate in ipairs(store.impounds or {}) do
        if candidate.id == id then impound = candidate end
    end

    if not impound then return { ok = false, reason = 'unknown_impound' } end
    if impound.released then return { ok = false, reason = 'already_released' } end

    local ok, result = pcall(function()
        return exports['fk_economy']:RemoveMoney(source, 'bank', math.floor(impound.fee), 'impound release')
    end)

    if not ok then
        P.warn('fk_economy is not running - the impound fee could not be taken.')
        return { ok = false, reason = 'no_economy' }
    end

    if result ~= true then return { ok = false, reason = 'insufficient_funds' } end

    impound.released = true
    impound.releasedAt = P.isoNow()
    impound.releasedBy = entry.identifier

    local vehicle = Mdt.findVehicle(store, impound.plate)

    if vehicle then
        vehicle.impounded = false
        store.vehicles[Mdt.vehicleKey(vehicle.plate)] = vehicle
    end

    store.department.balance = (tonumber(store.department.balance) or 0) + impound.fee
    P.save()

    return { ok = true, id = impound.id, plate = impound.plate, fee = impound.fee, balance = store.department.balance }
end

exports('ListImpounds', function(filter) return listImpounds(filter) end)
exports('ImpoundVehicle', function(source, why) return impoundVehicle(source, why) end)
exports('ReleaseImpound', function(source, id) return releaseImpound(source, id) end)

RegisterNetEvent('fk_police:server:impound:release', function(id)
    local source = source
    local result = releaseImpound(source, tostring(id or ''))

    if not result.ok then
        local reasons = {
            insufficient_funds = 'the fee is not in your bank account',
            already_released = 'that car is already out',
            unknown_impound = 'no such impound record',
        }

        return notify(source, ('Release failed: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('%s released for $%d. Court fund: $%d.'):format(result.plate, result.fee, result.balance))
end)


-- ---------------------------------------------------------------------------
-- Custody: booking and releasing the suspect
-- ---------------------------------------------------------------------------

--- @return table state
local function custodyFor(source)
    local entry = P.officerFor(source, true)

    if not entry or not entry.custody then return { active = false } end

    local custody = entry.custody
    local remaining = math.max(0, (custody.untilEpoch or 0) - epoch())

    if remaining <= 0 then
        entry.custody = nil

        return { active = false, released = custody.id }
    end

    return {
        active = true,
        id = custody.id,
        person = custody.person,
        plate = custody.plate,
        seconds = custody.seconds,
        remaining = remaining,
        cell = (config().Jail or {}).cell,
    }
end

--- Book the person the officer just arrested (or the one in front of them).
--- @return table result
local function bookSuspect(source, seconds)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local current = custodyFor(source)

    if current.active then return { ok = false, reason = 'already_in_custody' } end

    local arrest = P.lastArrest(source)
    local stop = P.stopFor(source)
    local rules = config().Jail or {}
    local cap = math.max(1, tonumber(rules.maxSeconds) or 600)
    local sentence = tonumber(seconds)
        or (arrest and tonumber(arrest.jail))
        or tonumber(rules.defaultSeconds)
        or 120

    sentence = math.max(1, math.min(cap, math.floor(sentence)))

    local person = arrest and arrest.person or (stop and stop.person and stop.person.name) or nil
    local plate = arrest and arrest.plate or (stop and stop.plate) or nil

    if not person and not plate then return { ok = false, reason = 'no_subject' } end

    local booking = {
        id = P.newId('BOOK'),
        person = person or ('Driver of ' .. tostring(plate)),
        plate = plate,
        charges = arrest and arrest.charges or nil,
        seconds = sentence,
        at = P.isoNow(),
        atEpoch = epoch(),
        officer = entry.identifier,
    }

    local store = records()

    store.bookings[#store.bookings + 1] = booking
    P.trim(store.bookings, tonumber(rules.history) or 200)

    entry.custody = {
        id = booking.id,
        person = booking.person,
        plate = booking.plate,
        seconds = sentence,
        untilEpoch = epoch() + sentence,
    }

    P.save()

    TriggerClientEvent('fk_police:client:custody', source, {
        id = booking.id,
        person = booking.person,
        plate = booking.plate,
        seconds = sentence,
        cell = rules.cell,
    })

    return {
        ok = true,
        id = booking.id,
        person = booking.person,
        plate = booking.plate,
        seconds = sentence,
        cell = rules.cell,
    }
end

--- Let the suspect go before the sentence is up.
--- @return table result
local function releaseSuspect(source, why)
    local entry = P.officerFor(source, true)

    if not entry or not entry.custody then return { ok = false, reason = 'no_custody' } end

    local custody = entry.custody
    local served = math.max(0, (tonumber(custody.seconds) or 0) - math.max(0, (custody.untilEpoch or 0) - epoch()))

    entry.custody = nil

    local store = records()

    for _, booking in ipairs(store.bookings or {}) do
        if booking.id == custody.id then
            booking.releasedAt = P.isoNow()
            booking.served = served
            booking.releasedBy = entry.identifier
            booking.releaseReason = Mdt.cleanText(why, 80) or 'released'
        end
    end

    P.save()
    TriggerClientEvent('fk_police:client:custodyEnded', source, {
        id = custody.id,
        person = custody.person,
        served = served,
    })

    return { ok = true, id = custody.id, person = custody.person, served = served }
end

exports('Custody', function(source) return custodyFor(source) end)
exports('BookSuspect', function(source, seconds) return bookSuspect(source, seconds) end)
exports('ReleaseSuspect', function(source, why) return releaseSuspect(source, why) end)

RegisterNetEvent('fk_police:server:jail', function(action, seconds)
    local source = source

    if action == 'release' then
        local result = releaseSuspect(source, 'released by the officer')

        return notify(source, result.ok
            and ('%s released after %s.'):format(result.person, Mdt.formatDuration(result.served))
            or ('Nothing to release (%s).'):format(tostring(result.reason)))
    end

    local result = bookSuspect(source, tonumber(seconds))

    if not result.ok then
        local reasons = {
            no_stop = 'stop a car or make an arrest first',
            no_subject = 'there is nobody to book',
            already_in_custody = 'someone is already in custody',
        }

        return notify(source, ('Booking failed: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('%s booked for %s (%s).'):format(result.person,
        Mdt.formatDuration(result.seconds), tostring(result.id)))
end)

RegisterCommand(config().Commands.jail or 'jail', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('jail is an in-game command.') end

    local action = tostring(args and args[1] or 'book')

    if action == 'release' then
        local result = releaseSuspect(src, 'released at the station')

        return notify(src, result.ok
            and ('%s released after %s.'):format(result.person, Mdt.formatDuration(result.served))
            or ('Nothing to release (%s).'):format(tostring(result.reason)))
    end

    if action == 'status' then
        local state = custodyFor(src)

        return notify(src, state.active
            and ('%s: %s left of %s.'):format(state.person, Mdt.formatDuration(state.remaining),
                Mdt.formatDuration(state.seconds))
            or 'Nobody in custody.')
    end

    local result = bookSuspect(src, tonumber(args and args[2]))

    notify(src, result.ok
        and ('%s booked for %s.'):format(result.person, Mdt.formatDuration(result.seconds))
        or ('Booking failed (%s).'):format(tostring(result.reason)))
end, false)

-- ---------------------------------------------------------------------------
-- Pursuits
-- ---------------------------------------------------------------------------

--- @return table state
local function pursuitFor(source)
    local entry = P.officerFor(source, true)

    if not entry or not entry.pursuit then return { active = false } end

    local state = entry.pursuit

    return {
        active = true,
        id = state.id,
        seconds = math.max(0, epoch() - (state.startedAt or epoch())),
        plate = state.plate,
        callout = state.callout,
        backup = state.backup == true,
    }
end

--- @return table result
local function startPursuit(source)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end
    if entry.pursuit then return { ok = false, reason = 'already_active' } end

    local stop = P.stopFor(source)
    local callout = P.callout()
    local calloutHere = callout and callout.source == source and callout.state == 'accepted'

    if not stop and not calloutHere then return { ok = false, reason = 'no_reason' } end

    local rules = config().Pursuit or {}

    entry.pursuit = {
        id = P.newId('PUR'),
        startedAt = epoch(),
        callout = calloutHere and callout.id or nil,
        plate = stop and stop.plate or nil,
        backup = false,
    }

    if rules.autoBackup ~= false then
        local kind = rules.backupKind or 'code3'
        local option = (config().Backup or {})[kind]

        if type(option) == 'table' then
            TriggerClientEvent('fk_police:client:backup', source, kind, option)
            entry.pursuit.backup = true
        end
    end

    TriggerClientEvent('fk_police:client:pursuit', source, pursuitFor(source))

    return { ok = true, id = entry.pursuit.id, plate = entry.pursuit.plate, backup = entry.pursuit.backup }
end

--- @return table result
local function endPursuit(source, outcome)
    local entry = P.officerFor(source, true)

    if not entry or not entry.pursuit then return { ok = false, reason = 'no_pursuit' } end

    local allowed = (config().Pursuit or {}).outcomes or { 'arrested' }
    local chosen = tostring(outcome or 'terminated')
    local valid = false

    for _, candidate in ipairs(allowed) do
        if candidate == chosen then valid = true end
    end

    if not valid then return { ok = false, reason = 'bad_outcome', allowed = allowed } end

    local pursuit = entry.pursuit
    local seconds = math.max(0, epoch() - (pursuit.startedAt or epoch()))

    entry.pursuit = nil

    local store = records()

    store.pursuits[#store.pursuits + 1] = {
        id = pursuit.id,
        officer = entry.identifier,
        callout = pursuit.callout,
        plate = pursuit.plate,
        startedAt = pursuit.startedAt,
        endedAt = epoch(),
        seconds = seconds,
        outcome = chosen,
    }

    P.trim(store.pursuits, (config().Pursuit or {}).max)
    P.save()

    local xp = 0

    if chosen == 'arrested' then
        xp = 60
        P.addXp(source, xp, 'pursuit ended in an arrest')
    end

    TriggerClientEvent('fk_police:client:pursuit', source, { active = false })

    return { ok = true, id = pursuit.id, seconds = seconds, outcome = chosen, xp = xp }
end

exports('PursuitState', function(source) return pursuitFor(source) end)
exports('ListPursuits', function()
    local out = {}

    for index = #(records().pursuits or {}), 1, -1 do out[#out + 1] = records().pursuits[index] end

    return out
end)

RegisterNetEvent('fk_police:server:pursuit:start', function()
    local source = source
    local result = startPursuit(source)

    if not result.ok then
        return notify(source, ('Pursuit not started (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Pursuit %s started. %s'):format(result.id,
        result.backup and 'Code 3 backup is en route.' or 'No backup available.'))
end)

RegisterNetEvent('fk_police:server:pursuit:end', function(outcome)
    local source = source
    local result = endPursuit(source, outcome)

    if not result.ok then
        return notify(source, ('Pursuit not closed (%s).'):format(tostring(result.reason)))
    end

    notify(source, ('Pursuit over after %s: %s.%s'):format(Mdt.formatDuration(result.seconds), result.outcome,
        result.xp > 0 and (' +%d XP.'):format(result.xp) or ''))
end)

-- ---------------------------------------------------------------------------
-- Field work: frisk, breath test, K9
-- ---------------------------------------------------------------------------

--- @return table result
local function frisk(source, name)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local stop = P.stopFor(source)
    local person, subject = subjectFor(source, name)

    if not person and not stop then return { ok = false, reason = 'no_subject' } end

    if not person and stop then
        -- Somebody the database has never heard of: an empty record.
        person = { name = subject or ('Driver of ' .. tostring(stop.plate)), license = 'valid', warrants = {} }
    end

    local found = Mdt.frisk(config(), person)

    return {
        ok = true,
        person = person.name,
        items = found.items,
        hasWeapon = found.hasWeapon,
        weaponFlag = found.hasWeapon,
    }
end

--- @return table result
local function breathalyzer(source, name)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local person, subject = subjectFor(source, name)
    local stop = P.stopFor(source)

    if not person and not stop then return { ok = false, reason = 'no_subject' } end

    local test = Mdt.breathalyzer(config(), person or { name = subject or ('Driver of ' .. tostring(stop.plate)) })

    return {
        ok = true,
        person = person and person.name or (subject or 'the driver'),
        bac = test.bac,
        limit = test.limit,
        over = test.over,
        charge = test.over and 'dui' or nil,
    }
end

--- The dog works the car or the person in front of it.
--- @return table result
local function k9(source)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local stop = P.stopFor(source)

    if not stop then return { ok = false, reason = 'no_stop' } end

    local rules = (config().Field or {}).k9 or {}
    local hits = {}
    local person = stop.person

    for _, warrant in ipairs(person and person.warrants or {}) do
        for _, charge in ipairs(rules.hits or {}) do
            if warrant.charge == charge then hits[#hits + 1] = warrant.charge end
        end
    end

    if stop.vehicle and stop.vehicle.stolen then hits[#hits + 1] = 'stolen' end

    local roll = Mdt.hash01(tostring(stop.plate or 'plate') .. ':k9')
    local alert = #hits > 0 or roll > 0.86

    return {
        ok = true,
        plate = stop.plate,
        alert = alert,
        hits = hits,
        message = alert and 'The dog alerts on the vehicle.' or 'The dog shows no interest.',
    }
end

exports('Frisk', function(source, name) return frisk(source, name) end)
exports('Breathalyzer', function(source, name) return breathalyzer(source, name) end)
exports('K9', function(source) return k9(source) end)

RegisterNetEvent('fk_police:server:field', function(tool, name)
    local source = source
    local kind = tostring(tool or 'frisk')
    local result

    if kind == 'frisk' then result = frisk(source, name)
    elseif kind == 'breath' then result = breathalyzer(source, name)
    elseif kind == 'k9' then result = k9(source)
    else return notify(source, ('Unknown field tool (%s).'):format(kind)) end

    if not result.ok then
        return notify(source, ('Nothing to search (%s).'):format(tostring(result.reason)))
    end

    TriggerClientEvent('fk_police:client:field', source, kind, result)

    if kind == 'frisk' then
        local names = {}

        for _, item in ipairs(result.items) do names[#names + 1] = ('%s x%d'):format(item.label, item.qty) end

        notify(source, ('Frisk of %s: %s.'):format(result.person,
            #names > 0 and table.concat(names, ', ') or 'nothing found'))

        if result.hasWeapon then notify(source, '*** CONCEALED WEAPON ***') end
    elseif kind == 'breath' then
        notify(source, ('Breath test %s: %.2f%% (limit %.2f%%) - %s.'):format(result.person, result.bac,
            result.limit, result.over and 'OVER THE LIMIT, charge dui' or 'under the limit'))
    else
        notify(source, ('K9 on %s: %s'):format(tostring(result.plate), result.message))
    end
end)

-- ---------------------------------------------------------------------------
-- The MDT bundle: one round trip for everything the page lists
-- ---------------------------------------------------------------------------

--- @return table
local function mdtBundle(source)
    local store = records()
    local entry = P.officerFor(source, true)
    local status = P.statusOf(source)
    local nowSeconds = epoch()
    local fines = listFines({})
    local totals = Mdt.fineTotals(store.fines, nil, nowSeconds)

    return {
        status = status,
        progress = Mdt.xpProgress(config(), status.xp),
        shift = shiftStatus(source),
        charges = config().Charges,
        callouts = config().Callouts,
        backup = config().Backup,
        bolos = listBolos(),
        reports = listReports(''),
        fines = { list = fines, totals = totals },
        warrants = listWarrants({}),
        impounds = listImpounds({}),
        shifts = (function()
            local out = {}

            for index = #(store.shifts or {}), 1, -1 do
                if entry and store.shifts[index].officer == entry.identifier then out[#out + 1] = store.shifts[index] end
                if #out >= 10 then break end
            end

            return out
        end)(),
        pursuits = (function()
            local out = {}

            for index = #(store.pursuits or {}), 1, -1 do
                out[#out + 1] = store.pursuits[index]
                if #out >= 10 then break end
            end

            return out
        end)(),
        department = { balance = store.department.balance or 0, label = (config().Justice or {}).departmentLabel },
        pursuit = pursuitFor(source),
        custody = custodyFor(source),
        callout = P.callout() or false,
    }
end

P.mdtBundle = mdtBundle
exports('GetMdt', function(source) return mdtBundle(source) end)

RegisterNetEvent('fk_police:server:mdt', function()
    local source = source

    TriggerClientEvent('fk_police:client:mdt', source, mdtBundle(source))
end)

-- ---------------------------------------------------------------------------
-- Commands (server-side: they work in chat, in the console, and without keys)
-- ---------------------------------------------------------------------------

local function split(args, from)
    local out = {}

    for index = from or 1, #(args or {}) do out[#out + 1] = args[index] end

    return out
end

RegisterCommand(config().Commands.report or 'report', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('report is an in-game command.') end

    local title = table.concat(split(args, 1), ' ')

    if title == '' then
        return notify(src, 'Usage: /report <title> - then fill the report in the MDT (Reports tab).')
    end

    TriggerClientEvent('fk_police:client:reportDraft', src, title)
    notify(src, ('Report "%s": fill in the details in the MDT Reports tab.'):format(title))
end, false)

RegisterCommand(config().Commands.bolo or 'bolo', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('bolo is an in-game command.') end

    local action = tostring(args and args[1] or 'list')

    if action == 'list' then
        local bolos = listBolos()

        if #bolos == 0 then return notify(src, 'No BOLOs on the board.') end

        for _, bolo in ipairs(bolos) do
            notify(src, ('  %s %s %s - %s%s'):format(bolo.id, bolo.kind, bolo.value, bolo.reason,
                bolo.active and '' or ' (cleared)'))
        end

        return
    end

    if action == 'clear' then
        local result = clearBolo(src, tostring(args[2] or ''))

        return notify(src, result.ok and ('BOLO %s cleared.'):format(result.id)
            or ('Could not clear that BOLO (%s).'):format(tostring(result.reason)))
    end

    if action == 'add' then
        local kind = 'vehicle'
        local value = args[2]
        local rest = split(args, 3)

        if tostring(args[2] or ''):lower() == 'person' then
            kind = 'person'
            value = args[3]
            rest = split(args, 4)
        end

        local result = addBolo(src, kind, value, table.concat(rest, ' '))

        return notify(src, result.ok
            and ('BOLO %s: %s %s for %d minutes.'):format(result.id, result.kind, result.value, result.minutes)
            or ('Could not put that BOLO out (%s).'):format(tostring(result.reason)))
    end

    notify(src, 'Usage: /bolo add <plate|person <name>> <reason> | /bolo list | /bolo clear <id>')
end, false)

RegisterCommand(config().Commands.warrant or 'warrant', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('warrant is an in-game command.') end

    local action = tostring(args and args[1] or 'list')

    if action == 'list' then
        local list = listWarrants({ active = true })

        if #list == 0 then return notify(src, 'No active warrants.') end

        for _, warrant in ipairs(list) do
            notify(src, ('  %s %s - %s'):format(warrant.id, warrant.person, warrant.charge))
        end

        return
    end

    if action == 'add' then
        local result = issueWarrant(src, {
            person = args[2],
            charge = args[3] or 'assault',
            note = table.concat(split(args, 4), ' '),
        })

        return notify(src, result.ok
            and ('Warrant %s issued: %s (%s).'):format(result.id, result.person, result.charge)
            or ('Could not issue that warrant (%s).'):format(tostring(result.reason)))
    end

    if action == 'revoke' then
        local result = revokeWarrant(src, tostring(args[2] or ''))

        return notify(src, result.ok and ('Warrant %s revoked.'):format(result.id)
            or ('Could not revoke that warrant (%s).'):format(tostring(result.reason)))
    end

    notify(src, 'Usage: /warrant add <name> <charge> | /warrant list | /warrant revoke <id>')
end, false)

RegisterCommand(config().Commands.fine or 'fine', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('fine is an in-game command.') end

    local action = tostring(args and args[1] or 'list')

    if action == 'list' then
        local fines = listFines({ person = args[2] })
        local totals = Mdt.fineTotals(records().fines, args[2], epoch())

        if #fines == 0 then return notify(src, 'No fines on the ledger.') end

        for _, fine in ipairs(fines) do
            notify(src, ('  %s %s $%d owed, due %s%s'):format(fine.id, tostring(fine.person), fine.owed,
                os.date('!%Y-%m-%d', fine.dueAt or epoch()), fine.overdue and ' [OVERDUE]' or ''))
        end

        return notify(src, ('Ledger: %d fine(s), $%d outstanding, court fund $%d.')
            :format(totals.count, totals.owed, records().department.balance or 0))
    end

    if action == 'collect' then
        local result = collectFine(src, tostring(args[2] or ''), tonumber(args[3]))

        return notify(src, result.ok
            and ('Collected $%d from %s. Court fund: $%d.'):format(result.amount, tostring(result.person), result.balance)
            or ('Could not collect that fine (%s).'):format(tostring(result.reason)))
    end

    if action == 'waive' then
        local result = waiveFine(src, tostring(args[2] or ''), table.concat(split(args, 3), ' '))

        return notify(src, result.ok and ('Fine waived for %s.'):format(tostring(result.person))
            or ('Could not waive that fine (%s).'):format(tostring(result.reason)))
    end

    if action == 'sweep' then
        local swept = sweepOverdue()

        return notify(src, ('Court sweep: %d overdue, %d licence(s) suspended, %d warrant(s).')
            :format(swept.overdue, swept.suspended, swept.warrants))
    end

    notify(src, 'Usage: /fine list [name] | /fine collect <id> [amount] | /fine waive <id> | /fine sweep')
end, false)

RegisterCommand(config().Commands.impound or 'impound', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('impound is an in-game command.') end

    local action = tostring(args and args[1] or 'tow')

    if action == 'list' then
        local list = listImpounds({ released = false })

        if #list == 0 then return notify(src, 'The impound lot is empty.') end

        for _, entry in ipairs(list) do
            notify(src, ('  %s %s (%s) $%d - %s'):format(entry.id, entry.plate, tostring(entry.model),
                entry.fee, tostring(entry.reason)))
        end

        return
    end

    if action == 'release' then
        local result = releaseImpound(src, tostring(args[2] or ''))

        return notify(src, result.ok
            and ('%s released for $%d.'):format(result.plate, result.fee)
            or ('Release failed (%s).'):format(tostring(result.reason)))
    end

    local result = impoundVehicle(src, table.concat(split(args, 1), ' '))

    notify(src, result.ok
        and ('%s impounded (%s). Fee $%d.'):format(result.plate, result.reason, result.fee)
        or ('Could not impound that car (%s).'):format(tostring(result.reason)))
end, false)

RegisterCommand(config().Commands.pursuit or 'pursuit', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('pursuit is an in-game command.') end

    local action = tostring(args and args[1] or 'start')

    if action == 'status' then
        local state = pursuitFor(src)

        return notify(src, state.active
            and ('Pursuit %s: %s.'):format(state.id, Mdt.formatDuration(state.seconds))
            or 'No pursuit running.')
    end

    if action == 'end' then
        local result = endPursuit(src, args[2] or 'terminated')

        return notify(src, result.ok
            and ('Pursuit closed after %s: %s.'):format(Mdt.formatDuration(result.seconds), result.outcome)
            or ('Pursuit not closed (%s).'):format(tostring(result.reason)))
    end

    local result = startPursuit(src)

    notify(src, result.ok
        and ('Pursuit %s started.%s'):format(result.id, result.backup and ' Code 3 backup en route.' or '')
        or ('Pursuit not started (%s).'):format(tostring(result.reason)))
end, false)

RegisterCommand(config().Commands.frisk or 'frisk', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('frisk is an in-game command.') end

    local result = frisk(src, args and args[1])

    if not result.ok then return notify(src, ('Nothing to search (%s).'):format(tostring(result.reason))) end

    local names = {}

    for _, item in ipairs(result.items) do names[#names + 1] = ('%s x%d'):format(item.label, item.qty) end

    notify(src, ('Frisk of %s: %s.'):format(result.person,
        #names > 0 and table.concat(names, ', ') or 'nothing found'))
end, false)

RegisterCommand(config().Commands.breath or 'breath', function(source, args)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('breath is an in-game command.') end

    local result = breathalyzer(src, args and args[1])

    if not result.ok then return notify(src, ('No one to test (%s).'):format(tostring(result.reason))) end

    notify(src, ('Breath test %s: %.2f%% - %s.'):format(result.person, result.bac,
        result.over and 'OVER THE LIMIT (charge dui)' or 'under the limit'))
end, false)

RegisterCommand(config().Commands.k9 or 'k9', function(source)
    local src = tonumber(source)

    if not src or src < 1 then return P.log('k9 is an in-game command.') end

    local result = k9(src)

    notify(src, result.ok and result.message or ('No car to search (%s).'):format(tostring(result.reason)))
end, false)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

P.log(('justice ready: %d fine(s), %d warrant(s), %d BOLO(s), %d report(s), %d impound(s), %d shift(s).')
    :format(#(records().fines or {}), #(records().warrants or {}), #(records().bolos or {}),
        #(records().reports or {}), #(records().impounds or {}), #(records().shifts or {})))
