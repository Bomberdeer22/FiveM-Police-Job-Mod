# FiveM Police Job Mod

A police job mod for FiveM (GTA V / GTA V Enhanced), in the spirit of LSPDFR Advanced.

**Current status:** the economic foundation — everything the main mod will later need to
move money around — the spawn manager, and Michael's house as a place you can actually
live in are built and tested.

```
fk_economy/          <- the economy resource (the money dependency)
fk_spawn/            <- spawn manager: players wake up in Michael's bedroom
fk_house/            <- Michael's mansion: wardrobe, kitchen, shower, bed, living room, garage
fk_boot/             <- starts heavy packs (vehicle/map) after boot, so txAdmin stops killing the server
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
/items                        what you own (equipment, licences)
/ecostaff …                   manage the staff list (see above)
/ecoaccess                    why do I (not) have staff access?
/econstatus                   (staff) version, accounts, last save, dropped requests
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

## fk_spawn

Spawn manager. Every player wakes up in **Michael De Santa's bedroom** in the
Rockford Hills mansion — fade to black, teleport, settle on the floor, short
establishing shot, fade back in — instead of dropping in at the default spawn.

### Install

1. Copy the `fk_spawn` folder into your `resources` directory.
2. Add to `server.cfg`, after the economy:

   ```cfg
   ensure fk_economy
   ensure fk_spawn
   ```

   `fk_spawn` uses `fk_economy`'s staff list (`/ecostaff`) for `/spawnset`. If you
   run it without the economy it falls back to the ACE `fk_spawn.staff`.
3. Join the server: the loading screen closes and you wake up in the bedroom.

### Commands

| Command | Who | What |
| --- | --- | --- |
| `/spawn` | everyone | respawn at the default point (Michael's bedroom) |
| `/spawn <name>` | everyone | respawn at a named point |
| `/spawnlist` | everyone | list every configured point and its coordinates |
| `/spawnset [name]` | staff | save **your current position and heading** as that spawn point |
| `spawn_set <name> <x> <y> <z> [heading]` | console / txAdmin | same, from the server console |
| `spawn_reset <name>` | console | forget the saved position, go back to `config.lua` |

Players can be told not to self-spawn with `Config.Spawn.allowPlayerCommand = false`
(staff can still use `/spawn`).

After the teleport the player is **invulnerable for `Config.Spawn.protection.seconds`
(5 s by default)**, so someone camping a spawn point cannot farm a player who is
still behind the fade. `/spawn` is also rate limited server-side (5 in a burst, then
one every 5 s), so a script cannot teleport-spam the server.

### The bedroom coordinates

```lua
coords = { x = -812.56, y = 174.85, z = 76.74, w = 200.0 }
```

That is the upstairs floor of the mansion (`z 76.74`; the ground floor is `72.8`),
which is the position used by the apartment/interior scripts that spawn players in
Michael's house. `w` is the heading the player faces on arrival.

**If it lands a metre away from where you want it** (MLO edits, custom mansion
replacements, or you'd rather spawn beside the bed): walk to the exact spot in game,
look in the direction you want, and run:

```
/spawnset
```

It writes `fk_spawn/data/spawns.json`, takes effect for everyone immediately, and
needs no restart. `/spawn_reset michael_bedroom` from the console undoes it.

### Configuration

| Key | Default | What it does |
| --- | --- | --- |
| `Config.Spawns` | Michael's bedroom | The spawn point list (`name`, `label`, `coords`, `interior`) |
| `Config.DefaultSpawn` | `'michael_bedroom'` | Point used on join and by `/spawn` with no argument |
| `Config.Interiors` | `michael_house` | Interior instance force-loaded before the teleport |
| `Config.Spawn.onJoin` | `true` | Play the spawn when a player joins |
| `Config.Spawn.allowPlayerCommand` | `true` | Let players use `/spawn` themselves |
| `Config.Spawn.joinDelay` | `1200` | ms to wait after the player is active, so the engine's own spawn cannot override ours |
| `Config.Spawn.pushDelay` | `3000` | ms after joining before the server starts pushing the spawn |
| `Config.Spawn.joinFallback` | `30000` | ms of pushing before the server gives up on that player |
| `Config.Spawn.shutdownLoadingScreen` | `true` | Close the loading screen on the first spawn |
| `Config.Spawn.freezeTime` | `2000` | Max ms frozen while the world streams in (released early once collision is ready) |
| `Config.Spawn.groundSnap` | `true` | Drop the ped onto the floor under the point (±`groundSnapRange`) |
| `Config.Spawn.cinematic` | `true` | Establishing shot that blends into gameplay (`cinematicTime`, `cinematicFov`) |
| `Config.Spawn.clearArea` | `true` | Clear vehicles/peds standing on the point first |
| `Config.Spawn.respawnOnDeath` | `false` | Send the player back to the point after dying (off: hospital/other scripts decide) |
| `Config.Staff.ace` | `'fk_spawn.staff'` | Fallback staff check when `fk_economy` is not running |
| `Config.Persistence.file` | `data/spawns.json` | Where in-game `/spawnset` positions are saved |

### How the spawn actually works

1. The server flags the player on `playerJoining` (so **restarting the resource never
   teleports someone who is already playing**).
2. On the client: fade out → controls off → leave any vehicle → clear the area →
   load the mansion interior → teleport → wait for collision → snap to the floor →
   establishing shot → fade in → controls on.
3. The teleport is re-asserted for a few seconds: on slow joins the engine's own
   spawn lands *after* ours and drags the player back to the default location, so
   the client keeps putting them back until the position sticks.
4. The server also **pushes** the spawn every 2.5 s (up to `joinFallback`) until
   the client confirms it landed — so the spawn never depends on the client
   asking at the right moment.
5. The client reports back where it ended up; `fk_spawn:server:playerSpawned` fires
   server-side so the police mod can hook it later.

### Data file

| File | Purpose |
| --- | --- |
| `fk_spawn/data/spawns.json` | Positions saved with `/spawnset` (git-ignored) |

---

## fk_house

Makes Michael De Santa's mansion a place you can actually use. Walk up to something,
press **E**, pick from the card that appears.

| Where | What you can do |
| --- | --- |
| **Wardrobe** | Three personal outfit slots, saved per licence. Save the look you're wearing, wear it again later, or **put your own clothes back on** — it captures your real ped components, so nothing is hard-coded and nothing breaks with custom clothing. |
| **Kitchen** | Make a sandwich (free, +20 health), brew a coffee, grab a donut or pour a water. Paid items are charged through `fk_economy` at the prices in its `Config.Items`, so the money side stays in one place. Eating plays the burger animation. |
| **Shower** | Clean the blood off and heal to full. "Wash your hands" is the quick version. |
| **Bed** | Sleep 8 hours or take a 2 hour nap: the screen fades, the clock moves forward and you wake up healed. |
| **Living room** | Relax on the sofa — slow health regen while you sit. |
| **Garage** | Park a car and it stays parked: the model is written to disk and the same car is spawned back in the garage on your next login. It is handled as your **personal vehicle**, so it is never despawned no matter how far from it you go. |

### Install

```cfg
ensure fk_economy
ensure fk_spawn
ensure fk_house
```

`fk_house` uses the economy for food prices and for the staff list (`/ecostaff`), and
works on its own if `fk_economy` is not running (food is free then).

### Moving the spots

The coordinates in `config.lua` are a starting point. To place a spot exactly where you
want it (in front of the wardrobe, at the fridge, by the bed):

1. Stand where the player should stand and look at the prop.
2. `/housetune wardrobe` (staff only — owners are staff via `/ecostaff claim`) drops a
   live marker that follows you; walk until it is exactly on the prop and press **E**.
   `/housespot wardrobe` does the same thing without the preview marker.
3. `/housemarkers` to draw a marker and the spot name on every spot, so you can see
   what is where. `/housespots` lists them all with the saved ones marked `*`.
4. `/housescan` prints your position, floor height, heading, interior id and room hash
   in chat — one paste of that is enough to re-measure a spot.

Everything saved this way goes to `fk_house/data/spots.json` and survives restarts.
Console equivalents: `house_spot <name> <x> <y> <z>` and `house_reset <name>`.
`/carreset` puts your garage car back on the garage floor, `/housestatus` (staff, also
works from the console) prints the version, spot count, stored outfits, stored cars and
any rate-limited requests.

| Spot name | Type | Default |
| --- | --- | --- |
| `wardrobe` | wardrobe | master dressing room, `-812.60, 175.20, 75.80` |
| `bed` | bed | master bedroom, `-813.20, 179.20, 75.80` |
| `shower` | shower | family bathroom, `-804.60, 169.90, 75.80` |
| `kitchen` | kitchen | kitchen at the back of the house, `-800.00, 185.60, 71.85` |
| `livingroom` | sofa | lounge, `-803.60, 174.40, 71.85` |
| `garage` | garage | Michael's garage (its own interior), `-811.33, 187.51, 71.47` |

Those numbers are measured from the game's interior data, not guessed — see
[`docs/COORDINATES.md`](docs/COORDINATES.md) for how each one was derived.

### Your car in the garage

Drive a car into Michael's garage and get out — that is all. The car is saved for your
licence (model, plate, position, heading) in `fk_house/data/garage.json`, and the next
time you join the server **the same model** is spawned back in the garage.

You can also use the card on the garage spot:

| Option | What it does |
| --- | --- |
| **Bring my car out** | Spawns the saved car in the garage (or tells you where it already is) |
| **Park a different car here** | Replaces the saved car with the one you are standing next to |
| **Forget this car** | Deletes the record *and* the spawned car |
| **Where is my car?** | Chat line with the model, plate and distance |

The car is **yours and it never despawns**: the entity is created by the server (not by a
client, which would be deleted as soon as it stopped streaming), marked as a mission
entity with a huge culling radius, and put in orphan mode so the server keeps it alive
with no player nearby. A watchdog re-creates it in the garage if it ever disappears, and
`/mycar` in chat tells you where it is. No F8 needed.

The **paint, window tint, wheels, mods and extras** are stored with it and put back when
the car is created again, so the car that returns is the one you left rather than a
showroom model. `/carreset` puts a car that ended up inside a wall back on the garage
floor (60 s cooldown, `Config.Garage.resetCooldown`).

The model is stored both as a name and as the model **hash read from the actual entity**,
so a car whose display name differs from its spawn name (e.g. `police3` → "POLICE")
still comes back as the same model, and a client cannot claim it is a different car.
`Config.Garage.blockedModels` (matched by hash) refuses cars like a tank.
`garage_list` in the server console prints everything that is stored.

Spawn hashes are compared as unsigned 32-bit numbers everywhere, so a record written by
an older build (where the hash could be negative) still returns the same car instead of
being refused.

The car is created by the server, and a freshly created entity is not registered on the
same tick — `DoesEntityExist` is still false for a moment. The spawn therefore **does not
treat that moment as a failure**: it marks the car as *pending*, keeps the request
open, and a background check retries every 100 ms for up to 5 s. Only if the entity never
appears is it cleaned up and you get a chat line (at most once every 15 s). While a car is
pending, further requests reuse it rather than creating a second one, so you never end up
with a stack of cars in the garage.

#### Surviving a restart

The car is written to disk when you park it, and read back **when the resource starts** —
so a server restart, `restart fk_house` or a full machine reboot cannot lose it:

* `fk_house/data/garage.json` is the current file.
* `fk_house/data/garage.bak.json` is the copy from just before the last write, so a write
  that was cut short still leaves the previous version.
* `fk_house/data/garage.1.json` … `.3.json` are rotating generations
  (`Config.Persistence.backups.slots`), written round-robin. If the file *and* the `.bak`
  are unreadable, startup restores the newest generation by its `savedAt` stamp and writes
  it back to `garage.json`, so the next restart is clean again.
* `onResourceStop` flushes the garage, so a car parked seconds before a restart is saved
  even if the process is stopped immediately afterwards.

On join, the server sends the stored car and the client says so in chat — no F8 needed:

```
Your adder is saved on the server (2026-11-02 14:03 UTC). Walk up to the garage to bring it out.
```

`/mycar` prints the same stamp. Walking up to the garage brings the car out; if you are
already near the house it is brought out automatically.

### Configuration

| Key | Default | What it does |
| --- | --- | --- |
| `Config.Spots` | 6 spots | What exists in the house: `name`, `label`, `type`, `coords`, `radius` |
| `Config.House` | interior origin, 30 m | Interactions only work inside this radius |
| `Config.House.zTolerance` | `2.4` | A spot is ignored when you are on another floor (the floors are 3.9 m apart) |
| `Config.Keys.interact` | `38` (E) | Interaction key |
| `Config.Wardrobe.slots` | `3` | Outfit slots per player |
| `Config.Food.chargeItems` | `true` | Charge kitchen items through the economy |
| `Config.Food.animation` | burger | Animation played while eating |
| `Config.Sleep.timeAdvanceEvent` | `nil` | Set to your time-sync event to advance server time instead of the local clock |
| `Config.Sleep.wakeMessage` | – | Chat line when you wake up |
| `Config.UI` | – | Card footer text and whether the `[E]` prompt shows |
| `Config.Garage.coords` / `radius` | `-811.33, 187.51, 71.47`, 6 m | Where a car must be for it to be saved, and where it is put back |
| `Config.Garage.spawn` | `-811.33, 187.51, 71.70`, heading 90 | Exact spawn point and heading inside the garage |
| `Config.Garage.cullDistance` | `4000.0` | Personal-vehicle culling radius — the car is never treated as abandoned |
| `Config.Garage.respawn` / `respawnDelay` | `true` / `5000` | Re-create the car in the garage if the entity ever disappears |
| `Config.Garage.blockedModels` | `{}` | Model names that may not be stored (matched by hash, so a fake name does not help) |
| `Config.Garage.door` | `prop_ld_garaged_01` | The garage door and how close you must be for it to open; `enabled = false` if another resource drives it |
| `Config.Persistence.backups` | `{ slots = 3 }` | How many rotating generations of `garage.json` to keep (used when the main file and its `.bak` are unreadable) |

Adding your own spot: copy an entry in `Config.Spots`, give it a `name`, a `type`
(`wardrobe`, `kitchen`, `shower`, `bed`, `sofa`, `garage`) and coordinates, then `/housespot <name>`
in game to fine-tune it.

### Data files

| File | Purpose |
| --- | --- |
| `fk_house/data/spots.json` | Positions saved with `/housespot` (git-ignored) |
| `fk_house/data/outfits.json` | Every player's saved outfits, keyed by `license:` (git-ignored) |
| `fk_house/data/garage.json` | Each player's saved car: model, hash, plate, position, heading (git-ignored) |
| `fk_house/data/garage.bak.json`, `garage.1.json` … `garage.3.json` | Previous copies of the above, used when the main file is unreadable (git-ignored) |

---

## fk_boot

A big vehicle or map pack (hundreds of `.yft`/`.ytd` files) can take minutes to load.
FiveM loads everything in `server.cfg` **before** the server answers on its HTTP port, and
txAdmin gives each resource a *Resource Starting Tolerance* — 1m30s by default — after
which it restarts the server:

```
[tx:FxMonitor] - Resource "fk_house" has been loading for 39s.
[tx:FxMonitor] Resource "fk_house" failed to start within the 1m30s time limit
```

**The resource named there is not the slow one.** txAdmin records the last resource it was
*told* about (`onResourceStarting`). A pack that blocks the server never gets to send its
own event, so the blame lands on the resource before it — in the log above `fk_house`
printed `1 saved vehicle(s) loaded` and `Started resource fk_house` in the same second,
while `Starting resource military` never finished. Removing the pack from the cfg is one
fix; `fk_boot` is the other, and it keeps the pack.

### Install

```cfg
# server.cfg
# ensure military      <- remove this line, fk_boot starts it instead
ensure fk_economy
ensure fk_spawn
ensure fk_house
ensure fk_boot         <- last line, so the delay starts after the rest of the boot
```

```lua
-- fk_boot/config.lua
Config.Deferred = {
    enabled = true,
    packs = { 'military' },   -- exact folder names, start order
    delay = 10000,            -- ms after fk_boot starts before the first pack
    gap = 2000,               -- ms between two packs
    skipIfStarted = true,     -- leave a pack alone if something already started it
}
```

The server boots, the HTTP endpoint comes up, players can connect — and then the pack is
started in the background without the boot clock running.

| What | Where |
| --- | --- |
| `boot_list` | Chat or console: every deferred pack and its current state |
| `boot_start <resource>` | Console / ACE-authorized: start one pack immediately |
| `exports.fk_boot:GetDeferredPacks()` | The configured list |
| `exports.fk_boot:GetDeferredState()` | `{ [name] = 'stopped' \| 'started' \| 'missing' }` |
| `exports.fk_boot:StartDeferredNow()` | Start them all now; returns the result per pack |

If you would rather keep `ensure military` in `server.cfg`, raise txAdmin's limit instead:
**Settings → FXServer → Show Advanced → Resource Starting Tolerance** (1.5 min → 10 min).

---

## Hardening (all three resources)

The three resources share the same small `shared/core.lua` (an identical copy in each,
because FiveM resources are separate Lua states). It gives every write and every net
event the same protection.

### Crash-safe data files

Every JSON write goes through `Persist.write`:

1. the previous file is copied to `<name>.bak.json` first,
2. then the new file is written,
3. a rotating snapshot (`accounts.1.json` … `accounts.3.json`, every
   `Config.Persistence.backups.everySeconds`) is kept as well.

On boot the loader reads the main file and **falls back to `.bak` automatically** if it is
truncated or corrupt — the classic result of a server dying mid-write. No database, no
extra directories: everything lives in the resource's existing `data/` folder.

### Rate-limited net events

Clients can fire net events as fast as they like, so every handler that does real work is
behind a token bucket (`Config.RateLimit`): a burst is allowed, a sustained flood is
dropped and counted.

| Resource | Events |
| --- | --- |
| `fk_economy` | `requestState`, `requestPlayers`, `staffAction`, purchases |
| `fk_house` | `requestSpots`, `setSpot`, `resetSpot`, `requestOutfits`, `saveOutfit`, `buy`, all four garage events |
| `fk_spawn` | `requestSpawns`, `requestSpawn`, `setSpawn`, `resetSpawn`, `isSpawnPending` |

Blocked requests are counted: `/econstatus` (staff) and `/housestatus` show the totals.

### `SetMoney` is gated

`AddMoney` / `RemoveMoney` can only move money that exists and are audited with the
calling resource in the log. `SetMoney` can *invent* money, so it now refuses any caller
that is not the console, `fk_economy` itself, a resource listed in
`Config.Limits.trustedResources`, or a resource holding `Config.Limits.setMoneyAce`:

```lua
Config.Limits.trustedResources = { 'fk_police' }
Config.Limits.setMoneyAce = 'fk_economy.admin'   -- IsPrincipalAceAllowed('resource.<name>', ace)
```

A refused call returns `false, 'not_permitted'` and prints a warning in the server console.

### Statebags

Every balance change is mirrored to a **replicated statebag**, so any resource or UI can
read money without listening to `fk_economy` events:

```lua
Player(src).state.money        -- { cash = 500, bank = 2500 }  (server)
LocalPlayer.state.money        -- same table, on the client
Player(src).state.moneyLoaded  -- true once the account exists
Entity(veh).state.garageOwner  -- whose personal car this is
Entity(veh).state.garagePlate  -- its plate
Entity(veh).state.personalVehicle
```

`AddStateBagChangeHandler('money', ...)` is the recommended way for the police mod to
react to a balance change.

### vPlayer

`server/player.lua` wraps an account in a `vPlayer` object, and every balance or item
change goes through it (`:Apply`, `:SetBalance`, `:AddItem`, `:RemoveItem`,
`:CanAfford`, `:Snapshot`). One choke point means one place where limits, totals and the
audit log are applied.

### Owned items

Buying something from `Config.Items` now also stores it on the account, so equipment
survives a reconnect and can be confiscated:

```lua
exports.fk_economy:GetItems(src)                  -- { bodycam = 1, radio = 2 }
exports.fk_economy:GetItemCount(src, 'bodycam')
exports.fk_economy:HasItem(src, 'bodycam', 2)
exports.fk_economy:AddItem(src, 'bodycam', 1, 'Evidence room')
exports.fk_economy:RemoveItem(src, 'bodycam', 1, 'Confiscated')
```

Consumables, services and vehicles are *not* stored (they are used at the till);
`Config.ItemsOwned.skipCategories` decides which categories count, and
`Config.ItemsOwned.maxStack` caps the count. Staff can see a player's equipment with
`/items`.

### CI

`.github/workflows/tests.yml` runs `npm run check` on every push and pull request: it
compiles all 25 Lua files with fengari (`tools/lint-lua.js`), then runs the five test
suites (410 checks) against a real Lua VM and jsdom.

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
npm run check   # lint every Lua file + all 410 checks
```

* **123 economy checks** — starting balances, overdraft refusal, invalid
  amounts/accounts/targets, purchase pricing, per-action caps, non-staff rejection,
  player-list permissions, chat/console commands, **staff roster** (claim, add,
  remove, last-member protection, persistence across a restart, JSON shape),
  optional vMenu detection (admin vs. moderator vs. unrelated node), a missing
  `server/staff.lua` degrading gracefully instead of killing the HUD, audit log,
  balance ceiling, **items you own** (equipment stored, consumables and services
  not, stack limit, add/remove/confiscate), **statebags** (`Player(src).state.money`
  and the `playerLoaded` event), the **SetMoney gate** (untrusted resource refused,
  console and trusted resources allowed, ACE path), **rate limiting** (a staff flood
  is cut off and refills), and **crash safety** (`.bak` fallback of a corrupted
  `accounts.json`, rotating snapshots).
* **33 UI checks** — money formatting, HUD rendering, menu/tab flow, drag mode,
  preset saving, staff selection, give/take confirmation, toasts, price list,
  delta pills, hidden-HUD behaviour.
* **33 fk_boot checks** — the deferred pack list, nothing starting before the delay,
  packs starting in order and once only, a pack that is already running or still starting
  being left alone, a misspelled or uninstalled pack being reported instead of started, a
  refused `StartResource`, the three exports, and both console commands.
* **14 preview checks** — the `preview/` harness boots and drives the same UI.
* **152 house checks** — the six spots and their types, coordinates checked against
  the game's own interior data (each spot must land in its room and on its floor),
  floor-aware nearest-spot lookup, 3D distance, spot validation, `/housespot` / `house_spot` / `house_reset`, staff gating,
  `spots.json` persistence across a restart, outfit validation and per-licence storage,
  kitchen purchases through the economy (success, refusal, unknown item, no economy),
  unsigned model-hash handling (a negative stored hash still spawns the same car), the
  slow-registration regression (a car that is not there yet is not "failed", is announced
  when it appears, and is never created twice), restart safety (the car is still there
  from the main file, from a `.bak`, from a single rotating snapshot, and from the newest
  of several; a corrupt file plus corrupt backup still recovers; `onResourceStop` flushes
  the garage and ignores another resource stopping), and the NUI card in jsdom (rows,
  hints, show/hide, Lua messages).
* **55 spawn checks** — the bedroom point and its interior, name lookup (case/space
  insensitive), coordinate parsing from strings and tables, bounds/NaN rejection,
  save/load of `spawns.json`, `spawn_set` / `spawn_reset` / `spawnlist`, the staff
  gate on `/spawnset`, permission on `/spawn`, the join handshake (a flagged
  player must spawn, an existing player must not), the server-side push loop that
  keeps offering the spawn until the client confirms, the startup banner, the
  `playerSpawned` event for other resources, client re-sync, the spawn **rate
  limit**, the `spawns.json` backup, and the anti-spawnkill protection settings.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| **`Resource "fk_house" failed to start within the 1m30s time limit` (txAdmin restarts the server)** | txAdmin names the last resource it was told about, not the slow one: a heavy pack that blocks the boot never reports itself. Look at the last `Starting resource …` line in the console — that is the one. Either raise **Settings → FXServer → Show Advanced → Resource Starting Tolerance**, or move the pack to [`fk_boot`](#fk_boot) and remove it from `server.cfg`. The `fk_house` line right before it (`N saved vehicle(s) loaded`) proves fk_house started in the same second it was asked to. |
| **Black (or white) box behind the HUD or menu** | The page must render over the game with no background. `html, body` are forced transparent, and **`backdrop-filter` must not be used** — FiveM's CEF does not support it and paints a hard black rectangle behind the element. If you add custom CSS, avoid `backdrop-filter`, `filter` and `mix-blend-mode`. |
| **Console: `attempt to call a nil value (global 'StaffCount')` / `'StaffRosterIsEmpty'` / `'IsStaff'`** | Your deployed copy is out of date: `server/staff.lua` is not being loaded. Re-copy the **whole** `fk_economy` folder (the file *and* `fxmanifest.lua`, which must list `server/staff.lua` before `server/main.lua`) and `restart fk_economy`. From v0.2.0 the resource prints a red `server/staff.lua was not loaded!` banner instead of crashing. |
| **HUD never appears** | It stays hidden until the server sends balances. If the server threw an error in `PushState` the client gets nothing — check the console for the banner above. The client re-requests state every 5s for 40s, then gives up until the resource restarts. |
| **UI changes do not appear** | NUI is cached per resource: `restart fk_economy` (or `ensure fk_economy` again) after editing `html/*`. |
| **HUD position resets** | The layout is stored in client KVP on each player's PC, not on the server. Clearing FiveM's cache or switching PCs resets it to `Config.UI.default`. |
| **Balances do not save** | The `fk_economy/data` folder must be writable; resources served from an archive cannot be written to. Check the server console for `[fk_economy] Failed to write…`. |
| **Staff tab missing** | Run `/ecoaccess` in game (or `eco_check &lt;id&gt;` in the console) — it prints whether access was granted and by what. Add the player with `/ecostaff add <id>` (or `eco_staff add <id>` in the console). |
| **Player does not wake up in the bedroom on join** | Everything needed is visible **in chat**: on a successful join you get `Waking you up in Michael's bedroom…`; `/spawnstatus` prints the resource version, the points it received, the pending flag and your coordinates. `/spawn` forces a spawn (if that works, the spawn logic is fine and only the join trigger is at fault). On the **server** console look for `[fk_spawn] Ready (v…)`, `Player N (name) spawned at michael_bedroom`, and `player N never confirmed the join spawn` (means the client never acknowledged — check that the player's client has the same `fk_spawn` version). No `Ready` line at all = the resource is not running: `ensure fk_spawn` after `ensure fk_economy`. |
| **No prompt inside the house** | Run `/housedebug` first — it prints, in chat: how many spots the client received, whether you are inside the house radius, which spots are near you (and within what radius), whether the UI page answered, and whether a menu is open. Then `/housemarkers` (staff) draws a marker **on the floor** at every spot, and `/housespot <name>` saves your position. If `/housedebug` says `spots=0`, the client never got the list — check the server console. |
| **Chat: the car "could not be spawned" — but the car is right there, and a new one keeps appearing** | Fixed in v0.3.1: a server-created vehicle is not registered on the tick it is made, so the old check called that a failure and the next request made another car. Update `fk_house` and `restart fk_house`. If it still happens, the server console prints `[fk_house] gave up spawning <model>` with the reason. |
| **"My car was gone after a restart"** | It should not be: the record is read from `fk_house/data/garage.json` at resource start, with `garage.bak.json` and `garage.1..3.json` as fallbacks. Check the server console at startup — it prints `N saved vehicle(s) loaded from data/garage.json`, or a yellow line naming the backup it restored from. If it says `0`, the file is empty or `data/` is not writable (see the `Could not write` row below). `/mycar` shows the exact save time. |
| **My car did not come back** | `/mycar` in chat prints what is stored and where the car is. If the record is empty, the car was never parked inside `Config.Garage.coords`/`radius` — drive it in, get out, and look for the "Parked your …" line. The console `garage_list` command lists every stored car. | Every default coordinate was measured from the interior's own MLO data — [`docs/COORDINATES.md`](docs/COORDINATES.md) lists the props each one is anchored to and the maths behind it. If your build differs, `/housescan` prints your position, floor height, interior id and room hash in chat, and `/housetune <spot>` saves a spot without editing files. |
| **`Could not write data/…json`** | `SaveResourceFile` cannot create folders: the resource needs a `data` directory next to `fxmanifest.lua`. Every resource ships one with a `.gitkeep`; if you copied files by hand, create `fk_house/data` (and `fk_spawn/data`) yourself and restart. |
| **Nothing happens when I press E** | Check the spot's `type` in `config.lua` — only `wardrobe`, `kitchen`, `shower`, `bed` and `sofa` have actions. The card should list at least one option; if the spot has no options you get "Nothing to do here yet." |
| **Food is not charged** | The economy is not running (food is free) or `Config.Food.chargeItems = false`. Prices come from `fk_economy`'s `Config.Items`, so edit them there. |
| **An outfit looks wrong** | Outfits are captured from your own ped, so they always match what you were wearing. If a slot was saved while a clothing script was mid-change, save it again. |
| **Spawn is a metre off / in the hallway** | Stand where you want it, face the direction, run `/spawnset` (staff). It is saved to `fk_spawn/data/spawns.json` and applies instantly. `/spawn_reset michael_bedroom` in the console restores `config.lua`. |
| **Player falls through the floor or spawns floating** | The mansion interior had not streamed in yet. The resource force-loads the interior and waits for collision; if it still happens, raise `Config.Spawn.freezeTime` and check the `z` value (`76.74` is the upstairs floor). Keep `groundSnap` on. |
| **Everyone got teleported home when I restarted the resource** | They should not — spawns only run for players flagged on join. If it happens, your `playerJoining` handler was reloaded while people were online; reconnect the affected players. |
| **`/spawnset` says "you need staff access"** | Add yourself to the economy staff list first: `/ecostaff claim` (fresh install) or `/ecostaff add <id>`. Without `fk_economy`, use `add_ace group.admin fk_spawn.staff allow`. |
| **Player spawns in a car / with a car in the room** | `/spawn` pulls the player out of the vehicle before teleporting; if a vehicle follows them, check `Config.Spawn.clearArea` is `true`. |
| **`/mymoney` says no account** | The account is created on first join; if you added the resource while players were online, they reconnect (or the server restarts). |

## Roadmap

The main police mod will build on this resource:

1. Items/equipment purchases (using `Config.Items` prices + `TryPurchase`).
2. Shift payouts and fines (using `AddMoney` / `RemoveMoney` with reasons, so the
   audit log stays useful).
3. Vehicle purchases/impound fees.
4. Department budgets (a shared account on top of the same store).

See [`docs/INTEGRATION.md`](docs/INTEGRATION.md) for the patterns the main mod should use.
