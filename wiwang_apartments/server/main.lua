--[[
    Wiwang Hotel apartments - server

    One real hotel room per character. Rooms are physical MLO rooms (20 floors x 19 rooms), so there
    is no routing-bucket instancing: everybody walks the same corridors and sees the same doors.
]]
local QBCore = exports['qb-core']:GetCoreObject()
local L = Wiwang.L

local Data = {}       -- roomId -> { id, floor, number, label, citizenid, keys = {cid...}, furniture = list|nil, locked = bool }
local ByCitizen = {}  -- citizenid -> roomId
local Ready = false
local OxStashes = {}  -- stash ids already registered with ox_inventory
local InventoryType   -- resolved lazily, see DetectInventory()
local KnockCooldown = {} -- src -> game time of the last knock
local TotalRooms = Rooms.Floors * #Rooms.Template
local running = Wiwang.Running

local function Notify(src, msg, kind)
    TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary')
end

local function Cid(src)
    local Player = QBCore.Functions.GetPlayer(src)
    return Player and Player.PlayerData.citizenid or nil
end

local function StashId(roomId)
    return 'wiwang_stash_' .. roomId
end

local function AnyOnlinePlayer()
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        return Player.PlayerData.source
    end
end

---------------------------------------------------------------------------------------------------
-- Views / access
---------------------------------------------------------------------------------------------------

--- what every client gets for an assigned room (no owner identity)
local function PublicView(rec)
    return { locked = rec.locked, furniture = rec.furniture }
end

local function OwnerView(rec)
    return { id = rec.id, floor = rec.floor, number = rec.number, label = rec.label, locked = rec.locked, keys = rec.keys, furniture = rec.furniture }
end

local function HasAccess(rec, citizenid)
    if rec.citizenid == citizenid then return true end
    for i = 1, #rec.keys do
        if rec.keys[i] == citizenid then return true end
    end
    return false
end

--- owner first, then key holders (ox_doorlock `characters`)
local function Characters(rec)
    local list = { rec.citizenid }
    for i = 1, #rec.keys do list[#list + 1] = rec.keys[i] end
    return list
end

--- roomIds this citizen may open (own room + rooms they hold a key for)
local function AccessList(citizenid)
    local list = {}
    for id, rec in pairs(Data) do
        if HasAccess(rec, citizenid) then list[id] = true end
    end
    return list
end

local function NearRoom(src, rec, dist)
    local room = Rooms.Get(rec.floor, rec.number)
    local ped = GetPlayerPed(src)
    if not room or ped == 0 then return false end
    return #(GetEntityCoords(ped) - room.centre) < (dist or 10.0)
end

local function PushOwner(rec)
    local Player = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if Player then
        TriggerClientEvent('wiwang:client:setApartment', Player.PlayerData.source, OwnerView(rec), AccessList(rec.citizenid))
    end
end

local function PushAccess(citizenid)
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then
        TriggerClientEvent('wiwang:client:setAccess', Player.PlayerData.source, AccessList(citizenid))
    end
end

local function Broadcast(roomId, rec)
    TriggerClientEvent('wiwang:client:roomState', -1, roomId, rec and PublicView(rec) or false)
end

local function SetInsideMeta(Player, roomId)
    local inside = Player.PlayerData.metadata['inside'] or {}
    inside.apartment = roomId and { apartmentType = Wiwang.ApartmentType, apartmentId = roomId } or { apartmentType = nil, apartmentId = nil }
    Player.Functions.SetMetaData('inside', inside)
end

---------------------------------------------------------------------------------------------------
-- Lock state (all backends end up here)
---------------------------------------------------------------------------------------------------

--- record + persist + tell clients; does not touch the door-lock backend
local function ApplyLockState(rec, locked)
    locked = locked and true or false
    if rec.locked == locked then return end
    rec.locked = locked
    MySQL.update('UPDATE wiwang_apartments SET locked = ? WHERE room = ?', { locked and 1 or 0, rec.id })
    TriggerClientEvent('wiwang:client:lockState', -1, rec.id, locked)
end

--- lock / unlock through whichever door-lock backend is active
---@param src number|nil acting player (qb-doorlock needs one; any online player is used otherwise)
local function SetLocked(rec, locked, src)
    locked = locked == true
    local mode = DoorLock.mode
    if mode == 'ox_doorlock' then
        if DoorLock.OxSet(rec.id, locked) then return true end -- state comes back through ox_doorlock:stateChanged
        return false
    elseif mode == 'qb-doorlock' then
        if not DoorLock.QbSet(rec.id, locked, src or AnyOnlinePlayer()) then return false end
    end
    ApplyLockState(rec, locked)
    return true
end

AddEventHandler('ox_doorlock:stateChanged', function(_, oxId, locked)
    local roomId = DoorLock.OxRoom(oxId)
    local rec = roomId and Data[roomId]
    if rec then ApplyLockState(rec, locked) end
end)

---------------------------------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------------------------------

local function Load()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `wiwang_apartments` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `room` VARCHAR(20) NOT NULL,
        `floor` TINYINT UNSIGNED NOT NULL,
        `number` TINYINT UNSIGNED NOT NULL,
        `label` VARCHAR(32) NOT NULL,
        `citizenid` VARCHAR(50) NOT NULL,
        `keys` LONGTEXT NULL,
        `furniture` LONGTEXT NULL,
        `locked` TINYINT(1) NOT NULL DEFAULT 1,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), UNIQUE KEY `room` (`room`), UNIQUE KEY `citizenid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    local rows = MySQL.query.await('SELECT * FROM wiwang_apartments') or {}
    for i = 1, #rows do
        local row = rows[i]
        local rec = {
            id = row.room, floor = row.floor, number = row.number, label = row.label, citizenid = row.citizenid,
            keys = row.keys and json.decode(row.keys) or {},
            furniture = row.furniture and json.decode(row.furniture) or nil,
            locked = row.locked == true or row.locked == 1,
        }
        Data[rec.id] = rec
        ByCitizen[rec.citizenid] = rec.id
    end
    print(('^2[wiwang_apartments]^7 %d / %d rooms assigned, door locks: %s'):format(#rows, TotalRooms, DoorLock.mode))
end

local function FindFreeRoom()
    local free = {}
    for floor = 1, Rooms.Floors do
        for number = 1, #Rooms.Template do
            if not Data[Rooms.RoomId(floor, number)] then
                if Wiwang.AssignOrder ~= 'random' then return floor, number end
                free[#free + 1] = { floor, number }
            end
        end
    end
    if #free == 0 then return nil end
    local pick = free[math.random(#free)]
    return pick[1], pick[2]
end

--- Give `citizenid` a room. floor/number optional (next free room otherwise).
---@return table|nil rec, string|nil err  ('already_owns' returns the existing room as rec)
local function AssignRoom(citizenid, floor, number)
    if not Ready then return nil, 'not_ready' end
    if ByCitizen[citizenid] then return Data[ByCitizen[citizenid]], 'already_owns' end
    if not floor then
        floor, number = FindFreeRoom()
        if not floor then return nil, 'full' end
    end
    floor, number = tonumber(floor), tonumber(number)
    if not floor or not number or not Rooms.Template[number] or floor < 1 or floor > Rooms.Floors then return nil, 'invalid' end
    local id = Rooms.RoomId(floor, number)
    if Data[id] then return nil, 'taken' end
    local rec = { id = id, floor = floor, number = number, label = Rooms.Label(floor, number), citizenid = citizenid, keys = {}, furniture = nil, locked = true }
    Data[id] = rec            -- reserve before yielding so two logins cannot get the same room
    ByCitizen[citizenid] = id
    local inserted = MySQL.insert.await('INSERT INTO wiwang_apartments (room, floor, number, label, citizenid, `keys`, locked) VALUES (?, ?, ?, ?, ?, ?, 1)',
        { id, floor, number, rec.label, citizenid, '[]' })
    if not inserted then
        if Data[id] == rec then Data[id] = nil end
        if ByCitizen[citizenid] == id then ByCitizen[citizenid] = nil end
        return nil, 'db'
    end
    if DoorLock.mode == 'ox_doorlock' then
        DoorLock.OxAssign(rec, Characters(rec))
    elseif DoorLock.mode == 'qb-doorlock' then
        DoorLock.QbSet(id, true, AnyOnlinePlayer(), true)
    end
    Broadcast(id, rec)
    PushOwner(rec)
    return rec
end

local function DetectInventory()
    if InventoryType then return InventoryType end
    if Wiwang.Inventory ~= 'auto' then
        InventoryType = Wiwang.Inventory
    elseif GetResourceState('ox_inventory') == 'started' then
        InventoryType = 'ox_inventory'
    else
        InventoryType = 'qb-inventory' -- new export API first, falls back to the old events at runtime
    end
    return InventoryType
end

local TableExists = {}
local function HasTable(name)
    if TableExists[name] == nil then
        local row = MySQL.single.await('SELECT 1 AS ok FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?', { name })
        TableExists[name] = row ~= nil
    end
    return TableExists[name]
end

--- wipe a room stash, whether or not the inventory resource has it loaded right now
local function ClearStash(roomId, label)
    local stash = StashId(roomId)
    local inv = DetectInventory()
    if inv == 'ox_inventory' then
        pcall(function()
            if not OxStashes[stash] then
                exports.ox_inventory:RegisterStash(stash, label or stash, Wiwang.StashSlots, Wiwang.StashWeight, false)
                OxStashes[stash] = true
            end
            exports.ox_inventory:ClearInventory(stash)
        end)
    else
        pcall(function() exports['qb-inventory']:ClearStash(stash) end) -- in-memory copy (new qb-inventory)
        if HasTable('inventories') then MySQL.query('DELETE FROM inventories WHERE identifier = ?', { stash }) end
        if HasTable('stashitems') then MySQL.query('DELETE FROM stashitems WHERE stash = ?', { stash }) end
    end
end

local function OpenStash(src, rec)
    local stash = StashId(rec.id)
    local inv = DetectInventory()
    if inv == 'ox_inventory' then
        if not OxStashes[stash] then
            exports.ox_inventory:RegisterStash(stash, rec.label, Wiwang.StashSlots, Wiwang.StashWeight, false)
            OxStashes[stash] = true
        end
        exports.ox_inventory:forceOpenInventory(src, 'stash', stash)
    elseif inv == 'qb-inventory' then
        local ok = pcall(function()
            exports['qb-inventory']:OpenInventory(src, stash, { label = rec.label, maxweight = Wiwang.StashWeight, slots = Wiwang.StashSlots })
        end)
        if not ok then -- old qb-inventory without the OpenInventory export
            InventoryType = 'qb-inventory-old'
            TriggerClientEvent('wiwang:client:openOldStash', src, stash, { maxweight = Wiwang.StashWeight, slots = Wiwang.StashSlots })
        end
    else
        TriggerClientEvent('wiwang:client:openOldStash', src, stash, { maxweight = Wiwang.StashWeight, slots = Wiwang.StashSlots })
    end
end

--- Free a room (admin or move-out). Stash is wiped when Wiwang.ClearStashOnUnassign.
local function UnassignRoom(roomId)
    local rec = Data[roomId]
    if not rec then return false end
    MySQL.query.await('DELETE FROM wiwang_apartments WHERE room = ?', { roomId })
    Data[roomId] = nil
    ByCitizen[rec.citizenid] = nil
    if Wiwang.ClearStashOnUnassign then ClearStash(roomId, rec.label) end
    if DoorLock.mode == 'ox_doorlock' then
        DoorLock.OxRelease(roomId)
    elseif DoorLock.mode == 'qb-doorlock' then
        DoorLock.QbSet(roomId, Wiwang.LockVacantRooms, AnyOnlinePlayer(), true)
    end
    Broadcast(roomId, nil)
    local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if Owner then
        SetInsideMeta(Owner, nil) -- otherwise "last location" would put them back into a room that is not theirs
        TriggerClientEvent('wiwang:client:setApartment', Owner.PlayerData.source, false, AccessList(rec.citizenid))
    end
    for i = 1, #rec.keys do PushAccess(rec.keys[i]) end
    return rec
end

--- validate a furniture list sent by a client; returns a cleaned copy or nil
local function ValidFurniture(list)
    if type(list) ~= 'table' or #list > Wiwang.MaxFurniture then return nil end
    local clean = {}
    for i = 1, #list do
        local f = list[i]
        if type(f) ~= 'table' or type(f.model) ~= 'string' or #f.model == 0 or #f.model > 64 then return nil end
        local x, y, z, h = tonumber(f.x), tonumber(f.y), tonumber(f.z), tonumber(f.h) or 0.0
        if not x or not y or not z then return nil end
        -- must stay inside the room box (written so that NaN fails too)
        if not (x >= -3.3 and x <= 3.3 and y >= -3.0 and y <= 3.0 and z >= -0.2 and z <= 3.2 and h == h) then return nil end
        clean[i] = { model = f.model, x = x, y = y, z = z, h = h % 360.0 }
    end
    return clean
end

local function SaveFurniture(rec, list)
    local encoded = list and json.encode(list) or nil
    rec.furniture = list
    if encoded then
        MySQL.update('UPDATE wiwang_apartments SET furniture = ? WHERE room = ?', { encoded, rec.id })
    else
        MySQL.update('UPDATE wiwang_apartments SET furniture = NULL WHERE room = ?', { rec.id })
    end
    TriggerClientEvent('wiwang:client:furniture', -1, rec.id, list or false)
end

local function SaveKeys(rec)
    MySQL.update('UPDATE wiwang_apartments SET `keys` = ? WHERE room = ?', { json.encode(rec.keys), rec.id })
    if DoorLock.mode == 'ox_doorlock' then DoorLock.OxUpdateCharacters(rec, Characters(rec)) end
    PushOwner(rec)
end

local function OwnedRoom(src)
    local cid = Cid(src)
    local roomId = cid and ByCitizen[cid]
    return roomId and Data[roomId] or nil, cid
end

local function OpenStashFor(src, roomId)
    local rec = Data[roomId]
    local cid = Cid(src)
    if not rec or not cid or not HasAccess(rec, cid) or not NearRoom(src, rec, 8.0) then return end
    OpenStash(src, rec)
end

local function Knock(src, roomId)
    local rec = Data[roomId]
    if not rec or not NearRoom(src, rec, 12.0) then return end
    local now = GetGameTimer()
    if KnockCooldown[src] and now - KnockCooldown[src] < 5000 then return end
    KnockCooldown[src] = now
    Notify(src, L('knock_sent', rec.label))
    local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if not Owner then return end
    if Wiwang.KnockOpenTime > 0 and rec.locked then
        TriggerClientEvent('wiwang:client:knock', Owner.PlayerData.source, rec.id)
    else
        Notify(Owner.PlayerData.source, L('knock_received', rec.label))
    end
end

--- (re)resolve the door-lock backend; clients are told when it changes after startup
local function ResolveMode()
    local old = DoorLock.mode
    local mode = DoorLock.Resolve()
    if Ready and old ~= mode then
        print(('^3[wiwang_apartments]^7 door locks switched from %s to %s'):format(old, mode))
        TriggerClientEvent('wiwang:client:lockMode', -1, mode)
    end
    return mode
end

--- a character with no room gets the next free one
local function AutoAssign(src, cid)
    local rec, err = AssignRoom(cid)
    if rec then
        Notify(src, L('room_given', rec.label, rec.floor), 'success')
    elseif err == 'full' then
        Notify(src, L('hotel_full'), 'error')
    end
    return rec
end

local function SyncOxDoors()
    DoorLock.OxRegisterHook(Data, function(src, rec)
        local cid = Cid(src)
        return cid ~= nil and HasAccess(rec, cid)
    end)
    DoorLock.OxSync(Data, Characters, ApplyLockState)
end

---------------------------------------------------------------------------------------------------
-- Startup / player lifecycle
---------------------------------------------------------------------------------------------------

MySQL.ready(function()
    DoorLock.Resolve()
    Load()
    Ready = true
    if DoorLock.mode == 'ox_doorlock' then SyncOxDoors() end
    -- resource restarted while people are online: resend everybody their data
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        local cid = Player.PlayerData.citizenid
        local roomId = ByCitizen[cid]
        TriggerClientEvent('wiwang:client:setApartment', Player.PlayerData.source, roomId and OwnerView(Data[roomId]) or false, AccessList(cid))
        DoorLock.QbInitialSync(Data, Player.PlayerData.source)
    end
end)

-- qb-doorlock restarted while people are online: its doors fell back to the config defaults
AddEventHandler('onResourceStart', function(res)
    if res ~= 'qb-doorlock' or not Ready then return end
    SetTimeout(3000, function()
        if Wiwang.DoorLock == 'auto' then ResolveMode() end
        DoorLock.QbInitialSync(Data, AnyOnlinePlayer())
    end)
end)

-- ox_doorlock (re)started after us: hook and doors need to be registered again
AddEventHandler('ox_doorlock:loaded', function()
    if not Ready then return end
    if DoorLock.mode == 'ox_doorlock' or (Wiwang.DoorLock == 'auto' and ResolveMode() == 'ox_doorlock') then
        SyncOxDoors()
    end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local cid = Player.PlayerData.citizenid
    while not Ready do Wait(100) end
    if Wiwang.AutoAssignOnLoad and not ByCitizen[cid] then
        if Apartments.Starting then
            -- qb-core fires PlayerLoaded during login, before qb-spawn shows the apartment choice:
            -- wait so apartments:server:CreateApartment (spawn inside the room) can run first
            SetTimeout(Wiwang.AutoAssignDelay * 1000, function()
                local Still = QBCore.Functions.GetPlayer(src)
                if Still and Still.PlayerData.citizenid == cid and not ByCitizen[cid] then AutoAssign(src, cid) end
            end)
        else
            AutoAssign(src, cid)
        end
    end
    local roomId = ByCitizen[cid]
    TriggerClientEvent('wiwang:client:setApartment', src, roomId and OwnerView(Data[roomId]) or false, AccessList(cid))
    DoorLock.QbInitialSync(Data, src)
end)

AddEventHandler('playerDropped', function()
    KnockCooldown[source] = nil
end)

lib.callback.register('wiwang:getState', function(source)
    while not Ready do Wait(100) end
    local cid = Cid(source)
    local rooms = {}
    for id, rec in pairs(Data) do rooms[id] = PublicView(rec) end
    local roomId = cid and ByCitizen[cid]
    return rooms, roomId and OwnerView(Data[roomId]) or false, cid and AccessList(cid) or {}, DoorLock.mode
end)

lib.callback.register('wiwang:getKeyHolders', function(source)
    local rec = OwnedRoom(source)
    if not rec then return {} end
    local holders = {}
    for i = 1, #rec.keys do
        local cid = rec.keys[i]
        local name = cid
        local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
        if Player then
            name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
        else
            local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { cid })
            if row and row.charinfo then
                local info = json.decode(row.charinfo)
                if info then name = (info.firstname or '') .. ' ' .. (info.lastname or '') end
            end
        end
        holders[#holders + 1] = { citizenid = cid, name = name }
    end
    return holders
end)

---------------------------------------------------------------------------------------------------
-- Room actions
---------------------------------------------------------------------------------------------------

RegisterNetEvent('wiwang:server:setLock', function(roomId, locked)
    local src = source
    local rec = Data[roomId]
    local cid = Cid(src)
    if not rec or not cid or not HasAccess(rec, cid) or not NearRoom(src, rec, 12.0) then return end
    if SetLocked(rec, locked, src) then
        Notify(src, L(locked and 'door_locked' or 'door_unlocked', rec.label))
    end
end)

RegisterNetEvent('wiwang:server:knock', function(roomId)
    Knock(source, roomId)
end)

--- owner accepted a knock: unlock, lock again after Wiwang.KnockOpenTime seconds
RegisterNetEvent('wiwang:server:openForVisitor', function(roomId)
    local src = source
    local rec = Data[roomId]
    local cid = Cid(src)
    if not rec or rec.citizenid ~= cid or not rec.locked or Wiwang.KnockOpenTime <= 0 then return end
    if not SetLocked(rec, false, src) then return end
    Notify(src, L('door_opened_for', rec.label, Wiwang.KnockOpenTime), 'success')
    SetTimeout(Wiwang.KnockOpenTime * 1000, function()
        local current = Data[roomId]
        if current and current == rec and not rec.locked then
            local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
            SetLocked(rec, true, Owner and Owner.PlayerData.source or nil)
        end
    end)
end)

RegisterNetEvent('wiwang:server:openStash', function(roomId)
    OpenStashFor(source, roomId)
end)

RegisterNetEvent('wiwang:server:giveKey', function(targetId)
    local src = source
    local rec, cid = OwnedRoom(src)
    if not rec then return Notify(src, L('no_room'), 'error') end
    local Target = QBCore.Functions.GetPlayer(tonumber(targetId))
    if not Target then return Notify(src, L('player_not_found'), 'error') end
    local tcid = Target.PlayerData.citizenid
    if tcid == cid or HasAccess(rec, tcid) then return Notify(src, L('already_has_key'), 'error') end
    rec.keys[#rec.keys + 1] = tcid
    SaveKeys(rec)
    PushAccess(tcid)
    Notify(src, L('key_given'), 'success')
    Notify(Target.PlayerData.source, L('key_received', rec.label, rec.floor), 'success')
end)

RegisterNetEvent('wiwang:server:removeKey', function(citizenid)
    local src = source
    local rec = OwnedRoom(src)
    if not rec then return end
    for i = #rec.keys, 1, -1 do
        if rec.keys[i] == citizenid then table.remove(rec.keys, i) end
    end
    SaveKeys(rec)
    PushAccess(citizenid)
    Notify(src, L('key_taken'), 'success')
end)

RegisterNetEvent('wiwang:server:setFurniture', function(list)
    local src = source
    local rec = OwnedRoom(src)
    if not rec or not Wiwang.AllowFurnitureEditing or not NearRoom(src, rec, 8.0) then return end
    local clean = ValidFurniture(list)
    if not clean then return Notify(src, L('furni_invalid'), 'error') end
    SaveFurniture(rec, clean)
end)

RegisterNetEvent('wiwang:server:resetFurniture', function()
    local src = source
    local rec = OwnedRoom(src)
    if not rec or not NearRoom(src, rec, 8.0) then return end
    SaveFurniture(rec, nil)
    Notify(src, L('furni_reset_done'))
end)

RegisterNetEvent('wiwang:server:logout', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local rec = OwnedRoom(src)
    if not rec or not NearRoom(src, rec, 8.0) then return end
    SetInsideMeta(Player, rec.id)
    QBCore.Player.Logout(src)
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
end)

---------------------------------------------------------------------------------------------------
-- Reception
---------------------------------------------------------------------------------------------------

local function NearReception(src)
    if not Wiwang.Reception.enabled then return false end
    local ped = GetPlayerPed(src)
    return ped ~= 0 and #(GetEntityCoords(ped) - Wiwang.Reception.coords) < (Wiwang.Reception.distance + 3.0)
end

RegisterNetEvent('wiwang:server:checkIn', function()
    local src = source
    local cid = Cid(src)
    if not cid or not NearReception(src) then return end
    local rec, err = AssignRoom(cid)
    if rec and err == 'already_owns' then
        Notify(src, L('already_have_room', rec.label), 'error')
    elseif rec then
        Notify(src, L('welcome', rec.label, rec.floor), 'success')
        TriggerClientEvent('wiwang:client:showRoom', src, OwnerView(rec))
    else
        Notify(src, L(err == 'full' and 'hotel_full' or 'assign_failed'), 'error')
    end
end)

RegisterNetEvent('wiwang:server:moveOut', function()
    local src = source
    local rec = OwnedRoom(src)
    if not rec or not Wiwang.AllowMoveOut or not NearReception(src) then return end
    UnassignRoom(rec.id)
    Notify(src, L('moved_out', rec.label), 'success')
end)

---------------------------------------------------------------------------------------------------
-- qb-apartments compatible events / callbacks (used by qb-spawn, qb-multicharacter and others)
---------------------------------------------------------------------------------------------------

RegisterNetEvent('apartments:server:CreateApartment', function(_, _, firstSpawn)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    while not Ready do Wait(100) end
    local cid = Player.PlayerData.citizenid
    local rec, err = AssignRoom(cid)
    if not rec then
        Notify(src, L(err == 'full' and 'hotel_full' or 'assign_failed'), 'error')
        SetPlayerRoutingBucket(src, 0)
        return
    end
    if err ~= 'already_owns' then
        Notify(src, L('welcome', rec.label, rec.floor), 'success')
    end
    if firstSpawn then
        SetPlayerRoutingBucket(src, 0)
        TriggerClientEvent('apartments:client:SpawnInApartment', src, rec.id, Wiwang.ApartmentType)
    end
    TriggerClientEvent('apartments:client:SetHomeBlip', src, Wiwang.ApartmentType)
end)

RegisterNetEvent('apartments:server:UpdateApartment', function()
    Notify(source, L('single_hotel'), 'error')
end)

RegisterNetEvent('qb-apartments:returnBucket', function()
    SetPlayerRoutingBucket(source, 0)
end)

RegisterNetEvent('qb-apartments:server:SetInsideMeta', function(_, insideId, bool)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    SetInsideMeta(Player, bool and insideId or nil)
end)

RegisterNetEvent('apartments:server:setCurrentApartment', function(ap)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player then Player.Functions.SetMetaData('currentapartment', ap) end
end)

RegisterNetEvent('apartments:server:openStash', function(roomId)
    OpenStashFor(source, roomId)
end)

RegisterNetEvent('apartments:server:RingDoor', function(roomId)
    Knock(source, roomId)
end)

QBCore.Functions.CreateCallback('apartments:GetOwnedApartment', function(source, cb, cid)
    while not Ready do Wait(100) end
    cid = cid or Cid(source)
    local roomId = cid and ByCitizen[cid]
    if not roomId then return cb(nil) end
    local rec = Data[roomId]
    cb({ name = rec.id, type = Wiwang.ApartmentType, label = rec.label, citizenid = rec.citizenid, floor = rec.floor, number = rec.number })
end)

QBCore.Functions.CreateCallback('apartments:IsOwner', function(source, cb)
    local cid = Cid(source)
    cb(cid ~= nil and ByCitizen[cid] ~= nil)
end)

QBCore.Functions.CreateCallback('apartments:GetAvailableApartments', function(_, cb)
    local list = {}
    for id, rec in pairs(Data) do list[#list + 1] = { name = id, label = rec.label } end
    table.sort(list, function(a, b) return a.name < b.name end)
    cb(list)
end)

QBCore.Functions.CreateCallback('apartments:GetApartmentOffset', function(_, cb) cb(0) end)
QBCore.Functions.CreateCallback('apartments:GetApartmentOffsetNewOffset', function(_, cb) cb(0) end)

---------------------------------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------------------------------

QBCore.Commands.Add('wiwang_room', 'Show where your Wiwang Hotel room is', {}, false, function(source)
    local rec = OwnedRoom(source)
    if not rec then return Notify(source, L('no_room'), 'error') end
    TriggerClientEvent('wiwang:client:showRoom', source, OwnerView(rec))
end)

QBCore.Commands.Add('wiwang_assign', 'Assign a Wiwang Hotel room to a player (admin)', {
    { name = 'id', help = 'Player server id' },
    { name = 'floor', help = 'Floor 1-' .. Rooms.Floors .. ' (optional)' },
    { name = 'room', help = 'Room 1-' .. #Rooms.Template .. ' (optional)' },
}, false, function(source, args)
    local Target = QBCore.Functions.GetPlayer(tonumber(args[1]))
    if not Target then return Notify(source, L('player_not_found'), 'error') end
    local rec, err = AssignRoom(Target.PlayerData.citizenid, args[2], args[3])
    if not rec or err == 'already_owns' then
        return Notify(source, L('assign_error', tostring(err)), 'error')
    end
    Notify(source, L('assigned_to', GetPlayerName(Target.PlayerData.source), rec.label, rec.floor), 'success')
    Notify(Target.PlayerData.source, L('room_given', rec.label, rec.floor), 'success')
end, Wiwang.AdminPermission)

QBCore.Commands.Add('wiwang_unassign', 'Take a Wiwang Hotel room away (admin)', {
    { name = 'target', help = 'Player server id, citizenid or room id (wiwang_03_12)' },
}, true, function(source, args)
    local target = args[1]
    local roomId
    if Data[target] then
        roomId = target
    elseif ByCitizen[target] then
        roomId = ByCitizen[target]
    else
        local Player = QBCore.Functions.GetPlayer(tonumber(target))
        roomId = Player and ByCitizen[Player.PlayerData.citizenid]
    end
    if not roomId then return Notify(source, L('no_room_for', tostring(target)), 'error') end
    local rec = UnassignRoom(roomId)
    Notify(source, L('room_freed', rec.label), 'success')
    local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if Owner then Notify(Owner.PlayerData.source, L('room_taken_away', rec.label), 'error') end
end, Wiwang.AdminPermission)

QBCore.Commands.Add('wiwang_free', 'How many Wiwang Hotel rooms are free (admin)', {}, false, function(source)
    local used = 0
    for _ in pairs(Data) do used = used + 1 end
    Notify(source, L('rooms_summary', used, TotalRooms, TotalRooms - used))
end, Wiwang.AdminPermission)

QBCore.Commands.Add('wiwang_doorlock', 'Door-lock backend: show + resync, or "cleanup" to delete the hotel doors from ox_doorlock (admin)', {
    { name = 'action', help = '(empty) = resync | cleanup' },
}, false, function(source, args)
    if args[1] == 'cleanup' and running('ox_doorlock') then
        local removed, restart = DoorLock.OxRemoveAll()
        return Notify(source, L('doorlock_cleanup', removed) .. (restart and (' ' .. L('doorlock_restart')) or ''))
    end
    ResolveMode()
    if DoorLock.mode == 'ox_doorlock' then
        SyncOxDoors()
    elseif DoorLock.mode == 'qb-doorlock' then
        for id, rec in pairs(Data) do DoorLock.QbSet(id, rec.locked, source, true) end
    end
    Notify(source, L('doorlock_mode', DoorLock.mode, Wiwang.Target))
end, Wiwang.AdminPermission)

---------------------------------------------------------------------------------------------------
-- Exports
---------------------------------------------------------------------------------------------------

exports('GetRoom', function(citizenid)
    local roomId = ByCitizen[citizenid]
    return roomId and OwnerView(Data[roomId]) or nil
end)
exports('GetRoomOwner', function(roomId)
    return Data[roomId] and Data[roomId].citizenid or nil
end)
exports('HasAccess', function(citizenid, roomId)
    return Data[roomId] ~= nil and HasAccess(Data[roomId], citizenid)
end)
exports('SetLocked', function(roomId, locked)
    local rec = Data[roomId]
    return rec ~= nil and SetLocked(rec, locked, nil)
end)
exports('AssignRoom', AssignRoom)
exports('UnassignRoom', function(roomId) return UnassignRoom(roomId) ~= false end)
