--[[
    Door-lock backend adapter (server)

    native      -> this resource tells clients the lock state, clients drive the native door system
    ox_doorlock -> one ox_doorlock door per hotel room (name = roomId), created once for all 380 rooms.
                   Owner + key holders are the door's `characters` and are also authorised through the
                   doorAuthorization hook (ox_doorlock does not bridge qb-core itself). Lock changes
                   come back through ox_doorlock:stateChanged.
                   Overextended builds expose createDoor; the CommunityOx fork does not, so there the
                   rows are inserted into the ox_doorlock table and ox_doorlock must be restarted once.
    qb-doorlock -> doors come from doorlock/qb-doorlock/wiwang_hotel.lua (static config, id = roomId);
                   this resource flips their state with qb-doorlock:server:updateState (unlockAnyway)
]]
DoorLock = { mode = 'native', oxCreateExport = nil }

local OxIds, ByOxId, Override = {}, {}, {}
local hookRegistered, syncing, qbSynced = false, false, false
local oxPendingRestart = 0
local warned = {}
local running = Wiwang.Running

function DoorLock.Resolve()
    local want = Wiwang.DoorLock
    if want == 'auto' then
        want = running('ox_doorlock') and 'ox_doorlock' or running('qb-doorlock') and 'qb-doorlock' or 'native'
    elseif want ~= 'native' and not running(want) then
        print(('^3[wiwang_apartments]^7 Wiwang.DoorLock = %s but that resource is not running, falling back to native door locks'):format(want))
        want = 'native'
    end
    DoorLock.mode = want
    return want
end

---------------------------------------------------------------------------------------------------
-- ox_doorlock
---------------------------------------------------------------------------------------------------

local function oxData(room, locked, characters)
    return {
        name = room.id,
        model = Rooms.DoorModel,
        coords = { x = room.door.x, y = room.door.y, z = room.door.z },
        heading = room.doorHeading,
        state = locked and 1 or 0,
        characters = characters,
        maxDistance = 2.0,
    }
end

--- call an ox_doorlock export; returns ok, result. A missing export is reported as ok = false, 'missing'.
local function oxCall(fn, ...)
    local args = table.pack(...)
    local ok, res = pcall(function() return exports.ox_doorlock[fn](exports.ox_doorlock, table.unpack(args, 1, args.n)) end)
    if ok then return true, res end
    local missing = tostring(res):find('No such export') ~= nil
    if not warned[fn] then
        warned[fn] = true
        print(('^3[wiwang_apartments]^7 ox_doorlock:%s %s'):format(fn, missing and 'is not available in this ox_doorlock build' or ('failed: ' .. tostring(res))))
    end
    return false, missing and 'missing' or res
end

local function sameList(a, b)
    if #a ~= #b then return false end
    local set = {}
    for i = 1, #a do set[a[i]] = true end
    for i = 1, #b do
        if not set[b[i]] then return false end
    end
    return true
end

--- create the ox_doorlock door of one room: export when available, otherwise a DB row (restart needed)
local function oxCreateDoor(room, locked, characters)
    local data = oxData(room, locked, characters)
    if DoorLock.oxCreateExport ~= false then
        local ok, id = oxCall('createDoor', data)
        if ok and id then
            DoorLock.oxCreateExport = true
            return id
        end
        if ok or id ~= 'missing' then return nil end
        DoorLock.oxCreateExport = false
    end
    local id = MySQL.insert.await('INSERT INTO ox_doorlock (name, data) VALUES (?, ?)', { room.id, json.encode(data) })
    if id then oxPendingRestart = oxPendingRestart + 1 end
    return id
end

--- change a door from the server: the authorisation hook lets it through while Override is set
function DoorLock.OxSet(roomId, locked)
    local id = OxIds[roomId]
    if not id then return false end
    Override[roomId] = true
    local ok, res = oxCall('setDoorState', id, locked and 1 or 0)
    Override[roomId] = nil
    return ok and res == true
end

function DoorLock.OxUpdateCharacters(rec, characters)
    local id = OxIds[rec.id]
    if id then oxCall('editDoor', id, { characters = characters }) end
end

--- room assigned: hand the door to its owner and lock it
function DoorLock.OxAssign(rec, characters)
    DoorLock.OxUpdateCharacters(rec, characters)
    DoorLock.OxSet(rec.id, true)
end

--- room freed: nobody owns the door any more
function DoorLock.OxRelease(roomId)
    local id = OxIds[roomId]
    if not id then return end
    oxCall('editDoor', id, { characters = {} })
    DoorLock.OxSet(roomId, Wiwang.LockVacantRooms)
end

function DoorLock.OxRoom(oxId)
    return ByOxId[oxId]
end

--- make sure every hotel room has an ox_doorlock door and that owners / states match our records
---@param rooms table roomId -> rec
---@param characters fun(rec: table): string[]
---@param onState fun(rec: table, locked: boolean)  ox_doorlock is the source of truth for assigned rooms
function DoorLock.OxSync(rooms, characters, onState)
    if DoorLock.mode ~= 'ox_doorlock' or syncing then return end
    syncing = true
    local rows = MySQL.query.await("SELECT `id`, `name` FROM `ox_doorlock` WHERE `name` LIKE 'wiwang\\_%'") or {}
    local known = {}
    for i = 1, #rows do known[rows[i].name] = rows[i].id end
    local created, pending = 0, {}
    for floor = 1, Rooms.Floors do
        for number = 1, #Rooms.Template do
            local room = Rooms.Get(floor, number)
            local rec = rooms[room.id]
            local chars = rec and characters(rec) or {}
            local wantLocked = rec and rec.locked or (not rec and Wiwang.LockVacantRooms)
            local id = known[room.id]
            if not id then
                id = oxCreateDoor(room, wantLocked, chars)
                if id then created = created + 1 end
            else
                local ok, door = oxCall('getDoor', id) -- false until ox_doorlock has finished loading
                if ok and door then
                    if not sameList(door.characters or {}, chars) then oxCall('editDoor', id, { characters = chars }) end
                    if rec then
                        if door.state ~= nil then onState(rec, door.state == 1) end
                    elseif (door.state == 1) ~= (wantLocked == true) then
                        pending[#pending + 1] = { room.id, wantLocked }
                    end
                end
            end
            if id then OxIds[room.id], ByOxId[id] = id, room.id end
        end
    end
    for i = 1, #pending do DoorLock.OxSet(pending[i][1], pending[i][2]) end
    if created > 0 then print(('^2[wiwang_apartments]^7 created %d ox_doorlock doors for the hotel rooms'):format(created)) end
    if oxPendingRestart > 0 then
        print(('^3[wiwang_apartments]^7 %d hotel doors were written straight into the ox_doorlock table (this ox_doorlock build has no createDoor export). Restart ox_doorlock once to load them.'):format(oxPendingRestart))
    end
    syncing = false
end

--- remove every hotel door from ox_doorlock (switching back to another mode)
function DoorLock.OxRemoveAll()
    local removed = 0
    local rows = MySQL.query.await("SELECT `id` FROM `ox_doorlock` WHERE `name` LIKE 'wiwang\\_%'") or {}
    for i = 1, #rows do
        local ok, res = oxCall('removeDoor', rows[i].id)
        if not ok and res == 'missing' then
            MySQL.query.await('DELETE FROM ox_doorlock WHERE id = ?', { rows[i].id })
            oxPendingRestart = oxPendingRestart + 1
        end
        removed = removed + 1
    end
    OxIds, ByOxId = {}, {}
    return removed, oxPendingRestart > 0
end

---@param rooms table roomId -> rec (live table)
---@param hasAccess fun(src: number, rec: table): boolean
function DoorLock.OxRegisterHook(rooms, hasAccess)
    if hookRegistered then return end
    local ok = oxCall('registerHook', 'doorAuthorization', function(payload)
        local door = payload.door
        local rec = door and door.name and rooms[door.name]
        if not rec then
            -- a vacant hotel door or not ours at all: leave ox_doorlock's own decision alone
            if door and door.name and door.name:find('^wiwang_') and Override[door.name] then return true end
            return
        end
        if Override[rec.id] then return true end
        if payload.lockpick then return end
        return hasAccess(payload.source, rec) or false
    end, { nameFilter = '^wiwang_' })
    hookRegistered = ok
end

AddEventHandler('onResourceStart', function(res)
    if res == 'ox_doorlock' then
        hookRegistered = false
        oxPendingRestart = 0
        OxIds, ByOxId = {}, {}
    end
    if res == 'qb-doorlock' then qbSynced = false end
end)

---------------------------------------------------------------------------------------------------
-- qb-doorlock
---------------------------------------------------------------------------------------------------

--- qb-doorlock needs an online player id to accept a state change
function DoorLock.QbSet(roomId, locked, src, silent)
    if not src or not running('qb-doorlock') then return false end
    TriggerEvent('qb-doorlock:server:updateState', roomId, locked == true, false, false, true, not silent, not silent, src)
    return true
end

--- qb-doorlock resets to its config defaults (unlocked) on restart: push our states once someone is online
function DoorLock.QbInitialSync(rooms, src)
    if DoorLock.mode ~= 'qb-doorlock' or qbSynced or not src then return end
    qbSynced = true
    for floor = 1, Rooms.Floors do
        for number = 1, #Rooms.Template do
            local id = Rooms.RoomId(floor, number)
            local rec = rooms[id]
            local locked = rec and rec.locked or (not rec and Wiwang.LockVacantRooms)
            if locked then DoorLock.QbSet(id, true, src, true) end
        end
    end
end
