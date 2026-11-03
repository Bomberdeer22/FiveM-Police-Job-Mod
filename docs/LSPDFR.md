# LSPDFR → fk_police

LSPDFR (Los Santos Police Department First Response) runs on **RAGE Plugin Hook
and single-player GTA V**. RPH hooks the game process, which FiveM does not
allow, so LSPDFR cannot be installed on this server. What *can* be taken from it
is the design: its systems, its key layout and its callout/dispatch model. That
is what `fk_police` re-implements, natively, as a FiveM resource.

Sources used for the mapping: the LSPDFR feature list and controls
(`MysticIguana/LSPD-First-Response-LSPDFR`), the 0.4.9 documentation and the
Stop The Ped pages (`gtavillage.com`), the "Policer Advanced" / LSPatrol
descriptions (`lcpdfr.com`, `gta5mods.com`) and the Charges Reborn code list
(`lcpdfr.com`).

---

## 1. Feature map

| LSPDFR system | What it does there | Where it lives in `fk_police` |
| --- | --- | --- |
| **Duty / locker** | Report for duty at the station, put the uniform on, draw a loadout | `/duty`, and the **station marker** at Mission Row: `duty`, `locker`, `armoury`, `garage`, `computer`, `jail` (`Config.Stations[1].services`) |
| **Uniform & equipment** | LSPDFR outfits, duty belt, weapon loadout | `Config.Uniform` (component/drawable/texture) + `Config.Loadout` (pistol, stungun, nightstick, flashlight, armour). Leaving duty restores the outfit the player was wearing beforehand |
| **Police computer (MDT)** | Plate/name lookups, warrants, BOLOs, call history | MDT page (`html/index.html`, opened with **F9** or **E** in a police car): *People*, *Vehicles*, *Calls*, *Charges*, *Backup* tabs. Lookups go to the server (`fk_police:server:search`) — the page cannot invent a record |
| **Traffic stop** | Pull a car over behind it, driver stays put | `/stop` (or **F10**): finds the vehicle in front within `Config.Traffic.maxDistance`, keeps the driver stopped for `waitSeconds`, returns plate/model/owner, insurance, registration and warrants |
| **Citations** | Pick charges, print a citation, collect a fine | `/cite` → server sums `Config.Charges`, writes a citation record, takes the fine out of the driver's roleplay record and pays the officer |
| **Arrest & jail** | Cuff, book, transport to a cell, release after the sentence | `/arrest` (hands-up animation, handcuffs, wants cleared), sentence = sum of `jail` seconds capped at `Config.Jail.maxSeconds`, suspect held in `Config.Jail.cell` until released |
| **Dispatch callouts** | Random callouts with a code, a scene and suspects | Server-side dispatch thread: weighted pick from `Config.Callouts`, a scene 120–550 m away, 25 s after going on duty, then every 60–150 s. The client shows the callout card + blip and accepts with **Y** |
| **Callout pressure** | Callouts expire if ignored, one at a time | `Config.Dispatch.expireAfter` (420 s) and `maxActive = 1` — a single-player server has exactly one officer to send |
| **Backup** | Code 2 / Code 3, air, K9, SWAT, EMS, fire | `Config.Backup` + the MDT *Backup* tab and `/backup` (**G**): units spawn at `spawnDistance`, drive to the scene, and the unit count/delay/vehicle come from config |
| **Ranks & progression** | Not in base LSPDFR (mods add it) | `Config.Ranks` (XP thresholds + salary) and `Config.Pay` (per callout/citation/arrest plus a share of the fine). Money goes through `fk_economy:AddMoney`, so the job feeds the same bank account as everything else |
| **ANPR** | Automatic plate reading while patrolling | The HUD radar (**F5**) reads the plate of the car in front, and the server checks it (`fk_police:server:anpr`): stolen, BOLO, expired papers, owner warrants. Alerts go to chat and flash on the HUD |
| **Interaction menu** | Stop The Ped style menu on the stopped driver | `/frisk`, `/breath` and `/k9` on the stopped driver, plus the `/pd` menu (**M**) and the on-scene **E** prompt |
| **BOLOs / APB** | Plates and people dispatch wants flagged | MDT **BOLOs** tab (and `/bolo`): vehicle or person, a reason and an expiry. They show on stops, lookups and the ANPR |
| **Warrants** | Court warrants attached to a person | MDT person result → *Issue warrant*, or `/warrant add`. An arrest clears the warrant it was made for. Warrants expire |
| **Fines** | Citations are money the driver owes | Every citation creates a **ledger entry** with a due date. Collect (full/part) or waive in the MDT; the **court sweep** on duty suspends licences and puts out warrants for overdue fines |
| **Reports / paperwork** | Incident and use-of-force reports | `/report <title>` + the MDT **Reports** tab: kind, title, body, subjects, plate, charges, XP |
| **Impound / vehicle seizure** | Seized vehicles, release fees | `/impound` from a live stop (stolen cars cost more), the **Impound** tab, and release takes the fee |
| **Pursuits** | Chases, PIT, spike strips, air support | `/pursuit start` (auto code 3), `/pit`, `/spikes` (2-minute stinger), `/pursuit end <outcome>`; the log is in the **Shift** tab |
| **Booking / jail** | Transport, cells, release | `/jail` books the arrested suspect into the cell for the sentence, with a live custody timer on the HUD; `/jail release` lets them out |
| **Shifts** | Not in base LSPDFR | Duty starts a shift; the HUD and MDT show length, citations, arrests, callouts and pay; going off duty pays rank salary (prorated) + per-action bonuses and writes a shift record |
| **Bodycam** | Equipment | **L** toggles it; the HUD shows a REC chip |

---

## 2. Keys

LSPDFR binds a lot of keys; FiveM only lets a resource *map* keys to commands,
so the defaults are close to LSPDFR's, not identical (FiveM already owns some of
the originals — **B** is the radio wheel, **F4** opens nothing we can use).

| Key | `fk_police` | LSPDFR / Stop The Ped | Notes |
| --- | --- | --- | --- |
| **E** | Interact: station services, on-scene prompt, MDT inside a police car | Interact / arrest / computer | `Config.Keys.interact` / `computer` (38) |
| **M** | Police interaction menu (`/pd`) | Interaction menu (Stop The Ped uses **N**) | `Config.Keys.menu` (244) |
| **G** | Backup (`backup_code3`) | **B** = backup | **B** is the radio wheel in FiveM, so backup moved to **G** |
| **F5** | Radar / ANPR on-off | — | LSPDFR's radar is always on; here it is a toggle |
| **F6** / **F7** | Cite / arrest the current stop | — | The two ends of a stop |
| **F9** | Police computer (MDT) | **Q** | `Q` is a weapon/cover key in FiveM, so the computer sits on **F9** |
| **F10** | Traffic stop the vehicle in front | Left Shift | FiveM's default `Left Shift` is sprint; **F10** is free |
| **F11** | Go on/off duty (`/duty`) | Space+F9 (force duty) | `Space+F9` is not a mappable pair; **F11** is |
| **L** | Bodycam | Equipment toggle | Free key in FiveM |
| **X** | Force a callout (`/callout_force`) | **X** | Unchanged |
| **Y** | Accept the current callout | **Y** | Unchanged |

All of these are `RegisterKeyMapping` entries, so **Settings → Key bindings →
FiveM** lets the player rebind them. The commands work without the keys, which is
also how they are tested.

---

## 3. Behaviour differences (and why)

| LSPDFR | `fk_police` | Why |
| --- | --- | --- |
| Ped AI driven suspects, pursuits, evidence | Callouts are scene + charges + XP; no pursuit AI | RPH can drive the game's AI directly; a resource cannot. The MDT still hands you the charges so the stop still ends in a citation or an arrest |
| Other officers on patrol (LSPDFR 0.4 ambient units) | Backup units spawn on request | Ambient AI units would need a population manager; on a one-player server they mostly add traffic |
| Court / verdicts (mods) | Fines and sentences are applied immediately | No court system exists in this project yet; `Config.Charges` keeps `type` (infraction/misdemeanor/felony) so one can be layered on later |
| K9 / partner menus | K9 arrives as a backup unit | Partner AI needs a follow system; the backup unit is the LSPDFR-shaped version of it |
| Roadblocks, spike strips | Not implemented | Would need client-side prop placement with server validation; the backup delay/count config is the hook for it |

---

## 3b. The systems LSPDFR does not have

A server job needs a few things the single-player plugin never did, so they were added
rather than copied:

| System | Why |
| --- | --- |
| **Fine ledger with due dates** | A citation is only interesting if it comes back: overdue fines suspend a licence and put out a warrant |
| **Court fund** | Fines the citizen "settles" go somewhere — `records.department.balance`, shown in the MDT header |
| **Shifts** | LSPDFR has no economy; here the job pays a salary and per-action bonuses, so a duty session has a beginning, an end and a payslip |
| **BOLOs with expiry** | A dispatch board that cleans itself up |
| **Custody timer** | The sentence from the arrest is served somewhere, and you can see it on the HUD |
| **Persistence** | Records, fines, warrants, reports and shifts all survive a restart (`.bak` + snapshots) |

## 4. What stays server-authoritative

Everything that touches money, records or XP lives in `fk_police/server/main.lua`:

| Action | Server-side rule |
| --- | --- |
| `search` | Requires duty (unless `Config.Singleplayer`), rate-limited otherwise; reads the records store, never the client |
| `stop` | Plate must be readable, the stop must be started by the officer, expires after 300 s |
| `cite` / `arrest` | Need a live stop; charge ids are re-priced from `Config.Charges`; the fine/pay split comes from `Config.Pay` |
| `arrest` | Clears the warrant, writes the arrest record, creates the fine, remembers the arrest for `/jail` |
| `book` / `release` | Needs an arrest (or a live stop); the sentence is capped by `Config.Jail.maxSeconds`; the booking is written to the records |
| `fines` | Amounts and due dates are set server-side; a payment can never exceed what is owed; the court fund is server-side |
| `warrants` / `bolos` | Validated names/plates, deduplicated, expiring; only an on-duty officer can add or clear one |
| `reports` | Length limits and subject dedupe in `Mdt.validateReport`; unknown charge ids are dropped |
| `impound` | Needs a live stop, one open impound per plate; the release fee is taken through `fk_economy:RemoveMoney` and only if the bank can cover it |
| `pursuit` | Needs a stop or an accepted callout; the outcome must be one of `Config.Pursuit.outcomes` |
| `callout:resolve` | The callout must be `accepted` **and** the client must report coords within `Config.Dispatch.sceneRadius` (12 m) of the scene |
| money | Only through `exports['fk_economy']:AddMoney(source, 'bank', n, reason)` |
| records | `data/records.json`, written by `Persist` (`.bak` fallback, same as the other resources) |

The MDT page (`html/app.js`) is a thin client: it `POST`s to
`fk_police/search`, `fk_police/cite`, `fk_police/backup` … and renders whatever
comes back. It has no copy of the charges, the prices or the records.

---

## 5. Single-player adjustments

`Config.Singleplayer = true` (top of `config.lua`):

* rate limits are skipped — there is no one to flood the server but yourself;
* `maxActive = 1` callouts, owned by the only officer;
* the MDT opens without a "who is asking" handshake, because the answer is always you;
* the records, the officer table and the callouts all live in one process, so no
  cross-player locks or queues exist;
* the court sweep runs when *you* go on duty (there is no other officer to run it);
* one suspect can be in custody at a time, because there is one of you.

The rest of the job is unchanged: money and records are still validated on the
server, so a client cannot write itself a citation or a payday.
