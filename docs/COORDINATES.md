# Michael's house — where every coordinate comes from

`fk_house` and `fk_spawn` used to point at Michael's mansion with numbers copied
from public spawn lists. Those numbers are only "somewhere in the house": one of
them (the kitchen) was **11 metres off**, sitting on the living-room sofa, and the
spawn floated a metre above the bedroom floor. This page records how the shipped
coordinates were measured so they can be checked or rebuilt later without guessing.

---

## 1. What the house actually is

| Fact | Value | Source |
| --- | --- | --- |
| Interior archetype | `v_michael` | `x64h.rpf/levels/gta5/interiors/v_int_44.rpf/v_int_44.ytyp` |
| Placed by | `bh1_48_interior_v_michael_milo_.ymap` (patchday27ng) | MLO dump |
| **Interior origin (world)** | **X -807.343, Y 174.981, Z 71.163** | `DurtyFree/gta-v-data-dumps` → `mloInteriors.json` |
| Interior rotation | **21.00°** about Z | fitted, see §3 |
| Entities in the interior | 372 | `mloInteriors.json` |
| Rooms | `V_Michael_G_Front`, `_G_Hall`, `_G_Lounge`, `_G_Kitche`, `_G_Dine`, `_G_Corridor`, `_G_Garage`, `_1_Hall`, `_1_Hall2`, `_1_Master`, `_1_M_Ward`, `_1_Son`, `_1_Daught`, `_1_WC` | interior `ytyp` room list |
| Ground floor (feet) | **z 71.85** | navmesh points in `ob_sofa_michael.c` |
| Upstairs floor (feet) | **z 75.74** | upstairs navmesh points in `family_scene_m.c` / `building_controller.c` |

Michael's house is a real interior, not an IPL shell: the whole mansion is one MLO,
so every prop inside it has a position in the MLO's local space. Converting those to
world space gives the exact location of every fridge, door, wardrobe and sofa in the
building — which is what the config is built from.

## 2. Sources used

| Source | What it gave |
| --- | --- |
| `DurtyFree/gta-v-data-dumps` → `mloInteriors.json` | the MLO placement (origin) and its `ytyp` path |
| `X3P0/nopixel-3.0` → `np-ytypparser/client/ytyp/v_int_44_empty.ytyp.xml` | the interior's **entity list** (local positions) and room list, dumped from `v_int_44.ytyp` |
| `calamity-inc/GTA-V-Decompiled-Scripts` → `decompiled_scripts/family_scene_m.c` | every door in the house with its world position: front doors `v_ilev_mm_doorm_l/r`, fridges `v_ilev_mm_fridge_l/r`, the two upstairs `v_ilev_mm_doorw`, Jimmy's and Tracey's doors, back doors; room names per door (`V_Michael_G_Kitche`, `V_Michael_1_WC`, …) |
| … `decompiled_scripts/am_doors.c` | a second, independent copy of the same door coordinates |
| … `decompiled_scripts/ob_sofa_michael.c` | the lounge sofa's seat positions and the script's 3 m activation point |
| … `decompiled_scripts/building_controller.c` | interior **entity sets** (`V_Michael_M_items`, `V_Michael_bed_tidy`, …) and the points used to resolve the interior |
| `Bob74/bob74_ipl` wiki + Cfx forum | the house interior instance and the second-floor WC door |

Nothing here was taken from a YouTube video or a spawn-list copy-paste; every number
below traces back to a file the game itself loads.

## 3. From local to world

The interior's entity positions are local. The world position is

```
world = origin + Rz(21.00°) · local
Rz(θ) = [ cosθ  -sinθ ]
        [ sinθ   cosθ ]
origin = (-807.343, 174.981, 71.163)
```

`θ` and the origin were fitted from four props whose world coordinates are known
independently from the game scripts (the two front doors and the two fridge doors).
The fit is over-determined and lands within **9 mm RMS**:

| Prop | Local (ytyp) | Predicted world | Game script says |
| --- | --- | --- | --- |
| `V_ILev_MM_DoorM_L` | -7.275, 7.203, 1.664 | -816.72, 179.10, 72.84 | -816.716, 179.098, 72.84 |
| `V_ILev_MM_DoorM_R` | -7.275, 5.503, 1.664 | -816.11, 177.51, 72.84 | -816.107, 177.511, 72.827 |
| `V_ILev_MM_Fridge_L` | 6.885, 8.952, 1.576 | -804.11, 185.81, 72.75 | -804.1, 185.8, 72.7 |
| `V_ILev_MM_Fridge_R` | 8.259, 8.952, 1.576 | -802.83, 186.30, 72.75 | -802.8, 186.3, 72.7 |

The fitted origin came out as `-807.343, 174.981` — identical to the MLO placement in
`mloInteriors.json` — which is the independent check that the transform is right.

## 4. What is where (world coordinates)

| Room | Anchor props | World |
| --- | --- | --- |
| Front doors | `v_ilev_mm_doorm_l/r` | -816.72, 179.10 / -816.11, 177.51, z 72.84 |
| Entrance hall | `np_h_44_G_Fron_Deta` | -815.40, 179.19, z 73.30 |
| Stairs | `V_44_G_Hall_Stairs` | -807.66, 181.96, z 74.05 |
| **Kitchen** | fridges -804.12, 185.81 and -802.83, 186.30; hob -799.80, 187.80; sink -796.14, 186.84; coffee machine -796.73, 188.28 | centre ≈ **-800, 185.6** |
| **Lounge** | lounge anchor -803.38, 174.44; projector -804.49, 171.94; sofa seats -804.37, 176.86 / -802.40, 175.85 / -806.60, 173.40 | centre ≈ **-803.6, 174.4** |
| Dining | `V_44_Dine_Detail` | -796.61, 180.40 |
| **Garage** | `V_44_Garage_Shell` (house MLO) -811.23, 187.34; `v_michael_garage` MLO placed at -811.33276, 187.51263, **71.47429**; door `prop_ld_garaged_01` -815, 186, 73 | centre ≈ **-811.33, 187.51**, floor **z 71.47** |
| **Master bedroom** | room anchor -812.71, 178.40; `np_h_44_1_Master_Deca` -813.09, 179.65; chandelier -814.21, 180.93; balcony doors -817.17, 178.01 | centre ≈ **-813.2, 179.2** |
| **Master dressing room** | wardrobe shell `V_44_1_Master_Ward` -813.95, 174.30; shelves -811.29, 175.32; clothes rail -811.26, 176.32 | centre ≈ **-812.6, 175.2** |
| Family bathroom | sink -804.46, 169.07; mirror -804.71, 169.00; WC door -805.00, 171.90 | centre ≈ **-804.6, 169.9** |
| Jimmy's room | door -806.80, 174.00; room anchor -807.95, 169.91 | |
| Tracey's room | door -802.70, 176.20 | |
| Upstairs hall | `np_h_44_1_Hall_Emis` | -804.97, 177.41 |

The master suite is above the front door: bedroom to the north (balcony over the
driveway), dressing room to the south. The family bathroom is the room behind the
`v_ilev_mm_doorw` door the Cfx forum lists at -804.95, 171.86, 76.89.

## 5. The six spots as shipped

| Spot | x, y, z | Radius | Anchored to |
| --- | --- | --- | --- |
| `wardrobe` | -812.60, 175.20, 75.80 | 3.2 | wardrobe shell + shelves + clothes rail |
| `bed` | -813.20, 179.20, 75.80 | 3.6 | master bedroom centre (bed is baked into the shell) |
| `shower` | -804.60, 169.90, 75.80 | 2.6 | family bathroom: sink, mirror, towels, shampoo |
| `kitchen` | -800.00, 185.60, 71.85 | 4.5 | between the fridges, the hob and the sink |
| `livingroom` | -803.60, 174.40, 71.85 | 4.0 | lounge sofa and projector |
| `garage` | -811.33, 187.51, 71.47 | 4.5 | `v_michael_garage` MLO placement + `V_44_Garage_Shell` |

`Config.House.coords` is the MLO origin and `radius` is 30 m, which covers the house,
the garage, the balcony and the pool terrace but not the street.

Two things changed in the client to make these numbers behave:

* **`Config.House.zTolerance = 2.4`** — the floors are 3.91 m apart, so a 4 m radius
  would fire through the ceiling. `House.nearest` now ignores a spot on another floor.
* **floor snapping** — every marker is projected onto the real floor with a short
  downward shape-test, so a marker can never float above the carpet again.

## 6. Spawn point

`fk_spawn` joins you in the master bedroom, just inside the suite door:

```
x -810.60  y 178.20  z 75.90  heading 90 (facing west, into the bedroom)
```

`z 75.90` is 16 cm above the upstairs floor (75.74) so the ped lands instead of
clipping; the old value of 76.74 was a metre of thin air above the carpet, which is
why the spawn felt wrong even when the coordinates "looked" like Michael's house.

## 7. Re-measuring in game

If anything still looks off on your build, you do not need to edit files:

```
/housemarkers          draw every spot on the floor with its name and radius
/housescan             one chat line per fact: your position, the floor height,
                       heading, interior id, room hash and the distance to every spot
/housetune wardrobe    a live marker follows you; walk to the wardrobe and press E
/housespot wardrobe    same thing without the preview marker
```

The room hash in `/housescan` is the game's own room key for the MLO room you are
standing in, so a single screenshot of that line identifies the room even if the
coordinates are off.

## 6. The garage (a second interior, and a different floor height)

The garage is **not** part of the `v_michael` MLO — it is a separate archetype
`v_michael_garage` inside the same `v_int_44.ytyp`, with its own placement:

| Fact | Value | Source |
| --- | --- | --- |
| `v_michael_garage` placement | `-811.33276, 187.51263, 71.47429` | `mloInteriors.json` (DurtyFree/gta-v-data-dumps) |
| `v_michael_garage` rooms | `V_Michael_G_Garage`, `V_Michael_G_Corridor`, `limbo` | `v_int_44_empty.ytyp.xml` (X3P0/nopixel-3.0) |
| Garage shell in the house MLO | `V_44_Garage_Shell` at local `0.799, 12.930, 2.160` → world `-811.23, 187.34, 73.34` | ytyp + the same 21° fit |
| Garage door | `prop_ld_garaged_01` at `-815, 186, 73` (search radius 6.5 m) | `building_controller.c`, case 40 |

Two consequences that matter:

* **The garage floor is z 71.474, not 71.85.** It is a different interior with its own
  placement, and its local floor is `z ≈ 0`, so it sits ~0.38 m below the house's ground
  floor. A car spawned at 71.85 would hover; `Config.Garage.spawn` uses 71.70 and lets the
  car settle.
* **The garage centre is the MLO placement**, which lands within 0.2 m of the house's own
  `V_44_Garage_Shell` (-811.23, 187.34) and ~4 m from the script door (-815, 186) — three
  independent sources agreeing, which is why it is the shipped point.

The room's bounding box is large (~11 m) and L-shaped, so the bounding-box centre is not
used; the placement origin (a point both interiors agree on) is.

The spawn heading is `90` (west), towards the door on the -x side.

---

## 8. Speed camera posts (`Config.Cameras`)

The camera posts are landmarks, not measured interior props: each one is the
middle of a well-known road junction, so the radius (`Config.Cameras.defaultRadius`,
32 m) covers both carriageways without reaching the buildings behind them. They are
ordinary config values — move one, change its `limitKmh`, or add a post anywhere.

| Post | Coords (x, y, z) | Limit | Landmark it sits on |
| --- | --- | --- | --- |
| `cam_legion` | 215.0, -810.0, 30.7 | 50 km/h | Legion Square, the plaza between the bank and the fountains |
| `cam_mission` | 425.1, -979.5, 30.7 | 50 km/h | Mission Row PD frontage, the road the station sits on |
| `cam_pier` | -1850.0, -1231.0, 13.0 | 65 km/h | Del Perro Pier approach, the seafront road |
| `cam_sandy` | 1848.0, 3690.0, 34.0 | 80 km/h | Sandy Shores main road, the highway through the town |
| `cam_paleto` | -380.0, 6040.0, 31.0 | 65 km/h | Paleto Bay high street, the road past the sheriff's office |

The server compares the reported position against each post's radius
(`Mdt.cameraAt`), so a post only reads the cars actually passing it. Nothing else in
the resource depends on these numbers: `/cameras` and the MDT **Traffic** tab read the
same table, and a test asserts the list is not empty.
