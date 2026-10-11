--[[
    Wiwang Hotel apartments - configuration

    qb-spawn and qb-multicharacter load this file as a shared script ('@qb-apartments/config.lua'),
    so it must stay self-contained: only the globals `Apartments` (qb-apartments compatible) and
    `Wiwang` are defined here and nothing else is called.
]]

-- qb-apartments compatible table (read by qb-spawn / qb-multicharacter) --------------------------
Apartments = {}
Apartments.Starting = true   -- new characters choose the hotel in qb-spawn and start inside their own room
Apartments.SpawnOffset = 30  -- unused (rooms are real places), kept for compatibility
Apartments.Locations = {
    ['wiwang'] = {
        name = 'wiwang',
        label = 'Wiwang Hotel',
        -- lobby entrance door: home blip + qb-spawn preview camera
        coords = { enter = vector4(-826.43, -700.86, 28.23, 270.0) },
        polyzoneBoxData = { heading = 0, minZ = 27.0, maxZ = 30.5, debug = false, length = 2, width = 3, distance = 2.0, created = false },
    },
}

-- Wiwang settings --------------------------------------------------------------------------------
Wiwang = {}
Wiwang.ApartmentType = 'wiwang'      -- key of Apartments.Locations above
Wiwang.AutoAssignOnLoad = true       -- give every character a free room the first time they load (works without qb-spawn too)
Wiwang.AssignOrder = 'floor'         -- 'floor' = fill the lowest floors first | 'random'
Wiwang.LockVacantRooms = false       -- true = rooms nobody owns are locked as well (native and qb-doorlock modes only)
Wiwang.AllowMoveOut = true           -- players can give their room back at the reception
Wiwang.Inventory = 'auto'            -- 'auto' | 'qb-inventory' | 'qb-inventory-old' | 'ox_inventory'
Wiwang.StashSlots = 50
Wiwang.StashWeight = 100000
Wiwang.ClearStashOnUnassign = true   -- wipe the room stash when a room is freed (next tenant starts empty)
Wiwang.OutfitEvent = 'qb-clothing:client:openOutfitMenu' -- illenium-appearance: 'illenium-appearance:client:openOutfitMenu'
Wiwang.Blip = { sprite = 475, colour = 3, scale = 0.7 }
Wiwang.AdminPermission = 'admin'     -- qb-core permission for the /wiwang_* admin commands

-- Door locks -------------------------------------------------------------------------------------
-- 'auto' picks ox_doorlock, then qb-doorlock, then the built-in native door system.
--  * native      : this resource registers the 380 doors itself (no extra resource needed)
--  * ox_doorlock : one ox_doorlock door per assigned room is created/removed automatically; owner and
--                  key holders are authorised through ox_doorlock's doorAuthorization hook, so its own
--                  [E] prompt, sounds and lockpick settings all work. Vacant rooms have no door entry.
--  * qb-doorlock : copy doorlock/qb-doorlock/wiwang_hotel.lua into qb-doorlock/configs/. Lock state is
--                  driven by this resource (owner / keys), qb-doorlock handles the door itself.
Wiwang.DoorLock = 'auto'             -- 'auto' | 'native' | 'ox_doorlock' | 'qb-doorlock'

-- Interaction ------------------------------------------------------------------------------------
-- 'auto' uses ox_target, then qb-target (options on the door model), otherwise [E] prompts via ox_lib.
Wiwang.Target = 'auto'               -- 'auto' | 'ox_target' | 'qb-target' | 'none'
Wiwang.InteractKey = 38              -- E: door prompt (native / qb-doorlock without target) and room menu inside the room
Wiwang.DoorKeybind = 'G'             -- used for the door menu when ox_doorlock owns the [E] prompt and no target resource is running
Wiwang.KnockOpenTime = 15            -- seconds the door stays open after the owner accepts a knock (0 = no prompt, just a notification)

-- Reception desk in the lobby: check in (get a room), find your room, move out
Wiwang.Reception = { enabled = true, coords = vector3(-824.2, -699.7, 28.0), distance = 2.5 }

-- Rendering --------------------------------------------------------------------------------------
-- Furniture is NOT networked. Each client spawns the props of the rooms on ITS OWN floor that are
-- within RenderDistance metres of it, and deletes them again when it walks away or changes floor.
-- Everybody nearby sees the same furniture because everybody spawns it from the same server data.
-- (The floor interiors themselves are already streamed per floor by map_wiwang_hotel/ipl.lua.)
Wiwang.RenderDistance = 22.0
Wiwang.RenderInterval = 750          -- ms between proximity checks
Wiwang.MaxFurniture = 40             -- props per room
Wiwang.AllowFurnitureEditing = true  -- owners can add / remove props from the room menu

-- Default furniture for every assigned room (room-local coordinates).
-- Frame: origin = room centre on the floor; x = -3.05 (door wall) .. 3.05 (back wall);
-- y = -2.73 .. 2.73; z = height above the floor; h = heading in degrees.
-- The 380 rooms are rotated copies of one layout, so this single list fits all of them.
-- PLACEHOLDER layout: tune it in game (room menu -> Furniture) or replace the props with your own.
Wiwang.DefaultFurniture = {
    { model = 'apa_mp_h_bed_double_09',   x = 1.3, y = 1.6,  z = 0.0,  h = 0.0 },
    { model = 'v_res_mdbedside',          x = 2.6, y = 2.3,  z = 0.0,  h = 0.0 },
    { model = 'v_res_mdbedside',          x = 0.0, y = 2.3,  z = 0.0,  h = 0.0 },
    { model = 'apa_mp_h_yacht_sofa_01',   x = 0.2, y = -2.0, z = 0.0,  h = 0.0 },
    { model = 'prop_table_03',            x = 2.4, y = -1.6, z = 0.0,  h = 0.0 },
    { model = 'prop_tv_flat_01',          x = 2.4, y = -1.6, z = 0.78, h = 90.0 },
    { model = 'apa_mp_h_acc_rugwoolm_04', x = 0.6, y = 0.0,  z = 0.0,  h = 0.0 },
}
