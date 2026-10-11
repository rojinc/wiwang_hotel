# wiwang_apartments

qb-apartments style apartments for the **Wiwang Hotel MLO**, using the hotel's **real rooms**:
20 floors x 19 rooms = **380 walkable apartments**. No shells, no routing buckets. Everybody walks the
same corridors, knocks on the same doors and sees the same furniture.

## What it does

| Feature | How |
|---|---|
| Room per character | Assigned automatically the first time a character loads (`Wiwang.AutoAssignOnLoad`) or through the qb-spawn "pick an apartment" flow for new characters. Lowest floors fill first (`Wiwang.AssignOrder`). |
| Locked door | The room door (`floky_wiwang_wood_door_01`) is registered with the native door system. Owner / key holders lock and unlock it with **[E]** at the door; others can **knock** (owner gets a notification). |
| Stash | Per room, opened from the room menu. Works with qb-inventory (new and old API) and ox_inventory (`Wiwang.Inventory`). |
| Wardrobe | Room menu -> Wardrobe fires `Wiwang.OutfitEvent` (qb-clothing by default). |
| Keys | Owner gives keys to other players (server id) and takes them back. Key holders can open the door and use the stash. |
| Furniture | Every assigned room gets `Wiwang.DefaultFurniture`. Owners can add / remove props from the room menu (or `/roomfurni`). Saved per room in the database. |
| Spawn | New characters start inside their room. "Last location" works out of the box because the room is a real place in the world. |
| Log out | Room menu -> Log out (back to character selection). |
| Home blip | Hotel entrance, named with your room number. |

## FPS: only render what is near you

* The map resource already loads **one floor interior at a time** per client (`map_wiwang_hotel/ipl.lua`).
* Furniture props are **local, non-networked objects**. Each client spawns only the rooms on **its own
  floor** that are within `Wiwang.RenderDistance` (22 m) and deletes them again when it walks away or
  changes floor. Worst case that is roughly 6 rooms x 7 props on screen instead of 380 x 7.
* Other players nearby see the same furniture because everybody spawns it from the same server data.
  Nothing is synced per entity, so the server has no entity cost at all.

## Install

1. Keep `map_wiwang_hotel` as it is (ox_lib required, as before).
2. Add this folder to your resources.
3. **Replace qb-apartments** with it. Easiest: stop/remove `qb-apartments` and **rename this folder to
   `qb-apartments`**. That keeps the `@qb-apartments/config.lua` lines in qb-spawn and qb-multicharacter
   and their `GetResourceState('qb-apartments')` checks working with zero edits.
   If you keep the folder name `wiwang_apartments` instead, change those two manifests to
   `@wiwang_apartments/config.lua` and replace `GetResourceState('qb-apartments')` with
   `GetResourceState('wiwang_apartments')` in qb-multicharacter's `server.lua`.
4. `ensure` order: `oxmysql`, `ox_lib`, `qb-core`, `map_wiwang_hotel`, then this resource.
5. The `wiwang_apartments` table is created on first start (`sql/wiwang_apartments.sql` if you prefer to
   run it yourself).

## Config (config.lua)

`Apartments` is the qb-apartments compatible table that qb-spawn / qb-multicharacter read. `Wiwang`
holds everything else: inventory type, stash size, outfit event, render distance, max props,
default furniture, admin permission.

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

## Exports (server)

```lua
exports.wiwang_apartments:GetRoom(citizenid)          -- { id, floor, number, label, locked, keys, furniture } or nil
exports.wiwang_apartments:GetRoomOwner('wiwang_03_12') -- citizenid or nil
exports.wiwang_apartments:HasAccess(citizenid, roomId)
exports.wiwang_apartments:AssignRoom(citizenid, floor?, number?)  -- rec, err
exports.wiwang_apartments:UnassignRoom(roomId)
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

* 380 rooms. When the hotel is full new characters get a message and no room; use
  `/wiwang_unassign` to free rooms or raise capacity with another building.
* Door locking uses the native door system (same approach as ox_doorlock), it is not registered in
  ox_doorlock's database.
* Room coordinates were extracted from the MLO files with `tools/mlo_dump.py` (see
  `shared/rooms.lua`), not measured in game. If a door or spawn point is a few centimetres off,
  adjust `Rooms.Template` or the offsets in `Rooms.Get`.
