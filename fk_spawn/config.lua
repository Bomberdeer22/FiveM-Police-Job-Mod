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
        -- Researched position: inside the master bedroom, just past the suite
        -- door, facing into the room (see docs/COORDINATES.md). The floor up
        -- here is at 75.74; the old 76.74 point floated a metre above it.
        coords = { x = -810.60, y = 178.20, z = 75.90, w = 90.0 },
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
        -- Michael's house (v_int_44 / v_michael). This is the interior's
        -- placement origin, straight out of the game's MLO data.
        coords = { x = -807.343, y = 174.981, z = 71.163 },
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
    -- The server keeps offering the spawn until the client confirms it landed.
    -- First push this long after joining (lets the client scripts load) ...
    pushDelay = 3000,
    -- ... and give up after this many ms in total.
    joinFallback = 30000,
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

    -- Anti-spawnkill: a short invulnerability after the teleport, so a camper
    -- cannot farm someone who is still behind the fade. Set seconds = 0 to
    -- disable, or protect = { enabled = false }.
    protection = {
        enabled = true,
        seconds = 5,
    },
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

    -- Writes go through shared/core.lua: the previous file is kept as
    -- spawns.bak.json and read back automatically if the main file is ever
    -- truncated by a crash.
    backups = {
        enabled = true,
        slots = 3,
        everySeconds = 300,
    },
}

-- ---------------------------------------------------------------------------
-- RATE LIMITS
--   Token buckets from shared/core.lua. `/spawn` typed twice in a row is fine
--   (burst); a script asking 100 times a second is not.
-- ---------------------------------------------------------------------------
Config.RateLimit = {
    requestSpawns   = { rate = 2, burst = 10 },
    requestSpawn    = { rate = 0.2, burst = 5 },
    setSpawn        = { rate = 1, burst = 5 },
    resetSpawn      = { rate = 1, burst = 5 },
    isSpawnPending  = { rate = 4, burst = 30 },
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
