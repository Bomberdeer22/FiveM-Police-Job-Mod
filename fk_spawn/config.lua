--[[
    fk_spawn — config.lua
    ---------------------------------------------------------------------------
    Spawn manager for the FiveM police job mod.

    The player wakes up in Michael De Santa's bedroom (De Santa Residence,
    Rockford Hills). Everything here can be edited without touching code.
]]

Config = {}

Config.Debug = false

-- ---------------------------------------------------------------------------
-- Spawn points
-- ---------------------------------------------------------------------------
-- `name` is what you type in commands (/spawn <name>), keep it lowercase.
-- `coords` takes x/y/z and an optional w (heading, 0 = north, 180 = south).
-- Staff can move any point in game with /spawnset <name> — that is saved to
-- data/spawns.json and overrides the values below, no file editing needed.
Config.Spawns = {
    {
        name = 'michael_bedroom',
        label = "Michael's bedroom",
        coords = { x = -812.56, y = 174.85, z = 76.74, w = 200.0 },
        enabled = true,
        interior = 'michael_house', -- loads the mansion interior before spawning
    },
}

-- Point used by /spawn with no argument, and for the very first spawn.
Config.DefaultSpawn = 'michael_bedroom'

-- ---------------------------------------------------------------------------
-- Interiors
-- ---------------------------------------------------------------------------
-- Interiors are force-loaded before the teleport so the player does not drop
-- through an empty shell while the MLO streams in.
Config.Interiors = {
    michael_house = {
        -- Michael's house (v_int_44). The interior instance sits around here.
        coords = { x = -802.311, y = 175.056, z = 72.8446 },
        label = "Michael's house",
    },
}

-- ---------------------------------------------------------------------------
-- Spawn behaviour
-- ---------------------------------------------------------------------------
Config.Spawn = {
    -- Spawn on the configured point when a player joins the server.
    onJoin = true,
    -- Wait this long after the player becomes active before teleporting, so the
    -- game's own initial spawn has finished and cannot drag them back.
    joinDelay = 1200,
    -- Safety net: if the client never asks for its spawn (script load race,
    -- another resource swallowing the event), push it after this many ms.
    joinFallback = 15000,
    -- Let players use /spawn themselves (staff can always use it).
    allowPlayerCommand = true,

    -- Loading screen + fade
    shutdownLoadingScreen = true, -- call ShutdownLoadingScreen on first spawn
    fadeOutTime = 500,            -- ms, DoScreenFadeOut
    fadeInTime = 600,             -- ms, DoScreenFadeIn
    fadeWait = 700,               -- ms to wait after the fade-out finishes

    -- Freeze the ped while the world streams in, then let go.
    freeze = true,
    freezeTime = 2000,            -- ms (max), released as soon as collision is ready

    -- Drop the ped onto the floor under the configured point. Keeps spawns safe
    -- if a coordinate is a few centimetres off.
    groundSnap = true,
    groundSnapRange = 3.0,        -- metres to look down/up for the floor

    -- Short establishing shot that blends into gameplay.
    cinematic = true,
    cinematicTime = 2200,         -- ms
    cinematicFov = 55.0,

    -- Clear vehicles/peds standing on the spawn point before teleporting.
    clearArea = true,

    -- Teleport the player back to the spawn point after dying (hospital
    -- scripts can fight this, so it is off by default).
    respawnOnDeath = false,
}

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
Config.Commands = {
    -- Chat commands (the list command also works in the console).
    spawn = 'spawn',       -- /spawn [name]
    spawnSet = 'spawnset', -- /spawnset [name]  (staff only)
    list = 'spawnlist',    -- /spawnlist

    -- Console-only commands (txAdmin / rcon).
    consoleSet = 'spawn_set',
    consoleReset = 'spawn_reset',
}

-- ---------------------------------------------------------------------------
-- Who is staff
-- ---------------------------------------------------------------------------
-- /spawnset is staff-only. The staff list lives in fk_economy (/ecostaff), so
-- that is checked first. If fk_economy is not running the ACE below is used.
Config.Staff = {
    ace = 'fk_spawn.staff',
    useEconomy = true, -- exports.fk_economy:IsStaff(src)
}

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
Config.Persistence = {
    file = 'data/spawns.json',
    saveDelay = 2000, -- ms, debounce for writes
}

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
Config.Notify = {
    -- 'auto' uses the chat resource when it is running, otherwise the feed
    -- notification in the top left.
    mode = 'auto',
    prefix = 'Spawn',
}
