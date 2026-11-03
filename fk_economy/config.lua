--[[
    fk_economy — config.lua
    ---------------------------------------------------------------------------
    Shared config. Loaded on BOTH client and server, so keep it free of
    native calls. Everything you would normally want to tweak lives here.

    Order of business:
      1. Currency / formatting
      2. Starting balances
      3. HUD + menu defaults
      4. Staff permissions
      5. Limits
      6. Persistence
      7. Item prices (this is the bit the main police mod will read later)
]]

Config = {}

-- ---------------------------------------------------------------------------
-- 0. SINGLE-PLAYER
-- ---------------------------------------------------------------------------
-- This server has exactly one player on it, so the machinery that only exists
-- to keep players from flooding each other is switched off:
--   * net-event rate limits (Config.RateLimit)  -> skipped when this is true
--   * staff menu player list                    -> still works, it is one row
-- The money itself is still server-authoritative; this only removes throttles.
Config.Singleplayer = true

-- ---------------------------------------------------------------------------
-- 1. CURRENCY
-- ---------------------------------------------------------------------------
Config.Locale = 'en-GB'

Config.Currency = {
    symbol      = '$',
    code        = 'USD',
    -- How many decimal places to show. 0 = $1,250     2 = $1,250.00
    decimals    = 0,
    -- true  -> $1,250     false -> 1,250$
    symbolFirst = true,
}

-- ---------------------------------------------------------------------------
-- 2. STARTING BALANCES (only applied the first time a player is seen)
-- ---------------------------------------------------------------------------
Config.StartingBalance = {
    cash = 750,
    bank = 2500,
}

-- Accounts shown on the HUD / used by the API.
-- Removing one here removes it from the UI, the API and the staff menu.
Config.Accounts = {
    cash = { label = 'Cash', enabled = true },
    bank = { label = 'Bank', enabled = true },
}

-- ---------------------------------------------------------------------------
-- 3. HUD + MENU DEFAULTS
--    These are only *defaults*. Each player can move/resize the HUD with the
--    in-game menu; their choice is saved to their client KVP storage.
-- ---------------------------------------------------------------------------
Config.UI = {
    -- Default HUD placement. x/y are percentages of the game viewport
    -- (top-left corner of the HUD), so it lands in the same-ish spot on
    -- 1080p, 1440p and ultrawide.
    default = {
        visible = true,
        x       = 1.0,   -- 0 = far left
        y       = 78.0,  -- 100 = bottom
        scale   = 1.0,
        opacity = 1.0,
        compact = false, -- true = single line "Cash / Bank" instead of two rows
    },

    -- Clamp values for the customisation menu sliders
    minScale   = 0.65,
    maxScale   = 1.80,
    minOpacity = 0.25,
    maxOpacity = 1.00,

    -- Accent colour (any CSS colour). Police blue by default.
    accent = '#3b82f6',

    -- Show "−$120" / "+$500" float text and a brief flash when money changes
    animateChanges  = true,
    showDeltaFloat  = true,

    -- Number of ms the count-up/count-down animation lasts
    numberTweenMs = 650,

    -- Hide the HUD entirely while a player is in a vehicle? (false = always on)
    hideWhenDead = false,

    -- Snap the HUD to the nearest screen edge when dropped within this
    -- many pixels of it (0 disables snapping)
    edgeSnapPx = 24,
}

Config.Keys = {
    -- Key that opens the economy menu. Players can rebind it in
    -- Settings > Key Bindings > FiveM (RegisterKeyMapping).
    menu = 'F7',
}

-- ---------------------------------------------------------------------------
-- 4. STAFF / ADMIN
--    Staff are resolved with ACE permissions (recommended) or the identifier
--    list below (handy for one-off server owners / testing).
--
--    Recommended server.cfg lines:
--      add_ace group.admin fk_economy.staff allow
--      add_principal identifier.license:YOUR_LICENSE_HERE group.admin
-- ---------------------------------------------------------------------------
Config.Staff = {
    -- -----------------------------------------------------------------------
    -- Staff list (recommended)
    -- A persistent roster stored in data/staff.json. No ACE permissions, no
    -- vMenu setup and no Discord needed:
    --
    --   In game:            /ecostaff claim     (first time, while list is empty)
    --                       /ecostaff add 3     (add player with server id 3)
    --                       /ecostaff list
    --                       /ecostaff remove 3
    --   Server console:     eco_staff add 3
    --                       eco_staff list
    --                       eco_staff remove 3
    --
    -- Staff can manage the list themselves once they are on it.
    -- -----------------------------------------------------------------------
    file = 'data/staff.json',

    -- Allow the very first player to run /ecostaff claim while the staff list
    -- is still empty (handy for a fresh install). Set to false once you have
    -- added yourself — after that, claim is refused anyway.
    allowClaim = true,

    -- Optional ACE permission node checked for staff access
    ace = 'fk_economy.staff',

    -- Optional extra identifiers that are always staff, e.g.
    -- { 'license:110000112345678' }
    identifiers = {},

    -- Allow the server console / rcon to use the money commands
    allowConsole = true,

    -- Quick-amount buttons in the staff panel
    quickAmounts = { 100, 500, 1000, 5000, 25000 },

    -- Hard cap on a single staff action (protects against typos / fat fingers)
    maxPerAction = 1000000,

    -- Reason strings offered in the staff panel dropdown. Free text is also
    -- accepted; these just make the audit log tidier.
    reasons = {
        'Payroll',
        'Bonus',
        'Fine',
        'Correction',
        'Refund',
        'Testing',
    },

    -- Write every staff money change + purchase to data/transactions.log
    logTransactions = true,

    -- -----------------------------------------------------------------------
    -- vMenu integration
    -- vMenu decides who is staff with ACE permissions, so we simply check the
    -- same permission nodes. Anyone allowed ANY of the permissions below is
    -- treated as economy staff (full access to the staff panel + commands).
    --
    -- Requires vMenu to be permission-driven (vmenu_use_permissions true, the
    -- default). Nothing breaks if vMenu is not installed — the checks just
    -- return false.
    -- -----------------------------------------------------------------------
    vmenu = {
        -- OFF by default. Turn on only if you want players that vMenu treats as
        -- admins to be economy staff automatically.
        enabled = false,

        -- Admin-level vMenu permissions. Being allowed any one of these counts.
        permissions = {
            'vMenu.Everything',                  -- full menu access
            'vMenu.OnlinePlayers.All',           -- every online-player action
            'vMenu.OnlinePlayers.PermBan',       -- permanent bans
            'vMenu.OnlinePlayers.Unban',         -- lift bans
            'vMenu.OnlinePlayers.Identifiers',   -- view player identifiers
            'vMenu.Staff',                       -- staff-only menu flag
        },

        -- Also treat vMenu moderators (kick / tempban / summon) as staff?
        -- false = only admins get money tools. Set true on servers where
        -- moderators are trusted with balances.
        includeModerators = false,

        moderatorPermissions = {
            'vMenu.OnlinePlayers.TempBan',
            'vMenu.OnlinePlayers.Kick',
            'vMenu.OnlinePlayers.Summon',
            'vMenu.OnlinePlayers.ViewBannedPlayers',
        },

        -- Any extra permission nodes you want to accept, e.g. a custom group
        -- node you already use for staff: { 'group.dreamstaff' }
        extraPermissions = {},
    },
}

-- ---------------------------------------------------------------------------
-- 5. LIMITS
-- ---------------------------------------------------------------------------
Config.Limits = {
    -- Balance ceiling per account
    maxBalance = 999999999,

    -- Smallest amount that may be moved (1 = whole units)
    minAmount  = 1,

    -- Round balances to whole numbers (set false if you want cents)
    wholeNumbers = true,

    -- Which resources may call the force-a-balance export.
    -- AddMoney/RemoveMoney are audited and can only move money in the open;
    -- SetMoney can *invent* it, so it is restricted by default. The console
    -- and this resource itself are always allowed; add your own resources by
    -- name (the folder name in your resources dir), e.g. { 'fk_police' }.
    trustedResources = {},

    -- ACE permission that may also call SetMoney, e.g. 'fk_economy.admin'.
    -- Leave nil to rely on the list above only.
    setMoneyAce = nil,
}

-- ---------------------------------------------------------------------------
-- 6. PERSISTENCE
--    File based by default (zero dependencies). Files live inside the
--    resource folder so no database is needed to get the mod running.
-- ---------------------------------------------------------------------------
Config.Persistence = {
    file = 'data/accounts.json',

    -- Auto-save interval in seconds (also saves on drop / resource stop)
    saveInterval = 60,

    -- Before every write the previous file is copied to accounts.bak.json, and
    -- a rotating snapshot (accounts.1.json .. accounts.N.json) is kept so a
    -- crash or a bad edit can always be rolled back. Nothing here needs a
    -- database or a directory that does not already exist.
    backups = {
        enabled      = true,
        slots        = 3,    -- accounts.1.json .. accounts.3.json
        everySeconds = 300,  -- how often a snapshot is rotated in
    },

    -- Optional transaction audit log (set Config.Staff.logTransactions = false
    -- to disable writing)
    transactionLog = 'data/transactions.log',
    maxLogLines    = 2000,
}

-- If you'd rather log with a server framework later, set this to your own
-- function in server code. It is called as Config.Log.hook(...) when present.
-- Example:
--   Config.Log.hook = function(actor, target, account, amount, reason)
--       print(('AUDIT %s -> %s %s %s (%s)'):format(actor, target, account, amount, reason))
--   end
Config.Log = {}

-- ---------------------------------------------------------------------------
-- 6b. RATE LIMITS
--     Net events are cheap to spam from a mod menu. These are token buckets:
--     `rate` events per second, with a short `burst` allowed on top.
--     A blocked request is dropped silently and counted in /econstatus.
-- ---------------------------------------------------------------------------
-- Ignored while Config.Singleplayer is true (the only client cannot flood you
-- in any way that matters). Set Singleplayer = false to use them again.
Config.RateLimit = {
    -- Client asking for its own HUD state (fires on spawn + menu open)
    requestState   = { rate = 2, burst = 20 },
    -- Staff menu player list (builds a list of every online player)
    requestPlayers = { rate = 1, burst = 5 },
    -- Staff give/take actions: people click in bursts, so allow a big burst
    -- and clamp the sustained rate.
    staffAction    = { rate = 1, burst = 30 },
    -- Item purchase (a person buying 30 things at once is not a person)
    purchase       = { rate = 2, burst = 10 },
}

-- ---------------------------------------------------------------------------
-- 6c. ITEMS THE PLAYER OWNS
--     Buying an item now also stores it on the account (see /items and the
--     GetItems export), so equipment survives a reconnect and can be taken
--     away again. Set to false to keep the old "money only" behaviour.
-- ---------------------------------------------------------------------------
Config.ItemsOwned = {
    enabled = true,
    -- Stack limit per item key
    maxStack = 99,
    -- Categories consumed at the till, so they are never stored on the
    -- account. Everything else (Equipment, Licenses) is kept.
    skipCategories = {
        Services    = true,
        Vehicles    = true,
        Consumables = true,
    },
}

-- ---------------------------------------------------------------------------
-- 7. ITEM PRICES
--    This is the price list the main police mod will import later, e.g.
--        local price = exports.fk_economy:GetPrice('bodycam')
--        local ok    = exports.fk_economy:TryPurchase(src, 'bodycam', 1)
--
--    Fields:
--      label       display name
--      price       buy price per unit (required)
--      sell        optional sell-back price (for later resale features)
--      category    groups items in the prices tab of the menu
--      description optional one-liner shown in the UI
-- ---------------------------------------------------------------------------
Config.Items = {
    -- Equipment -----------------------------------------------------------------
    ['bodycam'] = {
        label = 'Body Camera', price = 250, sell = 120, category = 'Equipment',
        description = 'Records your shift. Useful in court.',
    },
    ['radio'] = {
        label = 'Police Radio', price = 450, sell = 200, category = 'Equipment',
        description = 'Lets you talk to dispatch.',
    },
    ['handcuffs'] = {
        label = 'Handcuffs', price = 120, sell = 50, category = 'Equipment',
        description = 'Standard issue restraints.',
    },
    ['flashlight'] = {
        label = 'Flashlight', price = 80, sell = 30, category = 'Equipment',
        description = 'For dark alleyways.',
    },
    ['baton'] = {
        label = 'Baton', price = 200, sell = 80, category = 'Equipment',
        description = 'Less-lethal compliance tool.',
    },
    ['spike_strips'] = {
        label = 'Spike Strips', price = 600, sell = 250, category = 'Equipment',
        description = 'One use per deployment.',
    },
    ['evidence_kit'] = {
        label = 'Evidence Kit', price = 350, sell = 140, category = 'Equipment',
        description = 'Bagging and tagging.',
    },
    ['armour_vest'] = {
        label = 'Armour Vest', price = 900, sell = 400, category = 'Equipment',
        description = 'Ballistic protection.',
    },
    ['repair_kit'] = {
        label = 'Repair Kit', price = 300, sell = 120, category = 'Equipment',
        description = 'Field repairs for a damaged cruiser.',
    },

    -- Consumables ---------------------------------------------------------------
    ['coffee'] = {
        label = 'Coffee', price = 5, sell = 1, category = 'Consumables',
        description = 'Keeps you awake on nights.',
    },
    ['donut'] = {
        label = 'Donut', price = 3, sell = 1, category = 'Consumables',
        description = 'Tradition.',
    },
    ['water'] = {
        label = 'Water', price = 2, sell = 1, category = 'Consumables',
        description = 'Hydration.',
    },
    ['medkit'] = {
        label = 'Medical Kit', price = 150, sell = 60, category = 'Consumables',
        description = 'Stop the bleeding before EMS arrive.',
    },
    ['fuel_can'] = {
        label = 'Fuel Can', price = 60, sell = 20, category = 'Consumables',
        description = 'Five litres of petrol.',
    },
    ['ammo_pistol'] = {
        label = 'Pistol Ammo (50)', price = 120, sell = 40, category = 'Consumables',
        description = 'Range ammunition.',
    },

    -- Licenses ------------------------------------------------------------------
    ['license_driving'] = {
        label = 'Driving License', price = 500, sell = 0, category = 'Licenses',
        description = 'Required to drive legally.',
    },
    ['license_weapon'] = {
        label = 'Weapon License', price = 2500, sell = 0, category = 'Licenses',
        description = 'Firearms permit.',
    },
    ['license_pilot'] = {
        label = 'Pilot License', price = 8000, sell = 0, category = 'Licenses',
        description = 'Helicopter and fixed wing.',
    },

    -- Services ------------------------------------------------------------------
    ['service_repair'] = {
        label = 'Vehicle Repair', price = 400, sell = 0, category = 'Services',
        description = 'Full repair at the station workshop.',
    },
    ['service_clean'] = {
        label = 'Vehicle Valet', price = 100, sell = 0, category = 'Services',
        description = 'Wash and clean the cruiser.',
    },
    ['service_impound'] = {
        label = 'Impound Release', price = 750, sell = 0, category = 'Services',
        description = 'Get your vehicle back from the pound.',
    },
    ['service_medical'] = {
        label = 'Hospital Treatment', price = 250, sell = 0, category = 'Services',
        description = 'Patched up at Pillbox Hill.',
    },

    -- Vehicles ------------------------------------------------------------------
    ['vehicle_cruiser'] = {
        label = 'Patrol Cruiser', price = 45000, sell = 30000, category = 'Vehicles',
        description = 'Issued to your department.',
    },
    ['vehicle_interceptor'] = {
        label = 'Interceptor', price = 85000, sell = 60000, category = 'Vehicles',
        description = 'High speed pursuit unit.',
    },
    ['vehicle_helicopter'] = {
        label = 'Air Support Unit', price = 350000, sell = 250000, category = 'Vehicles',
        description = 'Requires a pilot license.',
    },
}
