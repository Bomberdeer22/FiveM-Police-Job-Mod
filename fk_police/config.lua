--[[
    fk_police — config.lua
    ---------------------------------------------------------------------------
    An LSPDFR-style police job for a *single-player* server: you are the only
    officer, so nothing here is built around other players (no shared callouts,
    no staff queue, no anti-griefing). See docs/LSPDFR.md for how each LSPDFR
    system maps onto this resource.
]]

Config = {}

-- Single-player server: rate limits are off, the lone player owns everything,
-- and the police computer is local to them.
Config.Singleplayer = true

-- Everything the UI talks about in one place.
Config.Prefix = 'LSPD'
Config.Debug = false

-- ---------------------------------------------------------------------------
-- Stations
-- ---------------------------------------------------------------------------
-- Mission Row. `services` decides what the marker offers; `exit` is where the
-- player is put when they leave the garage.
Config.Stations = {
    {
        name = 'missionrow',
        label = 'Mission Row Police Station',
        coords = { x = 441.0, y = -982.0, z = 30.68 },
        radius = 30.0,
        spawn = { x = 452.6, y = -993.3, z = 30.69, w = 90.0 },
        garage = { x = 447.8, y = -1000.6, z = 30.68, w = 179.0 },
        jail = { x = 477.0, y = -1007.9, z = 26.27, w = 90.0 },
        services = { 'duty', 'locker', 'armoury', 'garage', 'computer', 'jail' },
    },
}

-- ---------------------------------------------------------------------------
-- Loadout and uniforms
-- ---------------------------------------------------------------------------
-- Given by the armoury. Ammo is refilled, weapons are not dropped.
Config.Loadout = {
    weapons = {
        { weapon = 'WEAPON_PISTOL', ammo = 90 },
        { weapon = 'WEAPON_STUNGUN', ammo = 1 },
        { weapon = 'WEAPON_NIGHTSTICK', ammo = 1 },
        { weapon = 'WEAPON_FLASHLIGHT', ammo = 1 },
        { weapon = 'WEAPON_COMBATPISTOL', ammo = 90 },
    },
    armour = 100,
    -- Re-supplying is free; LSPDFR's armoury is free as well.
    cost = 0,
}

-- Component ids for the duty uniform (single player: no per-player outfits to
-- merge, so the whole uniform is set and restored from the player's saved
-- outfit when they go off duty).
Config.Uniform = {
    male = {
        { component = 11, drawable = 55, texture = 0 }, -- torso (LSPD shirt)
        { component = 4, drawable = 35, texture = 0 },  -- legs
        { component = 6, drawable = 25, texture = 0 },  -- shoes
        { component = 3, drawable = 4, texture = 0 },   -- arms (short sleeves)
    },
    female = {
        { component = 11, drawable = 48, texture = 0 },
        { component = 4, drawable = 34, texture = 0 },
        { component = 6, drawable = 27, texture = 0 },
        { component = 3, drawable = 4, texture = 0 },
    },
}

-- ---------------------------------------------------------------------------
-- Police vehicles
-- ---------------------------------------------------------------------------
Config.Vehicles = {
    { model = 'police', label = 'Police Cruiser' },
    { model = 'police2', label = 'Police Buffalo' },
    { model = 'police3', label = 'Police Interceptor' },
    { model = 'police4', label = 'Unmarked Cruiser' },
    { model = 'policeb', label = 'Police Bike' },
    { model = 'fbi2', label = 'Unmarked SUV' },
    { model = 'riot', label = 'Police Riot' },
    { model = 'polmav', label = 'Police Maverick' },
}

-- ---------------------------------------------------------------------------
-- Ranks and pay
-- ---------------------------------------------------------------------------
-- XP comes from resolved callouts (Config.Callouts[x].xp), citations and
-- arrests. Pay is credited to the bank account through fk_economy, so the
-- police job feeds the same economy as everything else.
-- Medals: awarded on XP thresholds, shown in the MDT and the status payload.
Config.Medals = {
    { xp = 500, label = 'Meritorious Service', blurb = '500 XP on the job' },
    { xp = 1500, label = "Chief's Commendation", blurb = '1,500 XP on the job' },
    { xp = 3000, label = 'Medal of Valor', blurb = '3,000 XP on the job' },
}

Config.Ranks = {
    { name = 'Cadet', xp = 0, salary = 500 },
    { name = 'Officer', xp = 150, salary = 750 },
    { name = 'Senior Officer', xp = 400, salary = 1000 },
    { name = 'Corporal', xp = 800, salary = 1400 },
    { name = 'Sergeant', xp = 1400, salary = 2000 },
    { name = 'Lieutenant', xp = 2200, salary = 2800 },
}

Config.Pay = {
    -- Paid on the spot when a callout is closed (bank), scaled by rank.
    callout = 250,
    citation = 100,
    arrest = 400,
    -- A share of every fine goes to the officer, the rest to the department.
    fineShare = 0.25,
}

-- ---------------------------------------------------------------------------
-- Callouts (dispatch)
-- ---------------------------------------------------------------------------
Config.Dispatch = {
    -- First callout this long after going on duty (seconds).
    firstAfter = 25,
    -- Then a random gap between these two, in seconds.
    minGap = 60,
    maxGap = 150,
    -- One callout at a time - this is a single-player server.
    maxActive = 1,
    -- How far from the player a callout can appear.
    minDistance = 120.0,
    maxDistance = 550.0,
    -- Seconds the callout stays on the board before dispatch withdraws it.
    expireAfter = 420,
    -- Standing on the scene marker within this distance resolves the callout.
    sceneRadius = 12.0,
}

-- Every callout: `xp`, `code` (radio code), `label`, the charges it can end in,
-- and how many suspects it may spawn.
Config.Callouts = {
    {
        id = 'traffic_stop',
        code = '10-38',
        label = 'Reckless driver',
        xp = 40,
        weight = 30,
        suspects = 1,
        charges = { 'reckless_driving', 'speeding' },
    },
    {
        id = 'disturbance',
        code = '10-16',
        label = 'Disturbance in progress',
        xp = 60,
        weight = 25,
        suspects = 1,
        charges = { 'disturbing_the_peace', 'assault' },
    },
    {
        id = 'robbery',
        code = '10-31',
        label = 'Robbery in progress',
        xp = 120,
        weight = 20,
        suspects = 2,
        charges = { 'armed_robbery', 'assault' },
    },
    {
        id = 'stolen_vehicle',
        code = '10-52',
        label = 'Stolen vehicle reported',
        xp = 80,
        weight = 15,
        suspects = 1,
        charges = { 'grand_theft_auto' },
    },
    {
        id = 'welfare_check',
        code = '10-96',
        label = 'Welfare check',
        xp = 30,
        weight = 10,
        suspects = 0,
        charges = {},
    },
    {
        id = 'drunk_driver',
        code = '10-55',
        label = 'Suspected drunk driver',
        xp = 50,
        weight = 18,
        suspects = 1,
        charges = { 'dui', 'reckless_driving' },
        weapon = nil,
    },
    {
        id = 'prowler',
        code = '10-32',
        label = 'Prowler reported',
        xp = 45,
        weight = 15,
        suspects = 1,
        charges = { 'resisting_arrest' },
        weapon = 'WEAPON_KNIFE',
    },
    {
        id = 'shots_fired',
        code = '10-71',
        label = 'Shots fired',
        xp = 140,
        weight = 12,
        suspects = 2,
        charges = { 'assault', 'evading_police' },
        weapon = 'WEAPON_PISTOL',
    },
    {
        id = 'bank_alarm',
        code = '10-90',
        label = 'Bank alarm',
        xp = 200,
        weight = 6,
        suspects = 3,
        charges = { 'armed_robbery' },
        weapon = 'WEAPON_CARBINERIFLE',
    },
    {
        id = 'pursuit_in_progress',
        code = '10-80',
        label = 'Pursuit in progress',
        xp = 160,
        weight = 8,
        suspects = 1,
        charges = { 'evading_police', 'grand_theft_auto' },
        weapon = nil,
    },
    {
        id = 'vandalism',
        code = '10-17',
        label = 'Vandalism in progress',
        xp = 40,
        weight = 12,
        suspects = 1,
        charges = { 'vandalism' },
        weapon = nil,
    },
}

-- Charges, fines and jail time. Every value is server-side; the UI only picks
-- an id.
Config.Charges = {
    { id = 'speeding', label = 'Speeding', fine = 250, jail = 0, type = 'infraction' },
    { id = 'reckless_driving', label = 'Reckless driving', fine = 600, jail = 0, type = 'misdemeanor' },
    { id = 'disturbing_the_peace', label = 'Disturbing the peace', fine = 500, jail = 30, type = 'misdemeanor' },
    { id = 'assault', label = 'Assault', fine = 1200, jail = 120, type = 'felony' },
    { id = 'grand_theft_auto', label = 'Grand theft auto', fine = 1800, jail = 120, type = 'felony' },
    { id = 'armed_robbery', label = 'Armed robbery', fine = 3000, jail = 300, type = 'felony' },
    { id = 'resisting_arrest', label = 'Resisting arrest', fine = 800, jail = 60, type = 'misdemeanor' },
    { id = 'dui', label = 'Driving under the influence', fine = 1000, jail = 60, type = 'misdemeanor' },
    { id = 'possession', label = 'Possession of narcotics', fine = 900, jail = 45, type = 'misdemeanor' },
    { id = 'evading_police', label = 'Evading police', fine = 1500, jail = 90, type = 'felony' },
    { id = 'assaulting_a_police_officer', label = 'Assaulting a police officer', fine = 2500, jail = 180, type = 'felony' },
    { id = 'burglary', label = 'Burglary', fine = 2200, jail = 240, type = 'felony' },
    { id = 'vandalism', label = 'Vandalism', fine = 600, jail = 0, type = 'misdemeanor' },
    { id = 'illegal_parking', label = 'Illegal parking', fine = 150, jail = 0, type = 'infraction' },
}

-- ---------------------------------------------------------------------------
-- Traffic stops
-- ---------------------------------------------------------------------------
Config.Traffic = {
    -- How close (and in front) a car has to be for /stop to work.
    maxDistance = 25.0,
    -- The stopped driver waits this long before driving off again (seconds).
    waitSeconds = 180,
    -- Stops act on the driver of the car you are behind.
    requireInVehicle = true,
}

-- ---------------------------------------------------------------------------
-- Arrests and jail
-- ---------------------------------------------------------------------------
Config.Jail = {
    -- Total sentence is the sum of the charges, capped.
    maxSeconds = 600,
    -- /jail with no number uses this (the arrest's own sentence is preferred).
    defaultSeconds = 120,
    -- Keep this many booking records.
    history = 200,
    -- Time served counts double while the player waits at the station? No -
    -- keep it simple and honest: real seconds.
    releaseRadius = 6.0,
    -- Booked suspects are moved here until their sentence is up.
    cell = { x = 461.1, y = -998.7, z = 30.69, w = 90.0 },
}

-- ---------------------------------------------------------------------------
-- Backup
-- ---------------------------------------------------------------------------
Config.Backup = {
    code2 = { label = 'Code 2 (no lights)', units = 1, delay = 12 },
    code3 = { label = 'Code 3 (lights and sirens)', units = 2, delay = 8 },
    air = { label = 'Air support', units = 1, delay = 20, model = 'polmav' },
    k9 = { label = 'K9 unit', units = 1, delay = 15 },
    swat = { label = 'SWAT / NOOSE', units = 2, delay = 30, model = 'riot' },
    ems = { label = 'Ambulance', units = 1, delay = 15, model = 'ambulance' },
    fire = { label = 'Fire department', units = 1, delay = 18, model = 'firetruk' },
    -- Backup that is not police does not arrive in a police car.
    policeModel = 'police3',
    spawnDistance = 120.0,
}

-- ---------------------------------------------------------------------------
-- Records (the MDT database)
-- ---------------------------------------------------------------------------
Config.Records = {
    file = 'data/records.json',
    -- Seed a small population so the computer, ANPR and callouts have something
    -- to find on a fresh install.
    seed = true,
    -- Keep the last N citations/arrests on disk.
    maxCitations = 200,
    maxArrests = 200,
}

-- Default records created when the file does not exist yet.
Config.Seed = {
    people = {
        { name = 'Marcus Vance', dob = '1987-04-12', license = 'valid', warrants = {} },
        { name = 'Dana Cruz', dob = '1990-11-02', license = 'expired', warrants = {} },
        { name = 'Ellis Roan', dob = '1979-06-30', license = 'suspended',
          warrants = { { charge = 'assault', issued = '2026-09-14' } } },
        { name = 'Tasha Bell', dob = '1995-02-19', license = 'valid', warrants = {} },
        { name = 'Owen Pike', dob = '1983-08-07', license = 'none',
          warrants = { { charge = 'grand_theft_auto', issued = '2026-10-01' } } },
    },
    vehicles = {
        { plate = 'MARCUS1', model = 'sultan', owner = 'Marcus Vance', stolen = false, registration = 'valid', insurance = 'valid' },
        { plate = 'DANA22', model = 'blista', owner = 'Dana Cruz', stolen = false, registration = 'expired', insurance = 'expired' },
        { plate = 'ELLIS3', model = 'buffalo', owner = 'Ellis Roan', stolen = false, registration = 'valid', insurance = 'valid' },
        { plate = 'TASHA44', model = 'asea', owner = 'Tasha Bell', stolen = false, registration = 'valid', insurance = 'valid' },
        { plate = 'OWEN555', model = 'schafter2', owner = 'Owen Pike', stolen = true, registration = 'expired', insurance = 'none' },
    },
}

-- ---------------------------------------------------------------------------
-- Justice: fines, warrants, BOLOs, reports, shifts, impound, pursuits, field work
-- ---------------------------------------------------------------------------
-- Everything below is server-side bookkeeping. The client can ask for any of
-- it, but every amount, id and deadline is decided here.

-- The citation/arrest ledger. A fine becomes overdue after `paymentDays`, and
-- an overdue fine suspends the person's licence and (optionally) issues a
-- warrant - that is what makes an unpaid ticket turn into a traffic stop with
-- consequences later.
Config.Justice = {
    paymentDays = 7,
    -- Interest is not simulated; the fine is the fine.
    suspensionOnOverdue = true,
    warrantOnOverdue = true,
    overdueCharge = 'unpaid_fines',
    maxFines = 400,
    -- What the department book (records.department.balance) is called in chat.
    departmentLabel = 'LSPD court fund',
    -- When a suspect leaves custody the court decides. The roll is deterministic
    -- per booking, so the same booking always lands on the same verdict.
    verdictChance = 0.72,
    -- An acquittal gives the fine back out of the court fund.
    acquitRefund = true,
    maxVerdicts = 250,
}

-- Warrants are stored twice on purpose: on the person (so a stop shows them)
-- and in records.warrants (so the MDT and the court can list and revoke them).
Config.Warrants = {
    defaultDays = 30,
    max = 250,
}

-- BOLOs: plates and names dispatch wants flagged. They expire on their own.
Config.Bolo = {
    defaultMinutes = 120,
    max = 120,
    -- A BOLO hit makes the ANPR in the HUD flash.
    alertRadius = 300.0,
}

-- Incident reports written in the MDT.
Config.Reports = {
    max = 250,
    minTitle = 3,
    maxTitle = 80,
    minBody = 10,
    maxBody = 4000,
    maxSubjects = 6,
    kinds = { 'incident', 'supplement', 'use_of_force', 'citation_note' },
    -- XP for a filed report: paperwork is part of the job.
    xp = 15,
}

-- A shift is a duty session. Pay is rank salary prorated over `fullShiftMinutes`
-- plus a bonus per citation/arrest/callout, capped at `maxPay`.
Config.Shift = {
    fullShiftMinutes = 60,
    minMinutes = 1,
    citationBonus = 50,
    arrestBonus = 120,
    calloutBonus = 80,
    reportBonus = 25,
    maxPay = 5000,
    maxHistory = 100,
}

-- The impound lot. Releasing a car costs the officer the fee (it is the
-- citizen's money in roleplay, but it is the player's bank here).
-- Evidence: what a frisk or an arrest turns up, kept for the record.
Config.Evidence = {
    max = 400,
    maxPerPerson = 40,
}

Config.Impound = {
    fee = 500,
    stolenSurcharge = 750,
    -- Cars stay on the lot this long before they are "scrapped" (record only).
    maxDays = 7,
    max = 250,
}

-- Pursuits: started from a stop or an accepted callout, ended with an outcome.
Config.Pursuit = {
    maxSeconds = 900,
    -- Offer code 3 backup when a pursuit starts.
    autoBackup = true,
    backupKind = 'code3',
    -- Air support is offered again after this many seconds.
    airAfter = 120,
    outcomes = { 'arrested', 'escaped', 'terminated', 'crashed' },
    max = 200,
}

-- Field work: frisking, breath tests, K9 and radar.
Config.Field = {
    -- 0.08 % is the legal limit; anything at or above it is a DUI.
    duiLimit = 0.08,
    breathMax = 0.199,
    -- Frisking a person rolls against their name, so the same person always
    -- carries the same pockets. `flag` items only show up when the person has
    -- that charge in their record.
    frisk = {
        { id = 'drugs', label = 'bag of narcotics', chance = 0.30, flag = 'possession', qty = { 1, 3 } },
        { id = 'weapon', label = 'concealed pistol', chance = 0.22, flag = 'armed_robbery', qty = { 1, 1 } },
        { id = 'knife', label = 'folding knife', chance = 0.18, qty = { 1, 1 } },
        { id = 'cash', label = 'roll of cash', chance = 0.35, qty = { 1, 4 } },
        { id = 'lockpick', label = 'lockpick set', chance = 0.15, qty = { 1, 1 } },
        { id = 'radio', label = 'police scanner', chance = 0.12, qty = { 1, 1 } },
    },
    -- A warrant makes the person more likely to be carrying something.
    warrantBonus = 0.15,
    -- Spike strips (client-side prop, burst tyres for this long).
    spikes = true,
    spikeSeconds = 120,
    k9 = {
        model = 'a_c_shepherd',
        radius = 18.0,
        -- How long the dog works before it answers (seconds).
        searchSeconds = 4,
        hits = { 'possession', 'armed_robbery', 'grand_theft_auto' },
    },
}

-- The radar in the HUD.
Config.Radar = {
    enabled = true,
    -- Only read cars this far in front of the patrol car.
    maxDistance = 60.0,
    -- Below this speed (m/s) the radar does not bother showing a reading.
    minSpeed = 4.0,
    -- Ask the server about the plate automatically when it is read.
    autoAnpr = true,
}

-- The on-screen HUD (duty, rank, XP, shift timer, callout, radar, BOLOs).
Config.Hud = {
    enabled = true,
    -- Refresh rate of the HUD payload, in milliseconds.
    interval = 500,
    showRadar = true,
    showShift = true,
    showXp = true,
}

-- ---------------------------------------------------------------------------
-- Keys and commands
-- ---------------------------------------------------------------------------
Config.Keys = {
    interact = 38,      -- E: station services, on-scene prompt
    computer = 38,      -- E inside a police vehicle opens the MDT
    menu = 244,         -- M: interaction menu
    backup = 47,        -- G: backup menu (B is the radio wheel)
    accept = 246,       -- Y: accept the current callout
}

Config.Commands = {
    duty = 'duty',
    computer = 'pc',
    menu = 'pd',
    stop = 'stop',
    cite = 'cite',
    arrest = 'arrest',
    jail = 'jail',
    backup = 'backup',
    callout = 'callout',
    forceCallout = 'callout_force',
    status = 'pdstatus',
    callsign = 'callsign',
    verdict = 'verdict',
    evidence = 'evidence',
    report = 'report',
    bolo = 'bolo',
    warrant = 'warrant',
    fine = 'fine',
    impound = 'impound',
    pursuit = 'pursuit',
    frisk = 'frisk',
    breath = 'breath',
    k9 = 'k9',
    radar = 'radar',
    bodycam = 'bodycam',
}

-- ---------------------------------------------------------------------------
-- Rate limits (only used when Config.Singleplayer = false)
-- ---------------------------------------------------------------------------
Config.RateLimit = {
    search = { rate = 6, burst = 12 },
    stop = { rate = 1, burst = 3 },
    cite = { rate = 1, burst = 3 },
    arrest = { rate = 0.5, burst = 2 },
    backup = { rate = 0.5, burst = 3 },
    callout = { rate = 0.5, burst = 3 },
}
