--[[
    fk_house — shared/garage.lua
    ---------------------------------------------------------------------------
    Pure helpers for the personal vehicle that lives in Michael's garage:
    model/plate validation, zone tests and the "where do I put it back" rule.

    No natives in here, so all of it is unit tested (tests/house.test.js).
]]

Garage = Garage or {}

Garage.MAX_MODEL_LENGTH = 64
Garage.MAX_PLATE_LENGTH = 8

-- ---------------------------------------------------------------------------
-- Model / plate
-- ---------------------------------------------------------------------------

--- Vehicle model names are lowercase with digits and underscores ("adder",
--- "sultanrs", "police2"). Anything else is not a model and is refused.
--- The name is only a label: the model hash read from the actual entity is what
--- is used when the car is created again, so the car is always the same model
--- even when the display name differs from the spawn name (police3 -> POLICE).
--- @return string|nil
function Garage.normalizeModel(value)
    if type(value) ~= 'string' then return nil end

    local model = value:lower()
        :gsub('%s+', '')
        :gsub('[^%w_%-]', '')

    if model == '' or #model > Garage.MAX_MODEL_LENGTH then return nil end
    if not model:match('^%a') then return nil end

    return model
end

--- @return string|nil
function Garage.normalizePlate(value)
    if type(value) ~= 'string' then return nil end

    local plate = value:upper()
        :gsub('[^%w ]', '')
        :gsub('^%s+', '')
        :gsub('%s+$', '')

    if plate == '' then return nil end
    if #plate > Garage.MAX_PLATE_LENGTH then plate = plate:sub(1, Garage.MAX_PLATE_LENGTH) end

    return plate
end

--- @return boolean
function Garage.isBlocked(model, list)
    if type(model) ~= 'string' then return false end

    for _, blocked in ipairs(list or {}) do
        if type(blocked) == 'string' and blocked:lower() == model then return true end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

--- Validate a vehicle record before it is stored or restored.
--- @return table|nil, string|nil reason
function Garage.normalizeVehicle(entry)
    if type(entry) ~= 'table' then return nil, 'invalid_entry' end

    local model = Garage.normalizeModel(entry.model)
    if not model then return nil, 'invalid_model' end

    local x, y, z = House.readCoords(entry)

    if not x or not y or not z then return nil, 'invalid_coords' end
    if math.abs(x) > 12000.0 or math.abs(y) > 12000.0 or math.abs(z) > 3000.0 then
        return nil, 'out_of_bounds'
    end

    local w = House.toNumber(entry.w) or 0.0
    local hash = House.toNumber(entry.hash)

    if hash then
        hash = math.floor(hash)
        if hash <= 0 or hash > 4294967295 then hash = nil end
    end

    return {
        model = model,
        hash = hash,
        plate = Garage.normalizePlate(entry.plate) or 'FKHOUSE',
        x = x,
        y = y,
        z = z,
        w = w % 360.0,
        savedAt = type(entry.savedAt) == 'string' and entry.savedAt or nil,
    }
end

--- What the client is allowed to see.
--- @return table|nil
function Garage.publicView(entry)
    if type(entry) ~= 'table' then return nil end

    return {
        model = entry.model,
        hash = entry.hash,
        plate = entry.plate,
        savedAt = entry.savedAt,
    }
end

--- Chat-friendly description, e.g. "adder (FK 1234)".
--- @return string
function Garage.describe(entry)
    if type(entry) ~= 'table' then return 'nothing stored' end

    return ('%s (%s)'):format(
        Garage.normalizeModel(entry.model) or 'unknown',
        Garage.normalizePlate(entry.plate) or 'no plate')
end

-- ---------------------------------------------------------------------------
-- Where the car goes
-- ---------------------------------------------------------------------------

--- Is this position inside the garage?
--- @return boolean
function Garage.inZone(pos, coords, radius)
    local distance = House.distance(pos, coords)

    if not distance then return false end

    return distance <= (House.toNumber(radius) or 6.0)
end

--- Position used when the car is recreated.
--- The spot it was parked in wins as long as that spot is still inside the
--- garage; otherwise the configured spawn point is used, so a bad record can
--- never drop a car into a wall or the sea.
--- @return number x, number y, number z, number w
function Garage.spawnPoint(stored, config)
    config = type(config) == 'table' and config or {}

    local spawn = type(config.spawn) == 'table' and config.spawn or {}
    local fallbackX = House.toNumber(spawn.x) or 0.0
    local fallbackY = House.toNumber(spawn.y) or 0.0
    local fallbackZ = House.toNumber(spawn.z) or 0.0
    local fallbackW = House.toNumber(spawn.w) or 0.0

    local x, y, z = House.readCoords(stored)

    if x and y and z and Garage.inZone({ x = x, y = y, z = z }, config.coords, config.radius) then
        return x, y, z, House.toNumber(stored.w) or fallbackW
    end

    return fallbackX, fallbackY, fallbackZ, fallbackW
end
