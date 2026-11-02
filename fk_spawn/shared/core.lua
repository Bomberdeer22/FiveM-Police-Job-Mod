--[[
    fk_spawn — shared/core.lua
    ---------------------------------------------------------------------------
    Two small pieces of plumbing that every resource in this pack needs:

      Persist    — crash-safe JSON reads/writes inside the resource folder.
      RateLimit  — per-key token bucket for net events.

    fk_economy and fk_house carry an identical copy. FiveM resources are separate
    Lua states, so a shared file across resources is not possible without making
    them depend on each other; keeping the file identical is the trade-off.

    Nothing in here touches money or gameplay.
]]

local RESOURCE = GetCurrentResourceName()

-- ---------------------------------------------------------------------------
-- Persist
-- ---------------------------------------------------------------------------

Persist = Persist or {}

--- Where the last known good copy of a JSON file lives.
--- "data/accounts.json" -> "data/accounts.bak.json"
--- @return string
function Persist.backupPath(path)
    return (path:gsub('%.json$', '.bak.json'))
end

--- Rotating snapshot slots: "data/accounts.json" -> "data/accounts.1.json"
--- @return string
function Persist.slotPath(path, slot)
    return (path:gsub('%.json$', ('.%d.json'):format(math.floor(slot or 1))))
end

--- Read a raw file from the resource folder, or nil.
--- @return string|nil
function Persist.read(path)
    local raw = LoadResourceFile(RESOURCE, path)

    if not raw or raw == '' then return nil end

    return raw
end

--- Decode a JSON file, falling back to the .bak copy when the main file is
--- truncated or corrupt (which is what a crash mid-write looks like).
--- @return table|nil value, string|nil source
function Persist.decode(path)
    for _, candidate in ipairs({ path, Persist.backupPath(path) }) do
        local raw = Persist.read(candidate)

        if raw then
            local ok, value = pcall(json.decode, raw)

            if ok and type(value) == 'table' then
                return value, candidate
            end
        end
    end

    return nil
end

--- Write a text file inside the resource folder.
--- The previous contents are copied to the .bak path first, so a failed or
--- partial write still leaves a readable copy behind.
--- @return boolean ok
function Persist.write(path, contents)
    local previous = Persist.read(path)

    if previous then
        SaveResourceFile(RESOURCE, Persist.backupPath(path), previous, -1)
    end

    local ok = SaveResourceFile(RESOURCE, path, contents, -1)

    if not ok then
        print(('^1[%s] Could not write %s — does the "%s" folder exist? '
            .. 'SaveResourceFile cannot create folders.^0')
            :format(RESOURCE, path, path:match('^(.*)/') or 'data'))
    end

    return ok
end

--- Keep a rotating snapshot (1..slots) so there is more than one generation
--- to go back to. Cheap: these are small JSON files.
--- @return boolean ok
function Persist.snapshot(path, contents, slot, slots)
    slots = math.max(1, math.floor(slots or 3))
    slot = ((math.floor(slot or 1) - 1) % slots) + 1

    return SaveResourceFile(RESOURCE, Persist.slotPath(path, slot), contents, -1)
end

-- ---------------------------------------------------------------------------
-- RateLimit
-- ---------------------------------------------------------------------------

RateLimit = RateLimit or {}

local function defaultClock()
    if type(GetGameTimer) == 'function' then
        return GetGameTimer() / 1000.0
    end

    return os.time()
end

--- A token bucket per key. `rate` tokens are added per second, up to `burst`.
--- Example: RateLimit.new({ rate = 4, burst = 8 }) allows a short burst of 8
--- calls and then 4 per second.
--- @param options table { rate = number, burst = number, clock = function|nil }
--- @return table limiter
function RateLimit.new(options)
    options = type(options) == 'table' and options or {}

    local rate = tonumber(options.rate) or 4.0
    local burst = tonumber(options.burst) or math.max(1, rate * 2)

    return setmetatable({
        rate = rate,
        burst = burst,
        buckets = {},
        clock = options.clock or defaultClock,
        blocked = 0,
    }, { __index = RateLimit })
end

--- Take `cost` tokens for `key`. Returns false when the caller is over budget.
--- @return boolean allowed
function RateLimit:allow(key, cost)
    cost = tonumber(cost) or 1
    key = tostring(key or 'global')

    local now = self.clock()
    local bucket = self.buckets[key]

    if not bucket then
        bucket = { tokens = self.burst, last = now }
        self.buckets[key] = bucket
    end

    local elapsed = now - bucket.last

    if elapsed > 0 then
        bucket.tokens = math.min(self.burst, bucket.tokens + elapsed * self.rate)
        bucket.last = now
    end

    if bucket.tokens >= cost then
        bucket.tokens = bucket.tokens - cost
        return true
    end

    self.blocked = self.blocked + 1
    return false
end

--- Forget a key (player dropped, cooldown over).
function RateLimit:reset(key)
    if key == nil then
        self.buckets = {}
        return
    end

    self.buckets[tostring(key)] = nil
end

--- True when the caller has any budget left, without consuming it.
--- @return boolean
function RateLimit:peek(key)
    local bucket = self.buckets[tostring(key or 'global')]

    if not bucket then return true end

    return bucket.tokens >= 1
end

--- How many seconds until `key` has a token again (0 when it already has one).
--- @return number
function RateLimit:waitTime(key)
    local bucket = self.buckets[tostring(key or 'global')]

    if not bucket then return 0 end
    if bucket.tokens >= 1 then return 0 end
    if self.rate <= 0 then return math.huge end

    return (1 - bucket.tokens) / self.rate
end
