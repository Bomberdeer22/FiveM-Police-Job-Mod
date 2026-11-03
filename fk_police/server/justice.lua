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
                contest = fine.contest,
                camera = fine.camera,
                cameraLabel = fine.cameraLabel,
                speedKmh = fine.speedKmh,
                limitKmh = fine.limitKmh,
                source = fine.source,
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

    TriggerClientEvent('fk_police:client:impound', source, {
        id = impound.id,
        plate = impound.plate,
        model = impound.model,
    })

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
-- Evidence: what the search turned up, kept on file
-- ---------------------------------------------------------------------------

--- Store seized items against a person. Frisk and booking both call this, so a
--- case file grows from the search, not only from the charge sheet.
--- @return table|nil the evidence entry
local function addEvidence(source, person, items, kind, note)
    if type(person) ~= 'string' or person == '' then return nil end
    if type(items) ~= 'table' or #items == 0 then return nil end

    local entry = P.officerFor(source, true)
    local store = records()
    local rules = config().Evidence or {}

    local evidence = {
        id = P.newId('EVD'),
        person = person,
        kind = kind or 'seized',
        note = Mdt.cleanText(note, 120) or nil,
        items = {},
        at = P.isoNow(),
        atEpoch = epoch(),
        officer = entry and entry.identifier or nil,
    }

    for _, item in ipairs(items) do
        evidence.items[#evidence.items + 1] = {
            id = item.id or item.label,
            label = Mdt.cleanText(item.label or item.id, 60),
            qty = math.max(1, math.floor(tonumber(item.qty) or 1)),
        }
    end

    store.evidence[#store.evidence + 1] = evidence
    P.trim(store.evidence, tonumber(rules.max) or 400)

    P.save()

    return evidence
end

--- Evidence held against a person.
--- @return table list
local function evidenceFor(person)
    local out = {}
    local target = type(person) == 'string' and person:lower() or nil

    for index = #(records().evidence or {}), 1, -1 do
        local item = records().evidence[index]

        if not target or tostring(item.person or ''):lower() == target then out[#out + 1] = item end
        if #out >= 40 then break end
    end

    return out
end

P.addEvidence = addEvidence

-- ---------------------------------------------------------------------------
-- Verdicts: the court's decision when a suspect leaves custody
-- ---------------------------------------------------------------------------

--- Close a booking and let the court rule on it.
--- A guilty verdict keeps the fine and the court fund; an acquittal returns the
--- money and waives whatever the person still owes on this case.
--- @return table verdict
local function finishCustody(entry, custody, why)
    local store = records()
    local justice = config().Justice or {}
    local outcome = Mdt.verdict(config(), custody.id, justice.verdictChance)
    local verdict = {
        id = P.newId('VRD'),
        booking = custody.id,
        person = custody.person,
        plate = custody.plate,
        outcome = outcome,
        at = P.isoNow(),
        atEpoch = epoch(),
        reason = Mdt.cleanText(why, 80) or 'released',
        officer = entry and entry.identifier or nil,
    }

    local booking

    for _, candidate in ipairs(store.bookings or {}) do
        if candidate.id == custody.id then booking = candidate end
    end

    if booking then
        booking.releasedAt = P.isoNow()
        booking.served = custody.served
        booking.releasedBy = entry and entry.identifier or nil
        booking.releaseReason = verdict.reason
        booking.verdict = outcome
    end

    if outcome == 'acquitted' and justice.acquitRefund ~= false then
        local refunded = 0

        for _, fine in ipairs(store.fines or {}) do
            local same = tostring(fine.person or ''):lower() == tostring(custody.person or ''):lower()
            local owed = math.max(0, (tonumber(fine.amount) or 0) - (tonumber(fine.paid) or 0))

            if same and (fine.status or 'unpaid') ~= 'paid' and owed > 0 then
                fine.status = 'waived'
                fine.waivedAt = P.isoNow()
                fine.waivedBy = 'court'
                fine.waiveReason = 'acquitted'
                refunded = refunded + owed
            end
        end

        if refunded > 0 then
            store.department.balance = math.max(0, (tonumber(store.department.balance) or 0) - refunded)
            verdict.refund = refunded
        end
    end

    store.verdicts[#store.verdicts + 1] = verdict

    local limits = config().Justice or {}

    P.trim(store.verdicts, tonumber(limits.maxVerdicts) or 250)

    return verdict
end

--- Verdicts, newest first, optionally for one person.
--- @return table list
local function verdictsFor(person)
    local out = {}
    local target = type(person) == 'string' and person:lower() ~= '' and person:lower() or nil
    local store = records()

    for index = #(store.verdicts or {}), 1, -1 do
        local verdict = store.verdicts[index]

        if not target or tostring(verdict.person or ''):lower() == target then out[#out + 1] = verdict end
        if #out >= 50 then break end
    end

    return out
end

P.finishCustody = finishCustody
P.verdictsFor = verdictsFor

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

        local verdict = finishCustody(entry, {
            id = custody.id,
            person = custody.person,
            plate = custody.plate,
            served = tonumber(custody.seconds) or 0,
        }, 'sentence served')

        P.save()
        TriggerClientEvent('fk_police:client:custodyEnded', source, {
            id = custody.id,
            person = custody.person,
            served = tonumber(custody.seconds) or 0,
            verdict = verdict and verdict.outcome or nil,
        })

        return { active = false, released = custody.id, verdict = verdict and verdict.outcome or nil }
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

    if arrest and type(arrest.charges) == 'table' and #arrest.charges > 0 then
        local items = {}

        local catalogue = config().Charges or {}

        for _, charge in ipairs(arrest.charges) do
            local id = type(charge) == 'table' and (charge.id or charge.code) or tostring(charge)
            local label

            for _, known in ipairs(catalogue) do
                if known.id == id then label = known.label end
            end

            items[#items + 1] = { id = id, label = label or id, qty = 1 }
        end

        addEvidence(source, booking.person, items, 'booking', booking.id)
    end

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

    local verdict = finishCustody(entry, {
        id = custody.id,
        person = custody.person,
        plate = custody.plate,
        served = served,
    }, why)

    P.save()
    TriggerClientEvent('fk_police:client:custodyEnded', source, {
        id = custody.id,
        person = custody.person,
        served = served,
        verdict = verdict and verdict.outcome or nil,
    })

    return {
        ok = true,
        id = custody.id,
        person = custody.person,
        served = served,
        verdict = verdict and verdict.outcome or nil,
        refund = verdict and verdict.refund or nil,
    }
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

    if #found.items > 0 then
        addEvidence(source, person.name, found.items, 'frisk', 'found during a search')
    end

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
exports('ListVerdicts', function(person) return verdictsFor(person) end)
exports('ListEvidence', function(person) return evidenceFor(person) end)

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
-- Forensics lab
-- ---------------------------------------------------------------------------
-- A sample goes in, the lab answers later. Nothing about the answer is decided
-- by the client: the kind, the wait and the roll all live here.

--- The live source still connected as this identifier, if any.
--- @return number|nil
local function sourceForIdentifier(identifier)
    if not identifier then return nil end

    for source, entry in pairs(P.officers or {}) do
        if entry.identifier == identifier then return source end
    end

    return nil
end

--- Samples, newest first, optionally for one person.
--- @return table
local function forensicsFor(filter)
    local options = type(filter) == 'table' and filter or {}
    local person = Mdt.normalizeName(options.person)
    local store = records()
    local out = {}

    for index = #(store.forensics or {}), 1, -1 do
        local sample = store.forensics[index]

        if not person or (Mdt.normalizeName(sample.person) or ''):lower() == person:lower() then
            out[#out + 1] = sample
        end

        if #out >= 50 then break end
    end

    return out
end

--- Close every sample whose lab time is up. Idempotent - safe on a timer.
--- @return number completed
local function settleForensics(nowSeconds)
    local store = records()
    local now = tonumber(nowSeconds) or epoch()
    local completed = 0

    for _, sample in ipairs(store.forensics or {}) do
        if sample.status == 'pending' and (tonumber(sample.readyAt) or 0) <= now then
            sample.status = 'done'
            sample.result = Mdt.sampleResult(config(), sample.id, sample.kind, sample.person)
            sample.completedAt = now
            completed = completed + 1

            local source = sourceForIdentifier(sample.officer)

            if source then
                notify(source, ('Lab result for %s (%s): %s.'):format(tostring(sample.person), tostring(sample.label),
                    tostring(sample.result.detail)))
                TriggerClientEvent('fk_police:client:lab', source, sample)
            end
        end
    end

    if completed > 0 then P.save() end

    return completed
end

--- Submit a sample. The suspect defaults to whoever is stopped.
--- @return table result
local function submitForensics(source, kindId, name)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local rules = config().Forensics or {}
    local kind = Mdt.forensicsKind(config(), kindId)

    if not kind then return { ok = false, reason = 'unknown_kind' } end

    local person, wanted = subjectFor(source, name)
    local stop = P.stopFor(source)
    local plate = person and person.plate or (stop and stop.plate) or nil

    if not wanted then return { ok = false, reason = 'no_subject' } end

    local store = records()
    local sample = {
        id = P.newId('LAB'),
        kind = kind.id,
        label = kind.label,
        person = wanted,
        plate = plate,
        status = 'pending',
        submittedAt = epoch(),
        readyAt = epoch() + math.max(1, tonumber(rules.labSeconds) or 45),
        officer = entry.identifier,
    }

    store.forensics[#store.forensics + 1] = sample

    -- Keep the per-person pile small: drop their oldest sample once over the cap.
    local cap = tonumber(rules.maxPerPerson) or 20
    local mine = {}

    for _, candidate in ipairs(store.forensics) do
        if (Mdt.normalizeName(candidate.person) or ''):lower() == wanted:lower() then mine[#mine + 1] = candidate end
    end

    while #mine > cap do
        local drop = table.remove(mine, 1)

        for index = #store.forensics, 1, -1 do
            if store.forensics[index] == drop then table.remove(store.forensics, index) end
        end
    end

    P.trim(store.forensics, tonumber(rules.max) or 300)
    P.save()
    P.addXp(source, tonumber(rules.xp) or 10, 'forensic sample')

    return {
        ok = true,
        id = sample.id,
        kind = kind.id,
        label = kind.label,
        person = wanted,
        readyIn = math.max(0, (sample.readyAt or 0) - epoch()),
        xp = tonumber(rules.xp) or 10,
    }
end

exports('SubmitForensics', function(source, kind, name) return submitForensics(source, kind, name) end)
exports('ListForensics', function(filter) return forensicsFor(filter) end)
exports('SettleForensics', function(nowSeconds) return settleForensics(nowSeconds) end)

RegisterNetEvent('fk_police:server:lab', function(kind, name)
    local source = source
    local result = submitForensics(source, kind, name)

    if not result.ok then
        local reasons = {
            no_subject = 'stop a car or name a person first',
            unknown_kind = 'use dna, drugs, ballistics or prints',
            off_duty = 'go on duty first',
            no_identifier = 'go on duty first',
        }

        return notify(source, ('Lab: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('Sample %s (%s) taken from %s - the lab needs %s.'):format(tostring(result.id),
        tostring(result.label), tostring(result.person), Mdt.formatDuration(result.readyIn)))
end)

-- ---------------------------------------------------------------------------
-- Bail and court dates
-- ---------------------------------------------------------------------------
-- Bail is the third way out of custody: the suspect pays, walks, and owes the
-- court a date. Missing the date is what turns this into a warrant.

--- Warrants the court issues to itself (no officer at the keyboard).
--- @return table|nil warrant
local function autoWarrant(name, charge, note, days)
    local store = records()
    local person = personRecord(name)

    if not person then return nil end

    person.warrants = person.warrants or {}
    person.warrants[#person.warrants + 1] = { charge = charge, issued = P.isoNow() }

    local warrant = {
        id = P.newId('WAR'),
        person = person.name or name,
        charge = charge,
        note = Mdt.cleanText(note, 120),
        issuedAt = epoch(),
        expiresAt = epoch() + math.max(1, tonumber(days) or 30) * 86400,
        active = true,
        officer = 'court',
        auto = true,
    }

    store.warrants[#store.warrants + 1] = warrant
    P.trim(store.warrants, (config().Warrants or {}).max)

    return warrant
end

--- Bail docket, newest first, with the time left on each date worked out now.
--- @return table
local function listBails(filter)
    local options = type(filter) == 'table' and filter or {}
    local person = Mdt.normalizeName(options.person)
    local nowSeconds = epoch()
    local store = records()
    local out = {}

    for index = #(store.bails or {}), 1, -1 do
        local bail = store.bails[index]
        local matches = true

        if person and (Mdt.normalizeName(bail.person) or ''):lower() ~= person:lower() then matches = false end
        if options.status and (bail.status or 'posted') ~= options.status then matches = false end

        if matches then
            out[#out + 1] = {
                id = bail.id,
                booking = bail.booking,
                person = bail.person,
                plate = bail.plate,
                amount = bail.amount,
                status = bail.status or 'posted',
                outcome = bail.outcome,
                courtAt = bail.courtAt,
                daysLeft = math.max(0, math.ceil(((tonumber(bail.courtAt) or nowSeconds) - nowSeconds) / 86400)),
                postedAt = bail.postedAt,
                officer = bail.officer,
                warrant = bail.warrant,
                refund = bail.refund,
                note = bail.note,
            }
        end

        if #out >= 50 then break end
    end

    return out
end

--- The court rules on a bailed suspect who has turned up (or has not).
--- @return table bail
local function hearBail(bail, nowSeconds)
    local rules = config().Bail or {}
    local justice = config().Justice or {}
    local store = records()
    local now = tonumber(nowSeconds) or epoch()
    local appeared = Mdt.hash01(tostring(bail.id) .. ':appear') < (tonumber(rules.appearChance) or 0.7)

    bail.heardAt = now

    if appeared then
        local outcome = Mdt.verdict(config(), tostring(bail.booking or bail.id), justice.verdictChance)

        bail.status = 'heard'
        bail.outcome = outcome

        if outcome == 'acquitted' then
            -- The court hands the bail back out of the fund.
            bail.refund = tonumber(bail.amount) or 0
            store.department.balance = math.max(0, (tonumber(store.department.balance) or 0) - (tonumber(bail.amount) or 0))
        end
    else
        bail.status = 'failed'

        if rules.warrantOnFail ~= false then
            local warrant = autoWarrant(bail.person, rules.failCharge or 'failure_to_appear',
                ('missed court date %s'):format(tostring(bail.id)), 30)

            if warrant then bail.warrant = warrant.id end
        end
    end

    return bail
end

--- Walk the docket: any date that has passed is heard. Idempotent.
--- @return number heard
local function sweepCourtDates(nowSeconds)
    local store = records()
    local now = tonumber(nowSeconds) or epoch()
    local heard = 0

    for _, bail in ipairs(store.bails or {}) do
        if (bail.status or 'posted') == 'posted' and (tonumber(bail.courtAt) or math.huge) <= now then
            hearBail(bail, now)
            heard = heard + 1
        end
    end

    if heard > 0 then P.save() end

    return heard
end

--- What bail would cost for the suspect in custody right now.
--- @return table quote
local function bailQuote(source)
    local entry = P.officerFor(source, true)

    if not entry or not entry.custody then return { ok = false, reason = 'no_custody' } end

    local rules = config().Bail or {}
    local amount = Mdt.bailAmount(config(), entry.custody.seconds)

    return {
        ok = true,
        booking = entry.custody.id,
        person = entry.custody.person,
        seconds = entry.custody.seconds,
        amount = amount,
        courtDays = tonumber(rules.courtDays) or 14,
    }
end

--- Post bail: the suspect pays, custody ends without a verdict, a date is set.
--- @return table result
local function postBail(source, amount, why)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local rules = config().Bail or {}

    if rules.enabled == false then return { ok = false, reason = 'disabled' } end

    local custody = entry.custody

    if not custody then return { ok = false, reason = 'no_custody' } end

    local due = Mdt.bailAmount(config(), custody.seconds)
    local paid = math.floor(tonumber(amount) or due)

    if paid < due then return { ok = false, reason = 'short_payment', due = due } end

    local store = records()
    local nowSeconds = epoch()
    local bail = {
        id = P.newId('BAIL'),
        booking = custody.id,
        person = custody.person,
        plate = custody.plate,
        amount = paid,
        due = due,
        status = 'posted',
        postedAt = nowSeconds,
        courtAt = nowSeconds + math.max(1, tonumber(rules.courtDays) or 14) * 86400,
        officer = entry.identifier,
        note = Mdt.cleanText(why, 120),
    }

    store.bails[#store.bails + 1] = bail
    P.trim(store.bails, tonumber(rules.history) or 200)
    store.department.balance = (tonumber(store.department.balance) or 0) + paid

    -- Close the booking without a court verdict: the case is pending a date.
    for _, booking in ipairs(store.bookings or {}) do
        if booking.id == custody.id then
            booking.releasedAt = P.isoNow()
            booking.releasedBy = entry.identifier
            booking.releaseReason = 'bail posted'
            booking.bail = bail.id
        end
    end

    entry.custody = nil
    P.save()

    TriggerClientEvent('fk_police:client:custodyEnded', source, {
        id = custody.id,
        person = custody.person,
        served = 0,
        verdict = nil,
        bail = bail.id,
    })

    return {
        ok = true,
        id = bail.id,
        person = bail.person,
        amount = paid,
        courtAt = bail.courtAt,
        courtDays = math.max(1, tonumber(rules.courtDays) or 14),
    }
end

exports('ListBails', function(filter) return listBails(filter) end)
exports('PostBail', function(source, amount, why) return postBail(source, amount, why) end)
exports('BailQuote', function(source) return bailQuote(source) end)
exports('SweepCourtDates', function(nowSeconds) return sweepCourtDates(nowSeconds) end)

RegisterNetEvent('fk_police:server:bail', function(amount, why)
    local source = source
    local result = postBail(source, amount, why)

    if not result.ok then
        local reasons = {
            no_custody = 'nobody is in custody',
            short_payment = ('bail is $%d'):format(tonumber(result.due) or 0),
            off_duty = 'go on duty first',
            no_identifier = 'go on duty first',
            disabled = 'bail is turned off in the config',
        }

        return notify(source, ('Bail: %s.'):format(reasons[result.reason] or tostring(result.reason)))
    end

    notify(source, ('%s released on $%d bail (%s) - court date in %d days.'):format(tostring(result.person),
        math.floor(result.amount), tostring(result.id), result.courtDays))
end)

RegisterNetEvent('fk_police:server:court', function(action, id)
    local source = source
    local entry, reason = onDuty(source)

    if not entry then return notify(source, 'Go on duty first.') end

    if action == 'attend' and id then
        local store = records()

        for _, bail in ipairs(store.bails or {}) do
            if bail.id == id and (bail.status or 'posted') == 'posted' then
                hearBail(bail, epoch())
                P.save()

                return notify(source, ('%s: %s%s.'):format(tostring(bail.person), tostring(bail.status),
                    bail.outcome and (' (' .. tostring(bail.outcome) .. ')') or ''))
            end
        end

        return notify(source, 'No such open court date.')
    end

    local open = listBails({ status = 'posted' })

    if #open == 0 then return notify(source, 'No court dates on the docket.') end

    for index = 1, math.min(#open, 5) do
        local bail = open[index]

        notify(source, ('%s - %s, $%d, %d days left.'):format(tostring(bail.id), tostring(bail.person),
            math.floor(tonumber(bail.amount) or 0), tonumber(bail.daysLeft) or 0))
    end
end)

-- ---------------------------------------------------------------------------
-- Stolen vehicle hotlist
-- ---------------------------------------------------------------------------
-- The list the ANPR compares against. Dispatch can flag a plate by itself, and
-- the officer can add one from a stop.

--- The hotlist, expired entries dropped.
--- @return table
local function listHotlist()
    return Mdt.activeHotlist(records().hotlist, epoch())
end

--- Flag a plate as stolen.
--- @return table result
local function addHotlist(source, plate, minutes, reason, options)
    local opts = type(options) == 'table' and options or {}
    local normalized = Mdt.normalizePlate(plate)

    if not normalized then return { ok = false, reason = 'bad_plate' } end

    local rules = config().Hotlist or {}
    local store = records()
    local nowSeconds = epoch()

    if Mdt.hotlistEntry(store.hotlist, normalized, nowSeconds) then
        return { ok = false, reason = 'already_hot' }
    end

    local entry = {
        id = P.newId('HOT'),
        plate = normalized,
        reason = Mdt.cleanText(reason, 80) or 'reported stolen',
        minutes = math.max(1, math.floor(tonumber(minutes) or tonumber(rules.defaultMinutes) or 240)),
        addedAt = nowSeconds,
        expiresAt = nowSeconds + math.max(1, math.floor(tonumber(minutes) or tonumber(rules.defaultMinutes) or 240)) * 60,
        addedBy = opts.auto and 'dispatch' or (source and 'officer' or 'console'),
        officer = opts.officer,
        auto = opts.auto == true,
    }

    store.hotlist[#store.hotlist + 1] = entry
    P.trim(store.hotlist, tonumber(rules.max) or 100)

    local vehicle = Mdt.findVehicle(store, normalized)

    if vehicle then
        -- Only the flag should be undone on recovery: a car the records already
        -- called stolen stays stolen.
        entry.markedStolen = vehicle.stolen ~= true
        vehicle.stolen = true
    end

    P.save()

    return { ok = true, id = entry.id, plate = entry.plate, expiresAt = entry.expiresAt, reason = entry.reason }
end

--- A flag that marked the car stolen puts it back when the flag goes away.
local function unmaskVehicle(store, entry)
    if not entry.markedStolen or not entry.plate then return end

    local vehicle = Mdt.findVehicle(store, entry.plate)

    if vehicle then vehicle.stolen = false end
end

--- Take a plate off the hotlist (recovered, or a mistake).
--- @return table result
local function clearHotlist(source, value)
    local store = records()
    local wantedPlate = Mdt.normalizePlate(value)
    local wantedId = tostring(value or '')
    local removed

    for index = #(store.hotlist or {}), 1, -1 do
        local entry = store.hotlist[index]

        if entry.id == wantedId or (wantedPlate and entry.plate == wantedPlate) then
            removed = entry
            unmaskVehicle(store, entry)
            table.remove(store.hotlist, index)
        end
    end

    if not removed then return { ok = false, reason = 'unknown_plate' } end

    P.save()

    return { ok = true, id = removed.id, plate = removed.plate }
end

--- Dispatch flags a car on its own, slowly, so patrol has something to find.
--- @return table|nil entry
local function autoHotlist(nowSeconds)
    local rules = config().Hotlist or {}
    local every = (tonumber(rules.autoMinutes) or 0) * 60
    local store = records()

    store.hotlistMeta = store.hotlistMeta or { lastAutoAt = nowSeconds }

    if every <= 0 then return nil end
    if nowSeconds - (tonumber(store.hotlistMeta.lastAutoAt) or nowSeconds) < every then return nil end

    local autoCount = 0

    for _, entry in ipairs(store.hotlist or {}) do
        if entry.auto then autoCount = autoCount + 1 end
    end

    if autoCount >= (tonumber(rules.autoMax) or 6) then return nil end

    local keys = {}

    for key in pairs(store.vehicles or {}) do keys[#keys + 1] = key end

    table.sort(keys)

    if #keys == 0 then return nil end

    local start = (tonumber(store.hotlistMeta.cursor) or 0) % #keys

    for offset = 1, #keys do
        local index = ((start + offset - 1) % #keys) + 1
        local vehicle = store.vehicles[keys[index]]

        if vehicle and vehicle.plate and not vehicle.stolen
            and not Mdt.hotlistEntry(store.hotlist, vehicle.plate, nowSeconds) then
            local reasons = rules.reasons or {}
            local reason = #reasons > 0 and reasons[(offset % #reasons) + 1] or 'reported stolen'
            local added = addHotlist(nil, vehicle.plate, rules.defaultMinutes, reason, { auto = true })

            if added.ok then
                store.hotlistMeta.cursor = index
                store.hotlistMeta.lastAutoAt = nowSeconds
                P.save()

                return added
            end
        end
    end

    return nil
end

--- Drop expired flags. Idempotent.
--- @return number removed
local function sweepHotlist(nowSeconds)
    local store = records()
    local now = tonumber(nowSeconds) or epoch()
    local removed = 0

    for index = #(store.hotlist or {}), 1, -1 do
        local entry = store.hotlist[index]

        if entry.expiresAt and tonumber(entry.expiresAt) <= now then
            unmaskVehicle(store, entry)
            table.remove(store.hotlist, index)
            removed = removed + 1
        end
    end

    if removed > 0 then P.save() end

    return removed
end

exports('ListHotlist', function() return listHotlist() end)
exports('AddHotlist', function(source, plate, minutes, reason) return addHotlist(source, plate, minutes, reason) end)
exports('ClearHotlist', function(source, value) return clearHotlist(source, value) end)

RegisterNetEvent('fk_police:server:hotlist', function(action, value, minutes, reason)
    local source = source
    local entry, why = onDuty(source)

    if not entry then return notify(source, 'Go on duty first.') end

    if action == 'clear' then
        local result = clearHotlist(source, value)

        return notify(source, result.ok
            and ('%s taken off the hotlist.'):format(tostring(result.plate))
            or 'That plate is not on the hotlist.')
    end

    local result = addHotlist(source, value, minutes, reason, { officer = entry.identifier })

    if not result.ok then
        return notify(source, ('Hotlist: %s.'):format(result.reason == 'already_hot' and 'that plate is already hot' or tostring(result.reason)))
    end

    notify(source, ('%s flagged as stolen until %s.'):format(tostring(result.plate),
        os.date('!%H:%M', tonumber(result.expiresAt) or epoch())))
end)

-- ---------------------------------------------------------------------------
-- Speed cameras
-- ---------------------------------------------------------------------------
-- The client sends the patrol car's position and speed every second while it is
-- on duty. The server decides whether a camera saw a speeding car, and the
-- ticket lands in the same fine ledger as a roadside citation.

--- The configured cameras (for the MDT and the map).
--- @return table
local function cameraList()
    local rules = config().Cameras or {}
    local out = {}

    for _, camera in ipairs(rules.cameras or {}) do
        out[#out + 1] = {
            id = camera.id,
            label = camera.label,
            limitKmh = tonumber(camera.limitKmh) or 0,
            radius = tonumber(camera.radius) or tonumber(rules.defaultRadius) or 30.0,
            coords = camera.coords,
        }
    end

    return out
end

--- The last camera tickets, newest first.
--- @return table
local function cameraTickets(limit)
    local out = {}

    for index = #(records().fines or {}), 1, -1 do
        local fine = records().fines[index]

        if fine.camera then out[#out + 1] = fine end

        if #out >= (tonumber(limit) or 10) then break end
    end

    return out
end

--- Check a position/speed against the cameras. Returns what the camera saw;
--- `ticketed` is true only when a new fine was actually written.
--- @return table result
local function checkCamera(source, payload)
    local entry = P.officerFor(source, true)

    if not entry or not entry.onDuty then return { ok = false, reason = 'off_duty' } end

    local rules = config().Cameras or {}

    if rules.enabled == false then return { ok = false, reason = 'disabled' } end
    if type(payload) ~= 'table' then return { ok = false, reason = 'bad_payload' } end

    local camera = Mdt.cameraAt(config(), payload.x, payload.y, payload.z)

    if not camera then return { ok = false, reason = 'no_camera' } end

    local over, kmh = Mdt.overLimit(camera, payload.speed)

    if not over then return { ok = true, camera = camera.id, ticketed = false, kmh = math.floor(kmh + 0.5) } end

    local store = records()
    local plate = Mdt.normalizePlate(payload.plate)
    local nowSeconds = epoch()
    local key = ('%s:%s'):format(tostring(camera.id), tostring(plate or 'UNKNOWN'))

    store.cameraCooldowns = store.cameraCooldowns or {}

    if nowSeconds - (tonumber(store.cameraCooldowns[key]) or 0) < (tonumber(rules.cooldownSeconds) or 120) then
        return { ok = true, camera = camera.id, ticketed = false, kmh = math.floor(kmh + 0.5), reason = 'cooldown' }
    end

    store.cameraCooldowns[key] = nowSeconds

    -- Keep the cooldown table from growing forever: anything an hour old is dead.
    local stale = {}

    for other, at in pairs(store.cameraCooldowns) do
        if nowSeconds - (tonumber(at) or 0) > 3600 then stale[#stale + 1] = other end
    end

    for _, other in ipairs(stale) do store.cameraCooldowns[other] = nil end

    local charge = Mdt.charge(config(), 'camera_speeding') or Mdt.charge(config(), 'speeding')
    local amount = charge and tonumber(charge.fine) or tonumber(rules.fine) or 250
    local vehicle = plate and Mdt.findVehicle(store, plate)
    local person = vehicle and vehicle.owner or (plate and ('Registered keeper of ' .. plate)) or 'Unknown driver'
    local fine = {
        id = P.newId('CAM'),
        person = person,
        plate = plate,
        charges = {
            { id = charge and charge.id or 'speeding', label = charge and charge.label or 'Speeding', qty = 1 },
        },
        amount = amount,
        paid = 0,
        status = 'unpaid',
        issuedAt = nowSeconds,
        dueAt = nowSeconds + ((config().Justice or {}).paymentDays or 7) * 86400,
        camera = camera.id,
        cameraLabel = camera.label,
        speedKmh = math.floor(kmh + 0.5),
        limitKmh = tonumber(camera.limitKmh) or 0,
        source = 'camera',
        officer = entry.identifier,
    }

    store.fines[#store.fines + 1] = fine
    P.trim(store.fines, (config().Justice or {}).maxFines)
    store.department.balance = tonumber(store.department.balance) or 0
    P.save()

    notify(source, ('Speed camera %s: %d km/h in a %d zone - ticket %s, $%d.'):format(tostring(camera.label or camera.id),
        fine.speedKmh, fine.limitKmh, tostring(fine.id), math.floor(amount)))

    TriggerClientEvent('fk_police:client:camera', source, {
        ok = true,
        camera = camera.id,
        label = camera.label,
        ticketed = true,
        kmh = fine.speedKmh,
        limitKmh = fine.limitKmh,
        fine = fine.id,
        amount = amount,
        person = person,
        plate = plate,
    })

    return {
        ok = true,
        camera = camera.id,
        label = camera.label,
        ticketed = true,
        kmh = fine.speedKmh,
        limitKmh = fine.limitKmh,
        fine = fine.id,
        amount = amount,
        person = person,
        plate = plate,
    }
end

exports('ListCameras', function() return cameraList() end)
exports('CheckCamera', function(source, payload) return checkCamera(source, payload) end)
exports('CameraTickets', function(limit) return cameraTickets(limit) end)

RegisterNetEvent('fk_police:server:camera', function(payload)
    checkCamera(source, payload)
end)

-- ---------------------------------------------------------------------------
-- Contested fines
-- ---------------------------------------------------------------------------
-- A citizen can fight a ticket. The hearing is a few days out; the court either
-- upholds the fine or strikes it out and pays back what was already collected.

--- Contests, newest first, optionally for one person.
--- @return table
local function listContests(filter)
    local options = type(filter) == 'table' and filter or {}
    local person = Mdt.normalizeName(options.person)
    local store = records()
    local out = {}

    for index = #(store.contests or {}), 1, -1 do
        local contest = store.contests[index]
        local matches = true

        if person and (Mdt.normalizeName(contest.person) or ''):lower() ~= person:lower() then matches = false end
        if options.status and (contest.status or 'scheduled') ~= options.status then matches = false end

        if matches then out[#out + 1] = contest end
        if #out >= 50 then break end
    end

    return out
end

--- Hear one contested fine.
--- @return table contest
local function hearContest(contest, nowSeconds)
    local rules = config().Bail or {}
    local store = records()
    local fine

    for _, candidate in ipairs(store.fines or {}) do
        if candidate.id == contest.fine then fine = candidate end
    end

    contest.heardAt = tonumber(nowSeconds) or epoch()

    local struck = Mdt.hash01(tostring(contest.id) .. ':contest') < (tonumber(rules.contestStrikeChance) or 0.45)

    if struck and fine then
        contest.status = 'struck'
        fine.status = 'waived'
        fine.waivedAt = contest.heardAt
        fine.waivedBy = 'court'
        fine.waiveReason = 'contested and struck out'

        local paid = math.max(0, tonumber(fine.paid) or 0)

        if paid > 0 then
            contest.refund = paid
            store.department.balance = math.max(0, (tonumber(store.department.balance) or 0) - paid)
        end
    else
        contest.status = 'upheld'
        if fine then fine.contest = 'upheld' end
    end

    if fine then fine.contest = contest.status end

    return contest
end

--- Walk the contest docket. Idempotent.
--- @return number heard
local function sweepContests(nowSeconds)
    local store = records()
    local now = tonumber(nowSeconds) or epoch()
    local heard = 0

    for _, contest in ipairs(store.contests or {}) do
        if (contest.status or 'scheduled') == 'scheduled' and (tonumber(contest.hearingAt) or math.huge) <= now then
            hearContest(contest, now)
            heard = heard + 1
        end
    end

    if heard > 0 then P.save() end

    return heard
end

--- Contest a fine. One open contest per fine.
--- @return table result
local function contestFine(source, id)
    local entry, reason = onDuty(source)

    if not entry then return { ok = false, reason = reason } end

    local store = records()
    local fine

    for _, candidate in ipairs(store.fines or {}) do
        if candidate.id == tostring(id or '') then fine = candidate end
    end

    if not fine then return { ok = false, reason = 'unknown_fine' } end
    if (fine.status or 'unpaid') == 'waived' then return { ok = false, reason = 'waived' } end

    for _, contest in ipairs(store.contests or {}) do
        if contest.fine == fine.id and (contest.status or 'scheduled') == 'scheduled' then
            return { ok = false, reason = 'already_contested' }
        end
    end

    local rules = config().Bail or {}
    local nowSeconds = epoch()
    local contest = {
        id = P.newId('CCT'),
        fine = fine.id,
        person = fine.person,
        plate = fine.plate,
        amount = fine.amount,
        status = 'scheduled',
        filedAt = nowSeconds,
        hearingAt = nowSeconds + math.max(1, tonumber(rules.contestDays) or 3) * 86400,
        officer = entry.identifier,
    }

    store.contests[#store.contests + 1] = contest
    P.trim(store.contests, tonumber(rules.contestHistory) or 200)

    fine.contest = 'scheduled'
    P.save()

    local days = math.max(1, tonumber(rules.contestDays) or 3)

    notify(source, ('%s is contesting %s ($%d) - hearing in %d days.'):format(tostring(fine.person),
        tostring(fine.id), math.floor(tonumber(fine.amount) or 0), days))

    return {
        ok = true,
        id = contest.id,
        fine = fine.id,
        person = fine.person,
        hearingAt = contest.hearingAt,
        days = days,
    }
end

exports('ContestFine', function(source, id) return contestFine(source, id) end)
exports('ListContests', function(filter) return listContests(filter) end)
exports('SweepContests', function(nowSeconds) return sweepContests(nowSeconds) end)

RegisterNetEvent('fk_police:server:fine:contest', function(id)
    local source = source
    local result = contestFine(source, id)

    if result.ok then return end

    local reasons = {
        unknown_fine = 'that ticket is not on the ledger',
        already_contested = 'that ticket is already waiting on a hearing',
        waived = 'that ticket was already waived',
        off_duty = 'go on duty first',
        no_identifier = 'go on duty first',
    }

    notify(source, ('Contest: %s.'):format(reasons[result.reason] or tostring(result.reason)))
end)

RegisterCommand('contest', function(source, args)
    local src = tonumber(source) or 0
    local id = (args or {})[1]

    if not id then
        local open = listContests({ status = 'scheduled' })

        if #open == 0 then return notify(src, 'No contested tickets waiting.') end

        for index = 1, math.min(#open, 6) do
            local contest = open[index]

            notify(src, ('%s %s - hearing %s.'):format(tostring(contest.id), tostring(contest.person),
                os.date('!%Y-%m-%d', tonumber(contest.hearingAt) or epoch())))
        end

        return
    end

    local result = contestFine(src, id)

    notify(src, result.ok
        and ('Hearing set for %s in %d days.'):format(tostring(result.fine), result.days)
        or ('Contest: %s.'):format(tostring(result.reason)))
end)

-- --- commands ---------------------------------------------------------------

--- Join the tail of an argument list back into one string ("Marcus Vance").
local function joinArgs(args, from)
    local parts = {}

    for index = from or 2, #(args or {}) do parts[#parts + 1] = tostring(args[index]) end

    return #parts > 0 and table.concat(parts, ' ') or nil
end

RegisterCommand(config().Commands.lab or 'lab', function(source, args)
    local src = tonumber(source) or 0
    local list = args or {}
    local action = tostring(list[1] or ''):lower()

    if action == '' or action == 'list' then
        local samples = forensicsFor({})

        if #samples == 0 then return notify(src, 'The lab has nothing on file.') end

        for index = 1, math.min(#samples, 6) do
            local sample = samples[index]
            local line = sample.result and sample.result.detail or ('at the lab, back in ' ..
                Mdt.formatDuration(math.max(0, (tonumber(sample.readyAt) or 0) - epoch())))

            notify(src, ('%s %s (%s): %s'):format(tostring(sample.id), tostring(sample.label),
                tostring(sample.person), line))
        end

        return
    end

    local names = { 'dna', 'drugs', 'ballistics', 'prints' }
    local kind = action
    local name = joinArgs(list, 2)
    local result = submitForensics(src, kind, name)

    if not result.ok then
        if result.reason == 'unknown_kind' then
            return notify(src, ('Lab kinds: %s.'):format(table.concat(names, ', ')))
        end

        return notify(src, ('Lab: %s.'):format(tostring(result.reason)))
    end

    notify(src, ('Sample %s (%s) from %s - back in %s.'):format(tostring(result.id), tostring(result.label),
        tostring(result.person), Mdt.formatDuration(result.readyIn)))
end)

RegisterCommand(config().Commands.bail or 'bail', function(source, args)
    local src = tonumber(source) or 0

    if not P.officerFor(src, true) then return notify(src, 'Go on duty first.') end

    local quote = bailQuote(src)

    if not quote.ok then return notify(src, 'Nobody is in custody to bail.') end

    local amount = tonumber((args or {})[1])

    if not amount then
        return notify(src, ('Bail for %s is $%d (sentence %s). /bail %d to post it.'):format(tostring(quote.person),
            math.floor(quote.amount), Mdt.formatDuration(quote.seconds), math.floor(quote.amount)))
    end

    local result = postBail(src, amount, 'posted at the desk')

    if not result.ok then
        return notify(src, ('Bail: %s.'):format(result.reason == 'short_payment'
            and ('the court wants $' .. tostring(result.due)) or tostring(result.reason)))
    end

    notify(src, ('%s out on $%d bail - court in %d days.'):format(tostring(result.person),
        math.floor(result.amount), result.courtDays))
end)

RegisterCommand(config().Commands.court or 'court', function(source, args)
    local src = tonumber(source) or 0
    local list = args or {}
    local action = tostring(list[1] or ''):lower()

    if action == 'attend' and list[2] then
        local store = records()

        for _, bail in ipairs(store.bails or {}) do
            if bail.id == tostring(list[2]) and (bail.status or 'posted') == 'posted' then
                hearBail(bail, epoch())
                P.save()

                return notify(src, ('%s: %s%s'):format(tostring(bail.person), tostring(bail.status),
                    bail.outcome and (' (' .. tostring(bail.outcome) .. ')') or ''))
            end
        end

        return notify(src, 'No such open court date.')
    end

    local open = listBails({ status = 'posted' })

    if #open == 0 then return notify(src, 'No court dates on the docket.') end

    notify(src, ('%d court date(s) open.'):format(#open))

    for index = 1, math.min(#open, 6) do
        local bail = open[index]

        notify(src, ('%s %s - $%d, %d day(s) left.'):format(tostring(bail.id), tostring(bail.person),
            math.floor(tonumber(bail.amount) or 0), tonumber(bail.daysLeft) or 0))
    end
end)

RegisterCommand(config().Commands.hotlist or 'hotlist', function(source, args)
    local src = tonumber(source) or 0
    local list = args or {}
    local action = tostring(list[1] or ''):lower()

    if action == 'add' and list[2] then
        local result = addHotlist(src, list[2], tonumber(list[3]), joinArgs(list, 4))

        return notify(src, result.ok
            and ('%s flagged as stolen.'):format(tostring(result.plate))
            or ('Hotlist: %s.'):format(tostring(result.reason)))
    end

    if action == 'remove' and list[2] then
        local result = clearHotlist(src, list[2])

        return notify(src, result.ok and ('%s recovered.'):format(tostring(result.plate)) or 'Not on the hotlist.')
    end

    local hot = listHotlist()

    if #hot == 0 then return notify(src, 'Nothing on the hotlist.') end

    notify(src, ('%d stolen plate(s) on the hotlist.'):format(#hot))

    for index = 1, math.min(#hot, 8) do
        local entry = hot[index]

        notify(src, ('%s - %s'):format(tostring(entry.plate), tostring(entry.reason)))
    end
end)

RegisterCommand(config().Commands.cameras or 'cameras', function(source, args)
    local src = tonumber(source) or 0
    local cameras = cameraList()

    notify(src, ('%d speed cameras: %s.'):format(#cameras,
        table.concat((function()
            local labels = {}

            for _, camera in ipairs(cameras) do labels[#labels + 1] = ('%s (%d)'):format(tostring(camera.label), camera.limitKmh) end

            return labels
        end)(), ', ')))

    local tickets = cameraTickets(3)

    if #tickets > 0 then
        for _, fine in ipairs(tickets) do
            notify(src, ('%s: %d km/h in a %d zone, $%d.'):format(tostring(fine.cameraLabel or fine.camera),
                tonumber(fine.speedKmh) or 0, tonumber(fine.limitKmh) or 0, math.floor(tonumber(fine.amount) or 0)))
        end
    end
end)

-- The one clock the new systems share. Each sweep is idempotent, so the timer
-- only decides how quickly an answer comes back, never what the answer is.
CreateThread(function()
    while true do
        Wait(5000)

        local nowSeconds = epoch()

        settleForensics(nowSeconds)
        sweepCourtDates(nowSeconds)
        sweepContests(nowSeconds)
        sweepHotlist(nowSeconds)
        autoHotlist(nowSeconds)
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
        verdicts = (function()
            local out = {}

            for index = #(store.verdicts or {}), 1, -1 do
                out[#out + 1] = store.verdicts[index]
                if #out >= 10 then break end
            end

            return out
        end)(),
        evidence = evidenceFor(nil),
        lab = { kinds = (config().Forensics or {}).kinds or {}, list = forensicsFor({}) },
        bail = bailQuote(source),
        bails = listBails({}),
        hotlist = listHotlist(),
        cameras = cameraList(),
        cameraTickets = cameraTickets(10),
        contests = listContests({}),
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

-- /callsign 3-ADAM-12 - your name on the radio and in the MDT header.
RegisterCommand(config().Commands.callsign or 'callsign', function(source, args)
    local entry, reason = onDuty(source)

    if not entry then return notify(source, ('You need to be on duty (%s).'):format(tostring(reason))) end

    local wanted = Mdt.normalizeCallsign(table.concat(args or {}, '-'))

    if not wanted then
        return notify(source, ('Usage: /%s <1-ADAM-12> (2-12 letters, digits or dashes).')
            :format(config().Commands.callsign or 'callsign'))
    end

    local before = entry.callsign
    local store = records()

    entry.callsign = wanted
    store.officers[entry.identifier] = entry
    P.save()
    P.sendStatus(source)

    notify(source, before and ('Callsign changed from %s to %s.'):format(before, wanted)
        or ('Callsign set to %s.'):format(wanted))
end, false)

-- /verdict [count] - what the court has been up to.
RegisterCommand(config().Commands.verdict or 'verdict', function(source, args)
    local entry, reason = onDuty(source)

    if not entry then return notify(source, ('You need to be on duty (%s).'):format(tostring(reason))) end

    local wanted = math.max(1, math.min(25, tonumber(args and args[1]) or 5))
    local store = records()
    local shown = 0

    notify(source, ('Court verdicts (newest first, showing %d):'):format(wanted))

    for index = #(store.verdicts or {}), 1, -1 do
        local verdict = store.verdicts[index]

        notify(source, (' - %s %s: %s%s'):format(
            tostring(verdict.id), tostring(verdict.person or '?'), tostring(verdict.outcome),
            verdict.refund and (' (refunded $%d)'):format(verdict.refund) or ''))
        shown = shown + 1

        if shown >= wanted then break end
    end

    if shown == 0 then notify(source, ' - nothing on the docket yet.') end
end, false)

-- /evidence [person] - what is on file, for one person or the lot.
RegisterCommand(config().Commands.evidence or 'evidence', function(source, args)
    local entry, reason = onDuty(source)

    if not entry then return notify(source, ('You need to be on duty (%s).'):format(tostring(reason))) end

    local who = table.concat(args or {}, ' ')
    local list = evidenceFor(who ~= '' and who or nil)

    notify(source, who ~= '' and ('Evidence against %s (%d entr%s):'):format(who, #list, #list == 1 and 'y' or 'ies')
        or ('Evidence locker (%d entr%s):'):format(#list, #list == 1 and 'y' or 'ies'))

    for index = 1, math.min(10, #list) do
        local item = list[index]
        local labels = {}

        for _, seized in ipairs(item.items or {}) do
            labels[#labels + 1] = ('%s x%d'):format(tostring(seized.label), tonumber(seized.qty) or 1)
        end

        notify(source, (' - %s: %s'):format(tostring(item.person), table.concat(labels, ', ')))
    end

    if #list == 0 then notify(source, ' - empty.') end
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

P.log(('justice ready: %d fine(s), %d warrant(s), %d BOLO(s), %d report(s), %d impound(s), %d shift(s), %d booking(s), %d verdict(s), %d exhibit(s).')
    :format(#(records().fines or {}), #(records().warrants or {}), #(records().bolos or {}),
        #(records().reports or {}), #(records().impounds or {}), #(records().shifts or {}),
        #(records().bookings or {}), #(records().verdicts or {}), #(records().evidence or {})))
