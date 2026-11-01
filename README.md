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
| **Staff panel** | Staff can select any online player and **give** or **take** cash/bank from the menu. Take asks for confirmation. Works for themselves too. |
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

3. Give your staff the permission (recommended, ACE based):

   ```cfg
   add_ace group.admin fk_economy.staff allow
   add_principal identifier.license:YOUR_LICENSE_HERE group.admin
   ```

   For a quick local test, you can instead list identifiers in `config.lua`:

   ```lua
   Config.Staff.identifiers = { 'license:110000112345678' }
   ```

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

### Commands

Chat (staff only — validated server-side):

```
/addmoney <id> <cash|bank> <amount> [reason]
/takemoney <id> <cash|bank> <amount> [reason]
/setmoney <id> <cash|bank> <amount> [reason]
/mymoney
```

Console / rcon:

```
eco_save                      flush accounts.json now
eco_count                     how many accounts are stored
eco_give <id> <acct> <amount> [reason]
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
| `Config.Staff` | ACE permission, identifier allowlist, per-action cap, quick amounts, reasons, logging |
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
npm test        # 102 checks
```

* **55 server checks** — starting balances, overdraft refusal, invalid
  amounts/accounts/targets, purchase pricing, per-action caps, non-staff rejection,
  player-list permissions, chat commands, JSON persistence across a restart, audit
  log, balance ceiling.
* **33 UI checks** — money formatting, HUD rendering, menu/tab flow, drag mode,
  preset saving, staff selection, give/take confirmation, toasts, price list,
  delta pills, hidden-HUD behaviour.
* **14 preview checks** — the `preview/` harness boots and drives the same UI.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| **Black (or white) box behind the HUD or menu** | The page must render over the game with no background. `html, body` are forced transparent, and **`backdrop-filter` must not be used** — FiveM's CEF does not support it and paints a hard black rectangle behind the element. If you add custom CSS, avoid `backdrop-filter`, `filter` and `mix-blend-mode`. |
| **UI changes do not appear** | NUI is cached per resource: `restart fk_economy` (or `ensure fk_economy` again) after editing `html/*`. |
| **HUD position resets** | The layout is stored in client KVP on each player's PC, not on the server. Clearing FiveM's cache or switching PCs resets it to `Config.UI.default`. |
| **Balances do not save** | The `fk_economy/data` folder must be writable; resources served from an archive cannot be written to. Check the server console for `[fk_economy] Failed to write…`. |
| **Staff tab missing** | The player is missing the ACE permission. `add_ace group.admin fk_economy.staff allow` + `add_principal identifier.license:… group.admin`, then reconnect. |
| **`/mymoney` says no account** | The account is created on first join; if you added the resource while players were online, they reconnect (or the server restarts). |

## Roadmap

The main police mod will build on this resource:

1. Items/equipment purchases (using `Config.Items` prices + `TryPurchase`).
2. Shift payouts and fines (using `AddMoney` / `RemoveMoney` with reasons, so the
   audit log stays useful).
3. Vehicle purchases/impound fees.
4. Department budgets (a shared account on top of the same store).

See [`docs/INTEGRATION.md`](docs/INTEGRATION.md) for the patterns the main mod should use.
