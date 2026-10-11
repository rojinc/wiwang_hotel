--[[
    Door-lock backend adapter (server)

    native      -> this resource tells clients the lock state, clients drive the native door system
    ox_doorlock -> one ox_doorlock door per assigned room (name = roomId); authorisation through the
                   doorAuthorization hook, state changes come back through ox_doorlock:stateChanged
    qb-doorlock -> doors come from doorlock/qb-doorlock/wiwang_hotel.lua (static config, id = roomId);
                   this resource flips their state with qb-doorlock:server:updateState (unlockAnyway)
]]
DoorLock = { mode = 'native' }

local OxIds, ByOxId, Override = {}, {}, {}
local hookRegistered, syncing, qbSynced = false, false, false

local function running(res)
    return (GetResourceState(res) or ''):find('start') ~= nil
end

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

local function oxData(rec, room, characters)
    return {
        name = rec.id,
        model = Rooms.DoorModel,
        coords = { x = room.door.x, y = room.door.y, z = room.door.z },
        heading = room.doorHeading,
        state = rec.locked and 1 or 0,
        characters = characters,
        maxDistance = 2.0,
    }
end

local function oxCall(fn, ...)
    local args = { ... }
    local ok, res = pcall(function() return exports.ox_doorlock[fn](exports.ox_doorlock, table.unpack(args)) end)
    if not ok then print(('^3[wiwang_apartments]^7 ox_doorlock:%s failed: %s'):format(fn, res)) end
    return ok, res
end

function DoorLock.OxCreate(rec, characters)
    local room = Rooms.Get(rec.floor, rec.number)
    local ok, id = oxCall('createDoor', oxData(rec, room, characters))
    if ok and id then
        OxIds[rec.id], ByOxId[id] = id, rec.id
    end
    return ok and id or nil
end

function DoorLock.OxRemove(roomId)
    local id = OxIds[roomId]
    if not id then return end
    OxIds[roomId], ByOxId[id] = nil, nil
    oxCall('removeDoor', id)
end

function DoorLock.OxUpdateCharacters(rec, characters)
    local id = OxIds[rec.id]
    if id then oxCall('editDoor', id, { characters = characters }) end
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

function DoorLock.OxRoom(oxId)
    return ByOxId[oxId]
end

--- create / update / remove ox_doorlock doors so they match the assigned rooms
---@param rooms table roomId -> rec
---@param characters fun(rec: table): string[]
---@param onState fun(rec: table, locked: boolean)  ox_doorlock is the source of truth for the state
function DoorLock.OxSync(rooms, characters, onState)
    if DoorLock.mode ~= 'ox_doorlock' or syncing then return end
    syncing = true
    local rows = MySQL.query.await("SELECT `id`, `name` FROM `ox_doorlock` WHERE `name` LIKE 'wiwang\\_%'") or {}
    local known = {}
    for i = 1, #rows do known[rows[i].name] = rows[i].id end
    for roomId, rec in pairs(rooms) do
        local id = known[roomId]
        if id then
            known[roomId] = nil
            OxIds[roomId], ByOxId[id] = id, roomId
            oxCall('editDoor', id, { characters = characters(rec) })
            local ok, door = oxCall('getDoor', id)
            if ok and door and door.state ~= nil then onState(rec, door.state == 1) end
        else
            DoorLock.OxCreate(rec, characters(rec))
        end
    end
    for _, id in pairs(known) do -- doors of rooms that are no longer assigned
        oxCall('removeDoor', id)
    end
    syncing = false
end

---@param rooms table roomId -> rec (live table)
---@param hasAccess fun(src: number, rec: table): boolean
function DoorLock.OxRegisterHook(rooms, hasAccess)
    if hookRegistered then return end
    local ok = oxCall('registerHook', 'doorAuthorization', function(payload)
        local door = payload.door
        local rec = door and door.name and rooms[door.name]
        if not rec then return end            -- not one of our doors: leave ox_doorlock's decision alone
        if Override[rec.id] then return true end
        if payload.lockpick then return end   -- lockpicking stays whatever ox_doorlock decided
        return hasAccess(payload.source, rec) or false
    end, { nameFilter = '^wiwang_' })
    hookRegistered = ok
end

AddEventHandler('onResourceStart', function(res)
    if res == 'ox_doorlock' then hookRegistered = false end
    if res == 'qb-doorlock' then qbSynced = false end
end)

---------------------------------------------------------------------------------------------------
-- qb-doorlock
---------------------------------------------------------------------------------------------------

--- qb-doorlock needs an online player id to accept a state change
function DoorLock.QbSet(roomId, locked, src, silent)
    if not src then return false end
    TriggerEvent('qb-doorlock:server:updateState', roomId, locked, false, false, true, not silent, not silent, src)
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
