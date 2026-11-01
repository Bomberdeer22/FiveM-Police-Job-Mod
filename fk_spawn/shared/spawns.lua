--[[
    fk_spawn — shared/spawns.lua
    ---------------------------------------------------------------------------
    Pure spawn helpers shared by the client and the server: parsing,
    validation, lookup and formatting. No natives are called from here, so the
    logic can be unit tested (tests/spawn.test.js).
]]

Spawn = Spawn or {}

local LIMIT_XZ = 12000.0
local LIMIT_Z_MIN = -500.0
local LIMIT_Z_MAX = 3000.0
local LIMIT_HEADING = 720.0

-- ---------------------------------------------------------------------------
-- Numbers
-- ---------------------------------------------------------------------------

--- Coerce a value to a finite number. Accepts numbers and numeric strings
--- (console commands and JSON both hand us strings sometimes).
--- @return number|nil
function Spawn.toNumber(value)
    local number

    if type(value) == 'number' then
        number = value
    elseif type(value) == 'string' then
        number = tonumber(value)
    end

    if not number or number ~= number then return nil end -- NaN
    if number == math.huge or number == -math.huge then return nil end

    return number
end

--- @return number rounded to `decimals` places
function Spawn.round(value, decimals)
    local factor = 10 ^ (decimals or 2)
    return math.floor((Spawn.toNumber(value) or 0) * factor + 0.5) / factor
end

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

--- "Michael's Bedroom!" -> "michaels_bedroom" so names stay command friendly.
--- @return string|nil
function Spawn.sanitizeName(name)
    if type(name) ~= 'string' then return nil end

    local cleaned = name:lower()
        :gsub("['\226\128\153]", '')  -- apostrophes: "Michael's" -> "michaels"
        :gsub('[^%w]+', '_')
        :gsub('^_+', '')
        :gsub('_+$', '')

    if cleaned == '' then return nil end

    return cleaned
end

-- ---------------------------------------------------------------------------
-- Coordinates
-- ---------------------------------------------------------------------------

--- Accepts a table ({x=,y=,z=,w=} or {1,2,3,4} or a vector3/vector4),
--- or a string such as "-812.56, 174.85, 76.74, 200".
--- @return table|nil { x, y, z, w }
function Spawn.parseCoords(input)
    if type(input) == 'string' then
        local parts = {}
        for token in input:gmatch('[^,;%s]+') do parts[#parts + 1] = token end
        input = parts
    end

    if type(input) ~= 'table' then return nil end

    local x = Spawn.toNumber(input.x or input[1])
    local y = Spawn.toNumber(input.y or input[2])
    local z = Spawn.toNumber(input.z or input[3])
    local w = Spawn.toNumber(input.w or input[4])

    if not x or not y or not z then return nil end

    return { x = x, y = y, z = z, w = w }
end

--- @return boolean ok, string|nil reason
function Spawn.validateCoords(coords)
    if type(coords) ~= 'table' then return false, 'invalid_coords' end

    local x = Spawn.toNumber(coords.x)
    local y = Spawn.toNumber(coords.y)
    local z = Spawn.toNumber(coords.z)

    if not x or not y or not z then return false, 'invalid_coords' end

    if x < -LIMIT_XZ or x > LIMIT_XZ or y < -LIMIT_XZ or y > LIMIT_XZ then
        return false, 'out_of_bounds'
    end

    if z < LIMIT_Z_MIN or z > LIMIT_Z_MAX then return false, 'out_of_bounds' end

    if coords.w ~= nil then
        local w = Spawn.toNumber(coords.w)
        if not w then return false, 'invalid_heading' end
        if w < -LIMIT_HEADING or w > LIMIT_HEADING then return false, 'invalid_heading' end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Spawn points
-- ---------------------------------------------------------------------------

--- Turn a config/JSON entry into a clean spawn point.
--- @param entry table
--- @return table|nil point, string|nil reason
function Spawn.normalize(entry)
    if type(entry) ~= 'table' then return nil, 'invalid_entry' end

    local name = Spawn.sanitizeName(entry.name)
    if not name then return nil, 'missing_name' end

    local coords = Spawn.parseCoords(entry.coords or entry)
    if not coords then return nil, 'invalid_coords' end

    local ok, reason = Spawn.validateCoords(coords)
    if not ok then return nil, reason end

    return {
        name = name,
        label = type(entry.label) == 'string' and entry.label or entry.name,
        x = Spawn.round(coords.x, 2),
        y = Spawn.round(coords.y, 2),
        z = Spawn.round(coords.z, 2),
        w = coords.w and Spawn.round(coords.w, 1) or 0.0,
        interior = type(entry.interior) == 'string' and entry.interior or nil,
        enabled = entry.enabled ~= false,
    }
end

--- Normalize a list of entries (array or map). Invalid entries are skipped and
--- their reasons returned so the console can report them.
--- @return table points (array), table errors (array of { name, reason })
function Spawn.normalizeList(entries)
    local points, errors = {}, {}

    if type(entries) ~= 'table' then return points, errors end

    for key, entry in pairs(entries) do
        if type(entry) == 'table' and entry.name == nil and type(key) == 'string' then
            entry = setmetatable({ name = key }, { __index = entry })
        end

        local point, reason = Spawn.normalize(entry)

        if point then
            points[#points + 1] = point
        else
            errors[#errors + 1] = {
                name = type(entry) == 'table' and tostring(entry.name or key) or tostring(key),
                reason = reason or 'invalid_entry',
            }
        end
    end

    table.sort(points, function(a, b) return a.name < b.name end)

    return points, errors
end

--- Find a point by name (case/space insensitive). Falls back to the first
--- enabled point when `name` is nil.
--- @param points table array of normalized points
--- @return table|nil
function Spawn.resolve(points, name)
    if type(points) ~= 'table' then return nil end

    if name ~= nil and tostring(name) ~= '' then
        local wanted = Spawn.sanitizeName(tostring(name))
        if wanted then
            for _, point in ipairs(points) do
                if point.name == wanted then return point end
            end
        end
        return nil
    end

    for _, point in ipairs(points) do
        if point.enabled ~= false then return point end
    end

    return nil
end

--- "Michael's bedroom (x -812.56, y 174.85, z 76.74)"
function Spawn.describe(point)
    if type(point) ~= 'table' then return 'unknown' end

    return ('%s (%.2f, %.2f, %.2f)'):format(
        point.label or point.name or 'spawn',
        Spawn.toNumber(point.x) or 0.0,
        Spawn.toNumber(point.y) or 0.0,
        Spawn.toNumber(point.z) or 0.0
    )
end

--- One line per point for /spawnlist.
--- @return string
function Spawn.listText(points)
    if type(points) ~= 'table' or #points == 0 then return 'No spawn points configured.' end

    local lines = {}

    for _, point in ipairs(points) do
        lines[#lines + 1] = ('- %s%s: %s'):format(
            point.name,
            point.enabled == false and ' (disabled)' or '',
            Spawn.describe(point)
        )
    end

    return table.concat(lines, '\n')
end
