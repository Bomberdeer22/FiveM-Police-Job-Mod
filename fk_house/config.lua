--[[
    fk_house — config.lua
    ---------------------------------------------------------------------------
    Everything you can do inside Michael De Santa's mansion.

    Spots are interaction points: walk up, press E, pick an option. The
    coordinates below are a starting point — stand exactly where you want a
    prompt, look at the prop and run /housespot <name> (staff) to save it.
    /housemarkers draws a marker on every spot so you can see where they are.
]]

Config = {}

Config.Debug = false

-- ---------------------------------------------------------------------------
-- Where the house is (interactions only work inside this radius)
-- ---------------------------------------------------------------------------
Config.House = {
    label = "Michael's house",
    -- The interior is v_michael from v_int_44.rpf; its MLO placement puts the
    -- origin exactly here (DurtyFree mloInteriors.json -> bh1_48_interior_
    -- v_michael_milo_.ymap). Every coordinate in this file is derived from that
    -- origin - see docs/COORDINATES.md for the working.
    coords = { x = -807.343, y = 174.981, z = 71.163 },
    radius = 30.0,
    -- The upstairs floor is 3.91 m above the ground floor, so a plain 3D radius
    -- fires through ceilings. A spot is only offered when you are on its floor.
    zTolerance = 2.4,
}

Config.Keys = {
    interact = 38, -- E
    cancel = { 200, 202, 322 }, -- ESC / back
}

-- ---------------------------------------------------------------------------
-- Interaction spots
-- ---------------------------------------------------------------------------
-- type decides what the spot does:
--   'wardrobe'  -> save/wear personal outfits
--   'kitchen'   -> food & drink (menu below)
--   'shower'    -> clean up + heal
--   'bed'       -> sleep / nap, advances the clock
--   'sofa'      -> relax, slow health regen
Config.Spots = {
    {
        name = 'wardrobe',
        label = 'Wardrobe',
        type = 'wardrobe',
        -- Master suite dressing room: wardrobe shell at (-813.95, 174.30),
        -- shelves at (-811.29, 175.32), clothes rail at (-811.26, 176.32).
        coords = { x = -812.60, y = 175.20, z = 75.80 },
        radius = 3.2,
    },
    {
        name = 'bed',
        label = 'Bed',
        type = 'bed',
        -- Master bedroom (upstairs, above the front door): room detail anchor
        -- at (-812.71, 178.40), chandelier at (-814.21, 180.93), balcony doors
        -- at (-817.17, 178.01). The bed itself is baked into the shell.
        coords = { x = -813.20, y = 179.20, z = 75.80 },
        radius = 3.6,
        -- hours advanced by each option and the health given back
        sleep = { hours = 8, health = 100, label = 'Sleep until morning' },
        nap = { hours = 2, health = 40, label = 'Take a nap' },
    },
    {
        name = 'shower',
        label = 'Shower',
        type = 'shower',
        -- Family bathroom off the upstairs hall: sink at (-804.46, 169.07),
        -- mirror at (-804.71, 169.00), door at (-805.00, 171.90).
        coords = { x = -804.60, y = 169.90, z = 75.80 },
        radius = 2.6,
        duration = 5000,
        health = 100,
    },
    {
        name = 'kitchen',
        label = 'Kitchen',
        type = 'kitchen',
        -- Kitchen at the back of the house: fridges at (-804.12, 185.81) and
        -- (-802.83, 186.30), hob at (-799.80, 187.80), sink at (-796.14, 186.84).
        coords = { x = -800.00, y = 185.60, z = 71.85 },
        radius = 4.5,
        options = {
            { id = 'snack', label = 'Make a sandwich', health = 20, description = 'Free. From the fridge.' },
            { id = 'coffee', label = 'Brew a coffee', item = 'coffee', health = 10, description = 'Keeps you awake.' },
            { id = 'donut', label = 'Grab a donut', item = 'donut', health = 15, description = 'Tradition.' },
            { id = 'water', label = 'Pour a water', item = 'water', health = 8, description = 'Hydration.' },
        },
    },
    {
        name = 'livingroom',
        label = 'Living room',
        type = 'sofa',
        -- Lounge, ground floor: sofa script seats at (-804.37, 176.86),
        -- (-802.40, 175.85) and (-806.60, 173.40), projector at (-804.49, 171.94).
        coords = { x = -803.60, y = 174.40, z = 71.85 },
        radius = 4.0,
        scenario = 'WORLD_HUMAN_SEAT_BENCH',
        regen = { health = 100, seconds = 30 },
    },
    {
        name = 'garage',
        label = 'Garage',
        type = 'garage',
        -- Michael's garage is its own MLO (v_michael_garage) on the north side
        -- of the house. mloInteriors.json places it at
        -- (-811.33276, 187.51263, 71.47429); building_controller.c puts the
        -- door (prop_ld_garaged_01) at (-815, 186, 73). The garage floor is
        -- ~0.38 m below the rest of the ground floor, because it is a
        -- different interior with its own origin.
        coords = { x = -811.33, y = 187.51, z = 71.47 },
        radius = 4.5,
    },
}

-- ---------------------------------------------------------------------------
-- Garage / personal vehicle
-- ---------------------------------------------------------------------------
-- One car per player. Park it by driving into the garage and getting out (or
-- use the Garage card). The model is stored in data/garage.json and the car is
-- re-created by the server on your next login, so it is always the same model.
--
-- The server owns the entity and marks it as an orphan, which is what keeps it
-- alive when you are nowhere near it — see server/garage.lua.
Config.Garage = {
    enabled = true,
    file = 'data/garage.json',

    -- The garage floor: the placement of the v_michael_garage MLO in
    -- mloInteriors.json (-811.33276, 187.51263, 71.47429), which is also where
    -- the house's own V_44_Garage_Shell sits (-811.23, 187.34) and ~4 m from
    -- the game's garage door. The car is only saved inside this radius and is
    -- put back here on login.
    coords = { x = -811.33, y = 187.51, z = 71.47 },
    radius = 6.0,
    -- Heading 90 faces west, towards the door on the -x side of the garage.
    spawn = { x = -811.33, y = 187.51, z = 71.70, w = 90.0 },

    -- Spawn the car once the player is this close to the garage (so the
    -- interior collision is streamed in before the car appears).
    spawnDistance = 80.0,

    -- "Personal vehicle": the engine must never treat it as abandoned.
    cullDistance = 4000.0,
    -- Re-create the entity if it ever disappears while the player is online.
    respawn = true,
    respawnDelay = 5000,

    -- Michael's garage door. Turn this off if another resource drives it.
    door = {
        enabled = true,
        -- building_controller.c, case 40: prop_ld_garaged_01 at (-815, 186, 73)
        model = 'prop_ld_garaged_01',
        coords = { x = -815.0, y = 186.0, z = 73.0 },
        openWithin = 12.0,
    },

    -- Models that may not be stored (e.g. { 'rhino', 'lazer' }).
    blockedModels = {},
}

-- ---------------------------------------------------------------------------
-- Wardrobe
-- ---------------------------------------------------------------------------
Config.Wardrobe = {
    slots = 3,          -- personal outfit slots per player
    saveDelay = 1000,   -- ms of "getting changed" before the screen reveals it
    fade = 400,
}

-- ---------------------------------------------------------------------------
-- Food / drink
-- ---------------------------------------------------------------------------
Config.Food = {
    -- Played while eating. Any valid animation dictionary works.
    animation = { dict = 'mp_player_inteat@burger', clip = 'mp_player_int_eat_burger' },
    duration = 3000,
    -- Charged through fk_economy when it is running and the option has `item`.
    chargeItems = true,
}

-- ---------------------------------------------------------------------------
-- Sleeping
-- ---------------------------------------------------------------------------
Config.Sleep = {
    fade = 1000,
    -- Local clock is overridden for the player. If your server has a
    -- time-sync resource, set this event to let the server advance it instead:
    -- TriggerEvent('yourTimeSync:addHours', hours)
    timeAdvanceEvent = nil,
    wakeMessage = 'You wake up feeling rested.',
}

-- ---------------------------------------------------------------------------
-- Staff (same list as the economy: /ecostaff)
-- ---------------------------------------------------------------------------
Config.Staff = {
    useEconomy = true,
    ace = 'fk_house.staff',
}

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
Config.Persistence = {
    outfitsFile = 'data/outfits.json',
    spotsFile = 'data/spots.json',
}

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
Config.UI = {
    title = "Michael's house",
    footer = 'Press the number to choose · ESC to close',
    showHelp = true,
}
