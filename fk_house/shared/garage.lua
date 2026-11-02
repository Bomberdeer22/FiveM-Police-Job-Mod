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
        appearance = Garage.normalizeAppearance(entry.appearance),
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
        appearance = entry.appearance,
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
-- Appearance (what makes it *your* car, not just the same model)
-- ---------------------------------------------------------------------------
-- Everything here is a plain number so it can be validated on the server before
-- it is stored: colours, window tint, wheel type, the mod table and extras.

local function wholeNumber(value, min, max)
    value = House.toNumber(value)

    if not value then return nil end

    value = math.floor(value)

    if value < min or value > max then return nil end

    return value
end

--- Clean a vehicle appearance table sent by a client.
--- Unknown or out-of-range keys are dropped rather than rejected, so one bad
--- value cannot stop the rest of a paint job being saved.
--- @return table|nil appearance
function Garage.normalizeAppearance(appearance)
    if type(appearance) ~= 'table' then return nil end

    local clean = {}

    local colors = appearance.colors
    if type(colors) == 'table' then
        local primary = wholeNumber(colors.primary, 0, 159)
        local secondary = wholeNumber(colors.secondary, 0, 159)

        if primary and secondary then
            clean.colors = { primary = primary, secondary = secondary }
        end

        local custom = colors.custom
        if type(custom) == 'table' then
            local r = wholeNumber(custom.r, 0, 255)
            local g = wholeNumber(custom.g, 0, 255)
            local b = wholeNumber(custom.b, 0, 255)

            if r and g and b then
                clean.colors = clean.colors or {}
                clean.colors.custom = { r = r, g = g, b = b }
            end
        end
    end

    clean.tint = wholeNumber(appearance.tint, 0, 6)
    clean.wheelType = wholeNumber(appearance.wheelType, 0, 12)

    if type(appearance.mods) == 'table' then
        local mods = {}

        for slot, index in pairs(appearance.mods) do
            local cleanSlot = wholeNumber(slot, 0, 49)
            local cleanIndex = wholeNumber(index, 0, 255)

            if cleanSlot and cleanIndex then
                mods[cleanSlot] = cleanIndex
            end
        end

        if next(mods) then clean.mods = mods end
    end

    if type(appearance.extras) == 'table' then
        local extras = {}

        for slot, on in pairs(appearance.extras) do
            local cleanSlot = wholeNumber(slot, 1, 20)

            if cleanSlot and wholeNumber(on, 0, 1) then
                extras[cleanSlot] = wholeNumber(on, 0, 1)
            end
        end

        if next(extras) then clean.extras = extras end
    end

    if not next(clean) then return nil end

    return clean
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
