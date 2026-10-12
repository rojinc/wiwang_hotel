# wiwang_apartments

qb-apartments style apartments for the **Wiwang Hotel MLO**, using the hotel's **real rooms**:
20 floors x 19 rooms = **380 walkable apartments**. No shells, no routing buckets. Everybody walks the
same corridors, knocks on the same doors and sees the same furniture.

## What it does

| Feature | How |
|---|---|
| Room per character | Assigned through the qb-spawn "pick an apartment" flow for new characters, at the lobby reception ("Check in"), or automatically `Wiwang.AutoAssignDelay` seconds after a character loads without one (`Wiwang.AutoAssignOnLoad`). Lowest floors fill first (`Wiwang.AssignOrder`). |
| Locked door | Native door system, **ox_doorlock** or **qb-doorlock** (`Wiwang.DoorLock`, auto-detected). Owner and key holders lock / unlock; others can **knock**. |
| Knock to open | The owner gets a prompt and can open the door for `Wiwang.KnockOpenTime` seconds; it locks itself again afterwards. |
| Stash | Per room, from the room menu. qb-inventory (new and old API) and ox_inventory (`Wiwang.Inventory`). |
| Wardrobe | Room menu -> Wardrobe fires `Wiwang.OutfitEvent` (qb-clothing by default). |
| Keys | Owner gives keys to other players (server id) and takes them back. Key holders can open the door and use the stash. |
| Furniture | Every assigned room gets `Wiwang.DefaultFurniture`. Owners add / remove props from the room menu (or `/roomfurni`). Saved per room. |
| Reception | Point in the lobby: check in, "where is my room" (waypoint), move out (`Wiwang.AllowMoveOut`). |
| Spawn | New characters start inside their room. "Last location" works out of the box because the room is a real place. |
| Elevator | The elevator menu of the map marks the floor of your room. |
| Log out | Room menu -> Log out (back to character selection). |
| Home blip | Hotel entrance, named with your room number. |
| Locale | All texts in `locales/en.lua` (`Wiwang.L(key, ...)`), copy and translate. |

## FPS: only render what is near you

* The map resource already loads **one floor interior at a time** per client (`map_wiwang_hotel/ipl.lua`).
* Furniture props are **local, non-networked objects**. Each client spawns only the rooms on **its own
  floor** that are within `Wiwang.RenderDistance` (22 m) and deletes them again when it walks away or
  changes floor. Worst case that is roughly 6 rooms x 7 props on screen instead of 380 x 7.
* Other players nearby see the same furniture because everybody spawns it from the same server data.
  Nothing is synced per entity, so the server has no entity cost at all.
* Door prompts use ox_lib points (grid based, checked every few hundred ms) or target options on the
  door model; nothing runs per frame unless you stand at a door or inside your room.

## Install

1. Keep `map_wiwang_hotel` as it is (ox_lib required, as before).
2. Add this folder to your resources.
3. **Replace qb-apartments** with it. Easiest: stop/remove `qb-apartments` and **rename this folder to
   `qb-apartments`**. That keeps the `@qb-apartments/config.lua` lines in qb-spawn and qb-multicharacter
   and their `GetResourceState('qb-apartments')` checks working with zero edits.
   If you keep the folder name `wiwang_apartments` instead, change those two manifests to
   `@wiwang_apartments/config.lua` and replace `GetResourceState('qb-apartments')` with
   `GetResourceState('wiwang_apartments')` in qb-multicharacter's `server.lua`.
4. `ensure` order: `oxmysql`, `ox_lib`, `qb-core`, (`ox_doorlock` / `qb-doorlock`, `ox_target` / `qb-target` if used),
   `map_wiwang_hotel`, then this resource.
5. The `wiwang_apartments` table is created on first start (`sql/wiwang_apartments.sql` if you prefer to
   run it yourself).

## Door locks (`Wiwang.DoorLock`)

| Mode | Setup | Notes |
|---|---|---|
| `native` | nothing | This resource registers the 380 doors with the game's door system and keeps them in the server state. `[E]` at a door: lock / unlock / knock. |
| `ox_doorlock` | nothing (auto when running) | On first start one ox_doorlock door is created for **every** hotel room (380, name = room id); afterwards only the owner / key list and the state change. Owner and key holders are the door's `characters` **and** are authorised through ox_doorlock's `doorAuthorization` hook, so it works on plain qb-core, which ox_doorlock does not bridge itself. ox_doorlock's own `[E]` prompt, sounds, lockpick settings and admin UI all apply. The **CommunityOx** fork has no `createDoor` export: the rows are inserted into its table instead and the console asks you to restart ox_doorlock once. Because ox_doorlock already uses `[E]` and the text UI at the door, the knock / room-door menu is on a keybind (`Wiwang.DoorKeybind`, default **G**, changeable in the game settings) unless a target resource is running. |
| `qb-doorlock` | copy `doorlock/qb-doorlock/wiwang_hotel.lua` into `qb-doorlock/configs/` | Door ids equal the room ids. Nobody is authorised in that file on purpose: this resource flips the state (owner / keys / knock) through `qb-doorlock:server:updateState`. States are pushed again after a restart as soon as a player is online. qb-doorlock keeps `[E]` for itself, so the door prompt shows the keybind (**G**) like in ox_doorlock mode. |

`/wiwang_doorlock` (admin) prints the active mode and re-syncs the doors; `/wiwang_doorlock cleanup`
deletes the hotel doors from ox_doorlock again (when you switch to another mode). If a door-lock
resource starts after this one, the switch is picked up automatically and every client is told.

## Interaction (`Wiwang.Target`)

* `ox_target` / `qb-target` (auto when running): options on the door model itself (Unlock, Lock, Room
  menu, Knock), no `[E]` prompt at doors.
* otherwise: `[E]` prompt at the door (ox_lib point) in native mode; with ox_doorlock or qb-doorlock
  the prompt points to the keybind (default **G**) because they use `[E]` themselves.
* Inside a room you have access to: `[E]` opens the room menu (`Wiwang.InteractKey`).
* Reception desk: `[E]` at `Wiwang.Reception.coords` (move it if the desk is elsewhere).

## Config (config.lua)

`Apartments` is the qb-apartments compatible table that qb-spawn / qb-multicharacter read. `Wiwang`
holds everything else: door-lock and target mode, keys, inventory type, stash size, outfit event,
knock-open time, reception, render distance, max props, default furniture, admin permission.

Default furniture uses **room-local** coordinates: x from -3.05 (door wall) to 3.05 (back wall),
y from -2.73 to 2.73, z = height above the floor, h = heading. One list fits all 380 rooms because
every room is a rotated copy of the same layout. The shipped list is a placeholder, tune it in game.

## Commands

| Command | Who | What |
|---|---|---|
| `/wiwang_room` | everyone | Shows your room + floor and sets a waypoint to the hotel |
| `/roomfurni` | owner, inside own room | Opens the furniture editor |
| `/wiwang_assign [id] [floor] [room]` | admin | Give a player a room (next free one when floor/room are omitted) |
| `/wiwang_unassign [id or citizenid or room id]` | admin | Free a room (wipes the stash when `ClearStashOnUnassign`) |
| `/wiwang_free` | admin | How many rooms are free |
| `/wiwang_doorlock [cleanup]` | admin | Show the door-lock mode and re-sync doors; `cleanup` removes the hotel doors from ox_doorlock |

## Exports

Server:

```lua
exports.wiwang_apartments:GetRoom(citizenid)           -- { id, floor, number, label, locked, keys, furniture } or nil
exports.wiwang_apartments:GetRoomOwner('wiwang_03_12') -- citizenid or nil
exports.wiwang_apartments:HasAccess(citizenid, roomId)
exports.wiwang_apartments:SetLocked(roomId, locked)    -- through the active door-lock backend
exports.wiwang_apartments:AssignRoom(citizenid, floor?, number?)  -- rec, err
exports.wiwang_apartments:UnassignRoom(roomId)
```

Client:

```lua
exports.wiwang_apartments:GetMyRoom()        -- owner view of your room or nil
exports.wiwang_apartments:GetRoomAt(coords?) -- nearest room door within 1.8 m (default: your position)
exports.wiwang_apartments:OpenRoomMenu(roomId)
exports.wiwang_apartments:OpenDoorMenu(roomId)
```

Room ids are `wiwang_FF_RR` (floor, room), labels are hotel style: floor 3 room 12 = `Room 312`.
Stash ids are `wiwang_stash_<roomId>`.

## qb-apartments compatibility

Implemented so other resources keep working: callbacks `apartments:GetOwnedApartment`,
`apartments:IsOwner`, `apartments:GetAvailableApartments`; events `apartments:server:CreateApartment`,
`apartments:client:setupSpawnUI`, `apartments:client:SpawnInApartment`, `apartments:client:SetHomeBlip`,
`qb-apartments:client:LastLocationHouse`, `qb-apartments:server:SetInsideMeta`, `qb-apartments:returnBucket`,
`apartments:server:openStash`, `apartments:server:RingDoor`, `apartments:client:OpenStash`,
`apartments:client:ChangeOutfit`, `apartments:client:Logout`.

Not kept: the `apartments` SQL table (data lives in `wiwang_apartments`), qb-interior shells and
routing buckets.

## Limits / notes

* 380 rooms. When the hotel is full new characters get a message and no room; players can move out at
  the reception and admins can free rooms with `/wiwang_unassign`.
* Room coordinates were extracted from the MLO files with `tools/mlo_dump.py` (see
  `shared/rooms.lua`), not measured in game. If a door or spawn point is a few centimetres off,
  adjust `Rooms.Template` or the offsets in `Rooms.Get`. `tools/gen_qb_doorlock.py` regenerates the
  qb-doorlock config from the same data (needs `pip install lupa`).
