--[[
    fk_economy — server/accounts.lua
    ---------------------------------------------------------------------------
    Owns the player account store and all disk I/O.

    * Accounts are keyed by license identifier so money survives reconnects,
      character slots and resource restarts.
    * Every write marks the store dirty; a background thread flushes it to
      data/accounts.json every Config.Persistence.saveInterval seconds, and
      immediately on player drop / resource stop.
    * Writes go through shared/core.lua, so the previous copy is kept as
      accounts.bak.json and a rotating snapshot is kept too. A crash mid-write
      can never leave you with an unreadable file and no way back.
    * Nothing in here is exposed to the client directly — see server/main.lua
      for the validated API.
]]

AccountStore = {}

local RESOURCE = GetCurrentResourceName()

local store = {
    accounts = {},   -- [identifier] = { cash, bank, items, name, firstSeen, lastSeen, earned, spent }
    loaded   = false,
    dirty    = false,
    lastSave = 0,    -- unix time of the last successful write
    lastError = nil, -- last write failure, for /econstatus
}

local logLines = nil
local snapshotSlot = 0
local lastSnapshot = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function timestamp()
    return os.time()
end

local function isoTime(ts)
    return os.date('!%Y-%m-%dT%H:%M:%SZ', ts or os.time())
end

--- Read a file from inside the resource, or return nil.
local function readFile(path)
    return Persist.read(path)
end

--- Write a file inside the resource (keeping a .bak of the previous copy).
local function writeFile(path, contents)
    return Persist.write(path, contents)
end

--- Keep a rotating snapshot so there is more than one generation to go back to.
local function maybeSnapshot(contents)
    local backups = Config.Persistence.backups

    if not backups or backups.enabled == false then return end

    local now = os.time()
    local every = math.max(60, tonumber(backups.everySeconds) or 300)

    if (now - lastSnapshot) < every then return end

    lastSnapshot = now
    snapshotSlot = snapshotSlot + 1

    Persist.snapshot(Config.Persistence.file, contents, snapshotSlot, backups.slots or 3)
end

-- ---------------------------------------------------------------------------
-- Load / save
-- ---------------------------------------------------------------------------

function AccountStore.load()
    if store.loaded then return true end

    local decoded, source = Persist.decode(Config.Persistence.file)
    if decoded then
        if source and source ~= Config.Persistence.file then
            print(('^3[fk_economy] %s was unreadable — restored %s instead.^0')
                :format(Config.Persistence.file, source))
        end

        local accounts = decoded.accounts or decoded
        if type(accounts) == 'table' then
            for identifier, account in pairs(accounts) do
                if type(identifier) == 'string' and type(account) == 'table' then
                    store.accounts[identifier] = {
                        cash      = tonumber(account.cash) or 0,
                        bank      = tonumber(account.bank) or 0,
                        items     = AccountStore.sanitizeItems(account.items),
                        name      = account.name,
                        firstSeen = tonumber(account.firstSeen) or timestamp(),
                        lastSeen  = tonumber(account.lastSeen) or timestamp(),
                        earned    = tonumber(account.earned) or 0,
                        spent     = tonumber(account.spent) or 0,
                    }
                end
            end
            print(('^2[fk_economy] Loaded %d account(s) from %s^0')
                :format((function()
                    local n = 0
                    for _ in pairs(store.accounts) do n = n + 1 end
                    return n
                end)(), Config.Persistence.file))
        end
    else
        print(('^2[fk_economy] No %s yet — a fresh one will be created on first save.^0')
            :format(Config.Persistence.file))
    end

    store.loaded = true
    return true
end

function AccountStore.save(force)
    if not force and not store.dirty then return true end

    local payload = json.encode({
        version  = 2,
        savedAt  = isoTime(),
        accounts = store.accounts,
    })

    local ok = writeFile(Config.Persistence.file, payload)
    if ok then
        store.dirty = false
        store.lastSave = os.time()
        store.lastError = nil
        maybeSnapshot(payload)
    else
        store.lastError = 'write failed'
    end
    return ok
end

function AccountStore.markDirty()
    store.dirty = true
end

-- ---------------------------------------------------------------------------
-- Transaction audit log
-- ---------------------------------------------------------------------------

local function loadLog()
    if logLines then return logLines end
    logLines = {}
    local raw = readFile(Config.Persistence.transactionLog)
    if raw then
        for line in raw:gmatch('[^\n]+') do
            logLines[#logLines + 1] = line
        end
        -- Trim to the configured maximum so the file cannot grow forever.
        local max = Config.Persistence.maxLogLines or 2000
        if #logLines > max then
            local trimmed = {}
            for i = #logLines - max + 1, #logLines do
                trimmed[#trimmed + 1] = logLines[i]
            end
            logLines = trimmed
        end
    end
    return logLines
end

--- Append an audit line. Safe to call from anywhere on the server.
--- @param actor string   who performed the action
--- @param target string  who it was performed on
--- @param account string cash/bank
--- @param amount number   signed amount
--- @param reason string
function AccountStore.log(actor, target, account, amount, reason)
    if not Config.Staff.logTransactions then return end

    local line = ('[%s] actor="%s" target="%s" account=%s amount=%s reason="%s"')
        :format(isoTime(), tostring(actor), tostring(target), tostring(account),
            tostring(amount), tostring(reason or 'unspecified'))

    local lines = loadLog()
    lines[#lines + 1] = line

    local max = Config.Persistence.maxLogLines or 2000
    if #lines > max then
        table.remove(lines, 1)
    end

    writeFile(Config.Persistence.transactionLog, table.concat(lines, '\n') .. '\n')

    -- Optional hook for framework logging (see config.lua)
    if type(Config.Log.hook) == 'function' then
        pcall(Config.Log.hook, actor, target, account, amount, reason)
    end
end

-- ---------------------------------------------------------------------------
-- Account access
-- ---------------------------------------------------------------------------

local function newAccount(name)
    return {
        cash      = RoundMoney(Config.StartingBalance.cash or 0),
        bank      = RoundMoney(Config.StartingBalance.bank or 0),
        name      = name,
        firstSeen = timestamp(),
        lastSeen  = timestamp(),
        earned    = 0,
        spent     = 0,
        items     = {},
    }
end

--- Normalise an items table read from disk or built by another resource.
--- Only known keys, only positive whole counts.
--- @return table
function AccountStore.sanitizeItems(items)
    local out = {}

    if type(items) ~= 'table' then return out end

    for key, quantity in pairs(items) do
        quantity = tonumber(quantity)

        if type(key) == 'string' and key ~= '' and quantity and quantity > 0 then
            out[key] = math.floor(quantity)
        end
    end

    return out
end

--- The items table for an account (never nil).
--- @return table
function AccountStore.items(account)
    if type(account) ~= 'table' then return {} end

    if type(account.items) ~= 'table' then
        account.items = {}
    end

    return account.items
end

--- Get (or lazily create) an account by identifier.
--- @param identifier string
--- @param name string|nil
--- @return table
function AccountStore.get(identifier, name)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    AccountStore.load()

    local account = store.accounts[identifier]
    if not account then
        account = newAccount(name)
        store.accounts[identifier] = account
        store.dirty = true
    elseif name and account.name ~= name then
        account.name = name
        store.dirty = true
    end

    account.lastSeen = timestamp()
    return account
end

--- Does an account exist on disk? (used for offline staff actions)
function AccountStore.exists(identifier)
    AccountStore.load()
    return store.accounts[identifier] ~= nil
end

--- All loaded accounts, keyed by identifier (read-only use).
function AccountStore.all()
    AccountStore.load()
    return store.accounts
end

--- Health snapshot for /econstatus and any monitoring you bolt on.
--- @return table
function AccountStore.status()
    AccountStore.load()

    return {
        accounts  = AccountStore.count(),
        dirty     = store.dirty,
        lastSave  = store.lastSave,
        lastError = store.lastError,
        file      = Config.Persistence.file,
        backup    = Persist.backupPath(Config.Persistence.file),
        savable   = store.lastSave > 0,
    }
end

--- Count of stored accounts (for the server console command).
function AccountStore.count()
    AccountStore.load()
    local n = 0
    for _ in pairs(store.accounts) do n = n + 1 end
    return n
end

--- Wipe the in-memory store — used by the /economy reset console command.
function AccountStore.resetMemory()
    store.accounts = {}
    store.dirty = true
    AccountStore.save(true)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

CreateThread(function()
    Wait(0)
    AccountStore.load()

    local interval = math.max(5, Config.Persistence.saveInterval or 60) * 1000
    while true do
        Wait(interval)
        if store.dirty then
            AccountStore.save()
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    if store.dirty then
        AccountStore.save(true)
        print('^2[fk_economy] Accounts flushed to disk on shutdown.^0')
    end
end)

-- Flush when the server itself shuts down cleanly.
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    AccountStore.save(true)
end)
