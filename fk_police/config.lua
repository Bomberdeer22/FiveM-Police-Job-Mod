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
    { model = 'policeb', label = 'Police Bike' },
    { model = 'fbi2', label = 'Unmarked SUV' },
}

-- ---------------------------------------------------------------------------
-- Ranks and pay
-- ---------------------------------------------------------------------------
-- XP comes from resolved callouts (Config.Callouts[x].xp), citations and
-- arrests. Pay is credited to the bank account through fk_economy, so the
-- police job feeds the same economy as everything else.
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
