--[[
    fk_economy — server/staff.lua
    ---------------------------------------------------------------------------
    Decides who is staff and owns the persistent staff roster.

    A player is staff if ANY of these match, checked in this order:

      1. data/staff.json roster      — managed in game with /ecostaff,
                                       or from the console with eco_staff
                                       (no ACE permissions, no vMenu, no Discord)
      2. Config.Staff.identifiers    — hard-coded identifiers in config.lua
      3. Config.Staff.ace            — optional ACE permission
      4. vMenu admin permissions     — optional, disabled by default

    The roster is the recommended path: it survives restarts, needs no server.cfg
    edit, and is written in the same style as accounts.json.
]]

local RESOURCE = GetCurrentResourceName()
local ROSTER_FILE = Config.Staff.file or 'data/staff.json'

local roster = {}       -- [lowercased identifier] = entry
local rosterLoaded = false

-- ---------------------------------------------------------------------------
-- Config allowlist + optional vMenu nodes
-- ---------------------------------------------------------------------------

local STAFF_IDENTIFIERS = {}
for _, id in ipairs(Config.Staff.identifiers or {}) do
    STAFF_IDENTIFIERS[string.lower(id)] = true
end

local VMENU_PERMISSIONS = {}
do
    local vmenu = Config.Staff.vmenu
    if vmenu and vmenu.enabled == true then
        local seen = {}
        local function add(list)
            for _, node in ipairs(list or {}) do
                if type(node) == 'string' and node ~= '' and not seen[node] then
                    seen[node] = true
                    VMENU_PERMISSIONS[#VMENU_PERMISSIONS + 1] = node
                end
            end
        end

        add(vmenu.permissions)
        if vmenu.includeModerators then add(vmenu.moderatorPermissions) end
        add(vmenu.extraPermissions)
    end
end

-- ---------------------------------------------------------------------------
-- Roster storage
-- ---------------------------------------------------------------------------

local function isoNow()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function saveRoster()
    local payload = json.encode({
        version = 1,
        savedAt = isoNow(),
        staff   = roster,
    })

    local ok = SaveResourceFile(RESOURCE, ROSTER_FILE, payload, -1)
    if not ok then
        print(('^1[fk_economy] Could not write %s — check the resource folder is writable.^0')
            :format(ROSTER_FILE))
    end
    return ok
end

local function loadRoster()
    if rosterLoaded then return end
    rosterLoaded = true

    local raw = LoadResourceFile(RESOURCE, ROSTER_FILE)
    if not raw or raw == '' then return end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        print(('^1[fk_economy] %s is not valid JSON — starting with an empty staff list.^0')
            :format(ROSTER_FILE))
        return
    end

    local entries = decoded.staff or decoded
    if type(entries) ~= 'table' then return end

    for key, entry in pairs(entries) do
        if type(key) == 'string' and type(entry) == 'table' then
            roster[string.lower(key)] = {
                identifier = entry.identifier or key,
                name       = entry.name or 'Unknown',
                role       = entry.role or 'staff',
                addedBy    = entry.addedBy,
                addedAt    = tonumber(entry.addedAt) or os.time(),
            }
        end
    end
end

loadRoster()

-- ---------------------------------------------------------------------------
-- Roster API
-- ---------------------------------------------------------------------------

--- Primary identifier used when registering an online player.
--- @param src number
--- @return string|nil
local function primaryIdentifier(src)
    local identifiers = GetPlayerIdentifiers(src) or {}
    for _, id in ipairs(identifiers) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return identifiers[1]
end

--- Is this identifier (any identifier of the player) on the roster?
--- @param identifiers table list of identifiers
--- @return table|nil entry, string|nil matchedIdentifier
local function rosterEntryFor(identifiers)
    for _, id in ipairs(identifiers or {}) do
        local entry = roster[string.lower(id)]
        if entry then return entry, id end
    end
    return nil, nil
end

--- Add an identifier to the roster. Returns ok, err.
function StaffRegister(identifier, name, addedBy, role)
    loadRoster()

    identifier = tostring(identifier or '')
    if identifier == '' then return false, 'invalid_identifier' end

    local key = string.lower(identifier)
    roster[key] = {
        identifier = identifier,
        name       = name or (roster[key] and roster[key].name) or 'Unknown',
        role       = role or 'staff',
        addedBy    = addedBy or 'console',
        addedAt    = os.time(),
    }

    saveRoster()
    return true
end

--- Remove an identifier from the roster. Returns ok, err.
function StaffUnregister(identifier)
    loadRoster()

    identifier = tostring(identifier or '')
    if identifier == '' then return false, 'invalid_identifier' end

    local key = string.lower(identifier)
    if not roster[key] then return false, 'not_on_roster' end

    roster[key] = nil
    saveRoster()
    return true
end

--- Is an identifier on the roster?
function StaffIsRegistered(identifier)
    loadRoster()
    if type(identifier) ~= 'string' then return false end
    return roster[string.lower(identifier)] ~= nil
end

--- Number of staff on the roster.
function StaffCount()
    loadRoster()
    local count = 0
    for _ in pairs(roster) do count = count + 1 end
    return count
end

--- Is the roster empty (i.e. nobody has been added yet)?
function StaffRosterIsEmpty()
    return StaffCount() == 0
end

--- Copy of the roster, sorted by name.
--- @return table array of entries
function StaffList()
    loadRoster()

    local list = {}
    for _, entry in pairs(roster) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        return string.lower(a.name or '') < string.lower(b.name or '')
    end)
    return list
end

--- vMenu permission nodes currently watched (empty when detection is off).
function StaffVMenuPermissions()
    return VMENU_PERMISSIONS
end

-- ---------------------------------------------------------------------------
-- Staff check
-- ---------------------------------------------------------------------------

--- Work out whether a player may use the staff tools, and *why*.
--- @param src number|nil
--- @return boolean isStaff
--- @return string|nil source   'console' | 'roster' | 'identifier' | 'ace' | 'vmenu'
--- @return string|nil matched  identifier / permission node that matched
function CheckStaff(src)
    if not src or src < 1 then
        return Config.Staff.allowConsole == true, 'console', nil
    end

    local identifiers = GetPlayerIdentifiers(src) or {}

    -- 1. Persistent staff roster (data/staff.json)
    local entry, matchedIdentifier = rosterEntryFor(identifiers)
    if entry then
        return true, 'roster', matchedIdentifier
    end

    -- 2. config.lua identifier allowlist
    for _, id in ipairs(identifiers) do
        if STAFF_IDENTIFIERS[string.lower(id)] then
            return true, 'identifier', id
        end
    end

    -- 3. Optional ACE permission
    if Config.Staff.ace and IsPlayerAceAllowed(src, Config.Staff.ace) then
        return true, 'ace', Config.Staff.ace
    end

    -- 4. Optional vMenu admin detection (off by default)
    for _, node in ipairs(VMENU_PERMISSIONS) do
        if IsPlayerAceAllowed(src, node) then
            return true, 'vmenu', node
        end
    end

    return false, nil, nil
end

--- Simple boolean form, used all over the resource.
--- @param src number
--- @return boolean
function IsStaff(src)
    return CheckStaff(src) == true
end

--- Combat-log safe note: nothing to do here, but export the helper so commands
--- and other resources resolve identifiers the same way.
function StaffPrimaryIdentifier(src)
    return primaryIdentifier(src)
end
