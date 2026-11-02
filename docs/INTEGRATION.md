# Using `fk_economy` from the police mod

> Spawning is handled by the sibling resource `fk_spawn` — see
> [Spawning](#spawning-fk_spawn) at the end of this document.

`fk_economy` owns player balances. The police mod should **never** write to
`accounts.json` or keep its own copy of a balance — always go through the exports.
That keeps the HUD in sync, keeps the audit log complete, and means the server
validates everything.

## Golden rules

1. **Server-side only for writes.** A client should never be able to say "give me $500".
   Trigger a server event from your client code, validate it there, then call the export.
2. **Prices come from config.** Read `GetPrice(item)` or call `TryPurchase`, which
   looks the price up on the server. Never send a price from the NUI/client.
3. **Always pass a `reason`.** It ends up in the audit log next to the staff member's name.
4. **Check the return value.** `RemoveMoney` refuses to take a player below zero.

## Buying something

```lua
-- server: the player pressed "buy" in your shop
RegisterNetEvent('police:server:buyItem', function(itemKey)
    local src = source

    -- server-side allow-list of what this shop sells
    local shopSells = { bodycam = true, radio = true, handcuffs = true }
    if not shopSells[itemKey] then return end

    local ok, newBalance = exports.fk_economy:TryPurchase(src, itemKey, 1, 'cash')
    if not ok then
        TriggerClientEvent('police:client:notify', src, 'You cannot afford that.')
        return
    end

    -- hand the item to the player with whatever inventory system the mod uses
    GivePoliceItem(src, itemKey, 1)
    TriggerClientEvent('police:client:notify', src, ('Purchased %s (balance %s)')
        :format(itemKey, newBalance))
end)
```

## Paying out a shift

```lua
local PAYOUT = 2500

local ok, newBalance = exports.fk_economy:AddMoney(src, 'bank', PAYOUT, 'Shift payout')
if ok then
    TriggerClientEvent('police:client:notify', src,
        ('Shift paid: +$%d (bank)'):format(PAYOUT))
end
```

## Writing a fine

```lua
RegisterNetEvent('police:server:issueFine', function(targetSrc, amount, reason)
    local officer = source
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or amount > 50000 then return end

    -- try bank first, then cash, never below zero
    local ok = exports.fk_economy:RemoveMoney(targetSrc, 'bank', amount, reason)
    if not ok then
        ok = exports.fk_economy:RemoveMoney(targetSrc, 'cash', amount, reason)
    end

    TriggerClientEvent('police:client:notify', officer,
        ok and 'Fine paid.' or 'They cannot afford that fine.')
end)
```

## Reacting to money changes

```lua
-- e.g. update your own HUD badge, statistics, achievements
AddEventHandler('fk_economy:server:moneyChanged', function(src, account, delta, newBalance, reason)
    if account == 'bank' and delta > 0 then
        RecordIncome(src, delta, reason)
    end
end)
```

## Client side

The HUD updates itself whenever the server pushes a change, so you normally do not
need to do anything. If you changed a balance through some other path, pull a refresh:

```lua
exports.fk_economy:Refresh()
```

## Listening for the menu key

The menu is bound to `economyMenu` (F7 by default). If the police mod's own menu
should take precedence, either change `Config.Keys.menu` or call
`exports.fk_economy:OpenMenu()` from your own keybind instead.

## Checking staff from another resource

```lua
local isStaff = exports.fk_economy:IsStaff(src)   -- staff roster, identifier list, ACE, or vMenu admin

-- or the detailed answer, useful for UI/debug output:
local access = exports.fk_economy:GetStaffAccess(src)
-- { staff = true, source = 'roster', matched = 'license:110000112345678' }
-- source is 'roster' | 'identifier' | 'ace' | 'vmenu' | 'console' | nil
```

If your police mod needs its own staff-only actions (e.g. a "duty supervisor"
menu), reuse this so one permission model covers the whole mod.

## Data model

```jsonc
{
  "version": 1,
  "savedAt": "2026-01-01T00:00:00Z",
  "accounts": {
    "license:110000112345678": {
      "cash": 1750,
      "bank": 24500,
      "name": "J. Smith",
      "firstSeen": 1767225600,
      "lastSeen": 1767229200,
      "earned": 12000,
      "spent": 4500
    }
  }
}
```

`earned` / `spent` are lifetime totals that a stats or achievements system can use
later. `GetAccountStats(src)` returns them.

## Spawning (`fk_spawn`)

`fk_spawn` puts players in Michael's bedroom on join and owns the spawn point
list. The police mod should not teleport players itself — ask `fk_spawn`.

```lua
-- Where should this player spawn? (table with name, label, x, y, z, w)
local point = exports.fk_spawn:GetSpawnPoint()          -- default point
local named = exports.fk_spawn:GetSpawnPoint('michael_bedroom')
local all   = exports.fk_spawn:GetSpawnPoints()         -- array

-- React once a player is actually standing at their spawn point:
AddEventHandler('fk_spawn:server:playerSpawned', function(src, spawnName, x, y, z)
    if spawnName == 'michael_bedroom' then
        -- e.g. set duty state, hand out a starter item, open the department UI
    end
end)
```

Move a point from your own code (staff UI, mission setup, …):

```lua
exports.fk_spawn:SetSpawnPoint('michael_bedroom', { x = -812.56, y = 174.85, z = 76.74, w = 200.0 }, 'police_mod')
-- validates the coordinates, saves data/spawns.json and re-syncs every client
exports.fk_spawn:ResetSpawnPoint('michael_bedroom')     -- back to config.lua
```

Staff checks come from the economy automatically (`/ecostaff`); if you call
`IsSpawnStaff` yourself it uses the same answer, with the `fk_spawn.staff` ACE as
a fallback when `fk_economy` is not running.

The spawn sequence (fade, interior load, ground snap, camera) happens on the
client, triggered by the server's `fk_spawn:client:doSpawn` with a point table —
send it another point and the player gets the same polished transition.

## Michael's house (`fk_house`)

The mansion ships with interaction spots (wardrobe, kitchen, shower, bed, sofa). The
police mod can read them, move them, or add its own by adding entries to
`Config.Spots` in `fk_house/config.lua` and calling:

```lua
local spots = exports.fk_house:GetSpots()          -- array of { name, label, type, x, y, z, radius }
exports.fk_house:SetSpot('kitchen', { x = -800.0, y = 185.6, z = 71.85 }, 'police_mod')

-- Personal outfits live server-side, keyed by licence:
local outfits = exports.fk_house:GetPlayerOutfits('license:110000112345678')
-- { [1] = { comps = { { i = 3, d = 15, t = 0 }, ... }, props = { ... } } }
```

Player outfits are plain component/drawable/texture triples, so the police mod can reuse
them for uniforms later (`SetPedComponentVariation` per entry) instead of re-inventing
clothing storage.
