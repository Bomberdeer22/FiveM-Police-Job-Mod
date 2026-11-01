--[[
    fk_house — shared/house.lua
    ---------------------------------------------------------------------------
    Pure helpers: spot validation, lookup and outfit validation. No natives, so
    this file is unit tested (tests/house.test.js).
]]

House = House or {}

local MAX_SPOTS = 64
local LIMIT_XZ = 12000.0

-- ---------------------------------------------------------------------------
-- Numbers / distance
-- ---------------------------------------------------------------------------

function House.toNumber(value)
    local number

    if type(value) == 'number' then
        number = value
    elseif type(value) == 'string' then
        number = tonumber(value)
    end

    if not number or number ~= number then return nil end
    if number == math.huge or number == -math.huge then return nil end

    return number
end

--- Distance between anything with x/y/z fields (table, vector3, player coords).
function House.distance(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return nil end

    local ax, ay, az = House.toNumber(a.x), House.toNumber(a.y), House.toNumber(a.z)
    local bx, by, bz = House.toNumber(b.x), House.toNumber(b.y), House.toNumber(b.z)

    if not ax or not ay or not az or not bx or not by or not bz then return nil end

    local dx, dy, dz = ax - bx, ay - by, az - bz

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function House.sanitizeName(name)
    if type(name) ~= 'string' then return nil end

    local cleaned = name:lower()
        :gsub("['\226\128\153]", '')
        :gsub('[^%w]+', '_')
        :gsub('^_+', '')
        :gsub('_+$', '')

    if cleaned == '' then return nil end

    return cleaned
end

-- ---------------------------------------------------------------------------
-- Spots
-- ---------------------------------------------------------------------------

--- @return table|nil spot, string|nil reason
function House.normalizeSpot(entry)
    if type(entry) ~= 'table' then return nil, 'invalid_entry' end

    local name = House.sanitizeName(entry.name)
    if not name then return nil, 'missing_name' end

    if type(entry.type) ~= 'string' or entry.type == '' then return nil, 'missing_type' end

    local coords = entry.coords
    local x = type(coords) == 'table' and House.toNumber(coords.x) or nil
    local y = type(coords) == 'table' and House.toNumber(coords.y) or nil
    local z = type(coords) == 'table' and House.toNumber(coords.z) or nil

    if not x or not y or not z then return nil, 'invalid_coords' end
    if math.abs(x) > LIMIT_XZ or math.abs(y) > LIMIT_XZ or math.abs(z) > 3000.0 then
        return nil, 'out_of_bounds'
    end

    local radius = House.toNumber(entry.radius) or 2.0
    if radius < 0.5 or radius > 20.0 then return nil, 'invalid_radius' end

    return {
        name = name,
        label = type(entry.label) == 'string' and entry.label or name,
        type = entry.type,
        x = x,
        y = y,
        z = z,
        radius = radius,
        options = type(entry.options) == 'table' and entry.options or {},
        raw = entry,
    }
end

--- @return table spots (array), table errors (array of { name, reason })
function House.normalizeSpots(entries)
    local spots, errors = {}, {}

    if type(entries) ~= 'table' then return spots, errors end

    for key, entry in pairs(entries) do
        if type(entry) == 'table' and entry.name == nil and type(key) == 'string' then
            entry = setmetatable({ name = key }, { __index = entry })
        end

        local spot, reason = House.normalizeSpot(entry)

        if spot then
            if #spots >= MAX_SPOTS then break end
            spots[#spots + 1] = spot
        else
            errors[#errors + 1] = {
                name = type(entry) == 'table' and tostring(entry.name or key) or tostring(key),
                reason = reason or 'invalid_entry',
            }
        end
    end

    table.sort(spots, function(a, b) return a.name < b.name end)

    return spots, errors
end

--- Closest spot within its own radius.
--- @param spots table array of normalized spots
--- @param pos table { x, y, z }
--- @return table|nil spot, number|nil distance
function House.nearest(spots, pos)
    local best, bestDistance = nil, nil

    for _, spot in ipairs(spots or {}) do
        local distance = House.distance(spot, pos)

        if distance and distance <= spot.radius then
            if not bestDistance or distance < bestDistance then
                best, bestDistance = spot, distance
            end
        end
    end

    return best, bestDistance
end

--- Movement of a spot away from the configured value, with the override applied.
--- @return table merged spot
function House.applyOverride(spot, override)
    if type(override) ~= 'table' then return spot end

    local x = House.toNumber(override.x)
    local y = House.toNumber(override.y)
    local z = House.toNumber(override.z)

    if x and y and z then
        spot.x, spot.y, spot.z = x, y, z
        spot.fromOverride = true
    end

    return spot
end

-- ---------------------------------------------------------------------------
-- Outfits
-- ---------------------------------------------------------------------------

local MAX_COMPONENTS = 12 -- GTA has 12 clothing components (0-11)
local MAX_PROPS = 5       -- and 5 props (0-4), use -1 for "none"

local function normalizePart(entry, maxIndex, allowMinusOne)
    if type(entry) ~= 'table' then return nil end

    local index = House.toNumber(entry.i)
    local drawable = House.toNumber(entry.d)
    local texture = House.toNumber(entry.t) or 0

    if not index or not drawable then return nil end
    if index < 0 or index > maxIndex then return nil end
    if drawable < (allowMinusOne and -1 or 0) or drawable > 255 then return nil end
    if texture < (allowMinusOne and -1 or 0) or texture > 255 then return nil end

    return { i = math.floor(index), d = math.floor(drawable), t = math.floor(texture) }
end

--- Validate an outfit sent by a client before it is stored.
--- @return boolean ok, string|nil reason, table|nil clean
function House.normalizeOutfit(outfit)
    if type(outfit) ~= 'table' then return false, 'invalid_outfit' end

    local comps, props = {}, {}

    for _, entry in ipairs(outfit.comps or {}) do
        local part = normalizePart(entry, MAX_COMPONENTS - 1, false)
        if not part then return false, 'invalid_component' end
        comps[#comps + 1] = part
    end

    for _, entry in ipairs(outfit.props or {}) do
        local part = normalizePart(entry, MAX_PROPS - 1, true)
        if not part then return false, 'invalid_prop' end
        props[#props + 1] = part
    end

    if #comps == 0 then return false, 'empty_outfit' end
    if #comps > MAX_COMPONENTS then return false, 'too_many_components' end

    return true, nil, { comps = comps, props = props, savedAt = outfit.savedAt }
end

--- Short human readable description used in the menu.
function House.describeOutfit(outfit)
    if type(outfit) ~= 'table' then return 'empty' end

    local parts = 0

    for _ in ipairs(outfit.comps or {}) do parts = parts + 1 end

    if parts == 0 then return 'empty' end

    return ('%d piece%s'):format(parts, parts == 1 and '' or 's')
end
