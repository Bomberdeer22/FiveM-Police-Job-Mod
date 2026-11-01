# FiveM Police Job Mod

A police job mod for FiveM (GTA V / GTA V Enhanced), in the spirit of LSPDFR Advanced.

**Current status:** the economic foundation — everything the main mod will later need to
move money around — is built and tested.

```
fk_economy/          <- the economy resource (this is the dependency)
preview/             <- dev-only browser preview of the UI (not shipped to the server)
```

---

## fk_economy

A standalone cash/bank economy with an on-screen HUD, an in-game HUD customiser and
staff money tools. No framework, no database, no other resources required.

### What it does

| Feature | Detail |
| --- | --- |
| **Money HUD** | Glassy card showing **Cash** and **Bank**, animated count-up/down, green/red flash and `+$500` float text on every change. |
| **HUD customiser** | Press **F7** → *HUD Layout*: hit **Start dragging** and the menu slides away so you can drop the HUD anywhere with the mouse. Also corner presets, arrow-key nudging, scale, opacity and compact mode. Saved per player on their own PC. |
| **Staff panel** | Staff can select any online player and **give** or **take** cash/bank from the menu. Take asks for confirmation. Works for themselves too. Staff come from a simple in-game list (`/ecostaff`) — no ACE, vMenu or Discord setup required. |
| **Price list** | Every item price lives in `config.lua` and is browsable in the menu's *Price List* tab. The main police mod will read these prices when buying items/vehicles/services. |
| **API for the main mod** | Server exports (`AddMoney`, `RemoveMoney`, `TryPurchase`, `GetPrice`, …) so the police mod never has to touch balances directly. |
| **Persistence** | Balances are stored in `fk_economy/data/accounts.json`, keyed by `license:` identifier, auto-saved and flushed on disconnect/shutdown. |
| **Audit log** | Every staff adjustment and purchase is written to `fk_economy/data/transactions.log`. |
| **Security** | The server is authoritative. The client only ever *asks*; all amounts, prices and permissions are re-validated server-side. |

### Requirements

* FXServer (works on regular and **Enhanced** builds — no game-version-specific natives are used).
* Nothing else. No ESX/QBCore, no oxmysql, no dependencies.

### Install

1. Copy the `fk_economy` folder into your server's `resources` directory
   (e.g. `resources/[police]/fk_economy`).
2. Add to `server.cfg`:

   ```cfg
   ensure fk_economy
   ```

3. Make yourself staff — **no server.cfg edit, no vMenu permissions, no Discord**:

   Join the server and type in chat:

   ```
   /ecostaff claim
   ```

   That's it. `claim` only works while the staff list is empty (a fresh install), and it
   adds *you* as the owner. Everyone else is added by staff:

   ```
   /ecostaff add 3          add the player with server id 3
   /ecostaff list           show the staff list
   /ecostaff remove 3       remove them again
   ```

   The list lives in `fk_economy/data/staff.json`, so it survives restarts. From the
   server console (or txAdmin) you can always run:

   ```
   eco_staff online         who is online, with their ids
   eco_staff add 3          add player id 3
   eco_staff list
   eco_staff remove 3
   ```

   Optional extras (all off by default): a `Config.Staff.identifiers` allowlist,
   the `fk_economy.staff` ACE, and vMenu admin detection — see
   [Staff detection](#staff-detection).

4. Start the server. First time a player connects they get the starting balances
   from `config.lua` (`$750` cash / `$2,500` bank by default).

> The `data/` folder must be writable by the server process. If you run resources
> from an archive (`.rpf`/`.zip`) or a read-only mount, point
> `Config.Persistence.file` at a writable path or move the resource out of the archive.

### Key bind

| Key | Action |
| --- | --- |
| **F7** | Open / close the economy menu (changeable in `Config.Keys.menu`) |

Players can rebind it in *Settings → Key Bindings → FiveM → "Open Economy Menu / HUD Customiser"*.

### Staff detection

A player counts as staff if **any** of these match, checked in this order:

| # | Source | How |
| --- | --- | --- |
| 1 | **Staff list** *(recommended)* | `/ecostaff claim` on a fresh install, then `/ecostaff add <id>`. Stored in `data/staff.json`. |
| 2 | Identifier allowlist *(optional)* | `Config.Staff.identifiers = { 'license:…' }` in `config.lua` |
| 3 | ACE permission *(optional)* | `add_ace group.admin fk_economy.staff allow` |
| 4 | vMenu admin *(optional, off by default)* | `Config.Staff.vmenu.enabled = true` |

Manage the staff list:

```
/ecostaff claim            become staff while the list is empty (one time only)
/ecostaff add <id>         add an online player (staff only)
/ecostaff remove <id>      remove a player (staff only, never the last one)
/ecostaff list             show names, roles and identifiers (staff only)
/ecostaff                  show your own access + command help
/ecoaccess                 why do I (not) have staff access?
```

The console equivalents are `eco_staff add <id>`, `eco_staff remove <id>`,
`eco_staff list` and `eco_staff online` (lists online players with their ids, handy for
picking the right one).

Config knobs in `config.lua`:

```lua
Config.Staff.file      = 'data/staff.json' -- where the list is stored
Config.Staff.allowClaim = true             -- false = console-only setup
Config.Staff.identifiers = {}              -- optional hard-coded identifiers
Config.Staff.ace        = 'fk_economy.staff' -- optional ACE fallback
Config.Staff.vmenu.enabled = false         -- optional vMenu admin detection
```

Notes:

* The last staff member cannot be removed — otherwise `/ecostaff claim` would be open
  to anyone again.
* Set `Config.Staff.allowClaim = false` if you would rather add the first staff member
  from the console (`eco_staff add <id>`) and never allow claiming.
* Deleting `data/staff.json` resets the list (and re-opens `claim` while it is empty).
* If you *do* want vMenu admins to get staff automatically, set
  `Config.Staff.vmenu.enabled = true`; the nodes that count are
  `vMenu.Everything`, `vMenu.OnlinePlayers.All`, `vMenu.OnlinePlayers.PermBan`,
  `vMenu.OnlinePlayers.Unban`, `vMenu.OnlinePlayers.Identifiers` and `vMenu.Staff`
  (moderators via `includeModerators = true`).

### Commands

Chat (staff only — validated server-side):

```
/addmoney <id> <cash|bank> <amount> [reason]
/takemoney <id> <cash|bank> <amount> [reason]
/setmoney <id> <cash|bank> <amount> [reason]
/mymoney
/ecostaff …                   manage the staff list (see above)
/ecoaccess                    why do I (not) have staff access?
```

Console / rcon:

```
eco_staff add|remove|list|online    manage the staff list
eco_save                            flush accounts.json now
eco_count                           how many accounts are stored
eco_give <id> <acct> <amount> [reason]
eco_check <id>                      staff access for a player, and where it came from
```

### Configuration

Everything lives in [`fk_economy/config.lua`](fk_economy/config.lua):

| Section | What it controls |
| --- | --- |
| `Config.Currency` | Symbol, decimals, symbol position, locale formatting |
| `Config.StartingBalance` | First-time cash/bank balances |
| `Config.Accounts` | Which accounts exist (`cash`, `bank`) |
| `Config.UI` | Default HUD position/scale/opacity, accent colour, animations, edge snapping |
| `Config.Keys` | Menu key |
| `Config.Staff` | **Staff list file + first-run claim**, optional identifier allowlist / ACE / vMenu detection, per-action cap, quick amounts, reasons, logging |
| `Config.Limits` | Max balance, minimum amount, whole numbers |
| `Config.Persistence` | Data file paths, save interval, log size |
| `Config.Items` | **Item price list** — the main mod reads this |

Adding an item is a single entry:

```lua
Config.Items['ticket_book'] = {
    label = 'Ticket Book', price = 90, sell = 40, category = 'Equipment',
    description = 'Used to write citations.',
}
```

It immediately appears in the *Price List* tab and is available to
`GetPrice('ticket_book')` / `TryPurchase(src, 'ticket_book')`.

### Server API (what the main mod uses)

```lua
-- reads
local money = exports.fk_economy:GetMoney(src)              -- { cash = 1750, bank = 2500 }
local cash  = exports.fk_economy:GetBalance(src, 'cash')
local price = exports.fk_economy:GetPrice('bodycam')        -- 250
local all   = exports.fk_economy:GetPrices()                -- whole Config.Items table
local canPay = exports.fk_economy:CanAfford(src, 'bodycam', 2, 'cash')

-- writes (ok, newBalanceOrError)
local ok, newBal, err = exports.fk_economy:AddMoney(src, 'cash', 500, 'Shift payout')
local ok, newBal, err = exports.fk_economy:RemoveMoney(src, 'bank', 200, 'Speeding fine')
local ok, newBal, err = exports.fk_economy:SetMoney(src, 'cash', 1000, 'Correction')

-- purchases use the price from config, never a client-supplied price
local ok, newBal, err = exports.fk_economy:TryPurchase(src, 'bodycam', 1, 'cash')
```

Return values:

| Call | Returns |
| --- | --- |
| `AddMoney` / `RemoveMoney` / `SetMoney` | `true, newBalance` or `false, errorCode` (`invalid_amount`, `invalid_account`, `no_target`, `insufficient_funds`) |
| `TryPurchase` | `true, newBalance` or `false, errorCode` (`unknown_item`, `not_for_sale`, `insufficient_funds`, …) |
| `GetMoney` | `{ cash = …, bank = … }` or `nil` |

`target` accepts a server id (`number`) **or** a stored identifier string
(`'license:…'`) for offline adjustments.

Client side:

```lua
exports.fk_economy:Refresh()     -- re-pull balances (after granting money elsewhere)
exports.fk_economy:OpenMenu()
exports.fk_economy:CloseMenu()
```

Server events (add a handler in your own resource):

```lua
AddEventHandler('fk_economy:server:moneyChanged', function(src, account, delta, newBalance, reason)
    -- e.g. log to your own system
end)
```

### Data files

| File | Purpose |
| --- | --- |
| `fk_economy/data/accounts.json` | Balances keyed by identifier (`cash`, `bank`, `earned`, `spent`, `firstSeen`, `lastSeen`) |
| `fk_economy/data/staff.json` | Staff roster (`name`, `role`, `identifier`, `addedBy`, `addedAt`) |
| `fk_economy/data/transactions.log` | One line per staff adjustment / purchase (trimmed to `Config.Persistence.maxLogLines`) |

Both are git-ignored. Back up `accounts.json` like any other player data.

---

## Preview the UI in a browser (dev only)

`preview/` runs the real NUI page against a mock bridge, so you can look at the HUD,
drag it around, and test the staff panel without booting a server:

```bash
npm run preview          # python3 -m http.server 8000
# then open http://localhost:8000/preview/
```

The demo toolbar at the top substitutes for the F7 key and fakes money changes.
The dark backdrop behind the UI in that page is only a stand-in for the game —
the real resource page is fully transparent, so nothing is drawn behind the HUD
in-game. `preview/` is not referenced by `fxmanifest.lua` and is safe to leave out
of a deploy.

## Testing

The resource is executed for real in CI-friendly form: the Lua runs inside a Lua VM
with mocked FiveM natives, and the NUI page runs in jsdom.

```bash
npm install
npm test        # 137 checks
```

* **90 server checks** — starting balances, overdraft refusal, invalid
  amounts/accounts/targets, purchase pricing, per-action caps, non-staff rejection,
  player-list permissions, chat/console commands, **staff roster** (claim, add,
  remove, last-member protection, persistence across a restart, JSON shape),
  optional vMenu detection (admin vs. moderator vs. unrelated node), a missing
  `server/staff.lua` degrading gracefully instead of killing the HUD, audit log,
  balance ceiling.
* **33 UI checks** — money formatting, HUD rendering, menu/tab flow, drag mode,
  preset saving, staff selection, give/take confirmation, toasts, price list,
  delta pills, hidden-HUD behaviour.
* **14 preview checks** — the `preview/` harness boots and drives the same UI.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| **Black (or white) box behind the HUD or menu** | The page must render over the game with no background. `html, body` are forced transparent, and **`backdrop-filter` must not be used** — FiveM's CEF does not support it and paints a hard black rectangle behind the element. If you add custom CSS, avoid `backdrop-filter`, `filter` and `mix-blend-mode`. |
| **Console: `attempt to call a nil value (global 'StaffCount')` / `'StaffRosterIsEmpty'` / `'IsStaff'`** | Your deployed copy is out of date: `server/staff.lua` is not being loaded. Re-copy the **whole** `fk_economy` folder (the file *and* `fxmanifest.lua`, which must list `server/staff.lua` before `server/main.lua`) and `restart fk_economy`. From v0.2.0 the resource prints a red `server/staff.lua was not loaded!` banner instead of crashing. |
| **HUD never appears** | It stays hidden until the server sends balances. If the server threw an error in `PushState` the client gets nothing — check the console for the banner above. The client re-requests state every 5s for 40s, then gives up until the resource restarts. |
| **UI changes do not appear** | NUI is cached per resource: `restart fk_economy` (or `ensure fk_economy` again) after editing `html/*`. |
| **HUD position resets** | The layout is stored in client KVP on each player's PC, not on the server. Clearing FiveM's cache or switching PCs resets it to `Config.UI.default`. |
| **Balances do not save** | The `fk_economy/data` folder must be writable; resources served from an archive cannot be written to. Check the server console for `[fk_economy] Failed to write…`. |
| **Staff tab missing** | Run `/ecoaccess` in game (or `eco_check &lt;id&gt;` in the console) — it prints whether access was granted and by what. Add the player with `/ecostaff add <id>` (or `eco_staff add <id>` in the console). |
| **`/mymoney` says no account** | The account is created on first join; if you added the resource while players were online, they reconnect (or the server restarts). |

## Roadmap

The main police mod will build on this resource:

1. Items/equipment purchases (using `Config.Items` prices + `TryPurchase`).
2. Shift payouts and fines (using `AddMoney` / `RemoveMoney` with reasons, so the
   audit log stays useful).
3. Vehicle purchases/impound fees.
4. Department budgets (a shared account on top of the same store).

See [`docs/INTEGRATION.md`](docs/INTEGRATION.md) for the patterns the main mod should use.
