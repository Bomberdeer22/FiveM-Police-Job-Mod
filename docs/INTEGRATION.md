# Using `fk_economy` from the police mod

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
local isStaff = exports.fk_economy:IsStaff(src)   -- economy ACE, identifier list, or vMenu admin

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
