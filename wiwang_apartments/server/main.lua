--[[
    Wiwang Hotel apartments - server

    One real hotel room per character. Rooms are physical MLO rooms (20 floors x 19 rooms), so there
    is no routing-bucket instancing: everybody walks the same corridors and sees the same doors.
]]
local QBCore = exports['qb-core']:GetCoreObject()

local Data = {}       -- roomId -> { id, floor, number, label, citizenid, keys = {cid...}, furniture = list|nil, locked = bool }
local ByCitizen = {}  -- citizenid -> roomId
local Ready = false
local OxStashes = {}  -- stash ids already registered with ox_inventory
local InventoryType   -- resolved lazily, see DetectInventory()
local TotalRooms = Rooms.Floors * #Rooms.Template

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
            locked = row.locked == 1,
        }
        Data[rec.id] = rec
        ByCitizen[rec.citizenid] = rec.id
    end
    Ready = true
    print(('^2[wiwang_apartments]^7 %d / %d rooms assigned'):format(#rows, TotalRooms))
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
    MySQL.insert.await('INSERT INTO wiwang_apartments (room, floor, number, label, citizenid, `keys`, locked) VALUES (?, ?, ?, ?, ?, ?, 1)',
        { id, floor, number, rec.label, citizenid, '[]' })
    Data[id] = rec
    ByCitizen[citizenid] = id
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

local function ClearStash(roomId)
    local stash = StashId(roomId)
    local inv = DetectInventory()
    if inv == 'ox_inventory' then
        pcall(function() exports.ox_inventory:ClearInventory(stash) end)
    elseif inv == 'qb-inventory' then
        if not pcall(function() exports['qb-inventory']:ClearStash(stash) end) then
            MySQL.query('DELETE FROM stashitems WHERE stash = ?', { stash })
        end
    else
        MySQL.query('DELETE FROM stashitems WHERE stash = ?', { stash })
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

--- Take the room away from its owner (admin). Stash is wiped when Wiwang.ClearStashOnUnassign.
local function UnassignRoom(roomId)
    local rec = Data[roomId]
    if not rec then return false end
    MySQL.query.await('DELETE FROM wiwang_apartments WHERE room = ?', { roomId })
    Data[roomId] = nil
    ByCitizen[rec.citizenid] = nil
    if Wiwang.ClearStashOnUnassign then ClearStash(roomId) end
    Broadcast(roomId, nil)
    local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if Owner then
        TriggerClientEvent('wiwang:client:setApartment', Owner.PlayerData.source, false, AccessList(rec.citizenid))
        Notify(Owner.PlayerData.source, rec.label .. ' is no longer yours', 'error')
    end
    for i = 1, #rec.keys do PushAccess(rec.keys[i]) end
    return true
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
        if math.abs(x) > 3.3 or math.abs(y) > 3.0 or z < -0.2 or z > 3.2 then return nil end -- must stay inside the room box
        clean[i] = { model = f.model, x = x, y = y, z = z, h = h % 360.0 }
    end
    return clean
end

local function SaveFurniture(rec, list)
    rec.furniture = list
    if list then
        MySQL.update('UPDATE wiwang_apartments SET furniture = ? WHERE room = ?', { json.encode(list), rec.id })
    else
        MySQL.update('UPDATE wiwang_apartments SET furniture = NULL WHERE room = ?', { rec.id })
    end
    TriggerClientEvent('wiwang:client:furniture', -1, rec.id, list or false)
end

local function OwnedRoom(src)
    local cid = Cid(src)
    local roomId = cid and ByCitizen[cid]
    return roomId and Data[roomId] or nil, cid
end

---------------------------------------------------------------------------------------------------
-- Startup / player lifecycle
---------------------------------------------------------------------------------------------------

MySQL.ready(function()
    Load()
    -- resource restarted while people are online: resend everybody their data
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        local cid = Player.PlayerData.citizenid
        local roomId = ByCitizen[cid]
        TriggerClientEvent('wiwang:client:setApartment', Player.PlayerData.source, roomId and OwnerView(Data[roomId]) or false, AccessList(cid))
    end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local cid = Player.PlayerData.citizenid
    while not Ready do Wait(100) end
    if Wiwang.AutoAssignOnLoad and not ByCitizen[cid] then
        local rec, err = AssignRoom(cid)
        if rec then
            Notify(src, ('You have been given %s at the Wiwang Hotel (floor %d)'):format(rec.label, rec.floor), 'success')
        elseif err == 'full' then
            Notify(src, 'The Wiwang Hotel is full, no room could be assigned', 'error')
        end
    end
    local roomId = ByCitizen[cid]
    TriggerClientEvent('wiwang:client:setApartment', src, roomId and OwnerView(Data[roomId]) or false, AccessList(cid))
end)

lib.callback.register('wiwang:getState', function(source)
    while not Ready do Wait(100) end
    local cid = Cid(source)
    local rooms = {}
    for id, rec in pairs(Data) do rooms[id] = PublicView(rec) end
    local roomId = cid and ByCitizen[cid]
    return rooms, roomId and OwnerView(Data[roomId]) or false, cid and AccessList(cid) or {}
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
    rec.locked = locked and true or false
    MySQL.update('UPDATE wiwang_apartments SET locked = ? WHERE room = ?', { rec.locked and 1 or 0, roomId })
    TriggerClientEvent('wiwang:client:lockState', -1, roomId, rec.locked)
    Notify(src, rec.label .. (rec.locked and ' locked' or ' unlocked'))
end)

RegisterNetEvent('wiwang:server:knock', function(roomId)
    local src = source
    local rec = Data[roomId]
    if not rec or not NearRoom(src, rec, 12.0) then return end
    local Owner = QBCore.Functions.GetPlayerByCitizenId(rec.citizenid)
    if Owner then Notify(Owner.PlayerData.source, 'Someone is knocking on the door of ' .. rec.label) end
    Notify(src, 'You knock on the door of ' .. rec.label)
end)

RegisterNetEvent('wiwang:server:openStash', function(roomId)
    local src = source
    local rec = Data[roomId]
    local cid = Cid(src)
    if not rec or not cid or not HasAccess(rec, cid) or not NearRoom(src, rec, 8.0) then return end
    OpenStash(src, rec)
end)

RegisterNetEvent('wiwang:server:giveKey', function(targetId)
    local src = source
    local rec, cid = OwnedRoom(src)
    if not rec then return Notify(src, 'You do not own a room', 'error') end
    local Target = QBCore.Functions.GetPlayer(tonumber(targetId))
    if not Target then return Notify(src, 'Player not found', 'error') end
    local tcid = Target.PlayerData.citizenid
    if tcid == cid or HasAccess(rec, tcid) then return Notify(src, 'They already have a key', 'error') end
    rec.keys[#rec.keys + 1] = tcid
    MySQL.update('UPDATE wiwang_apartments SET `keys` = ? WHERE room = ?', { json.encode(rec.keys), rec.id })
    PushOwner(rec)
    PushAccess(tcid)
    Notify(src, 'Key given', 'success')
    Notify(Target.PlayerData.source, 'You received a key to ' .. rec.label .. ' (Wiwang Hotel, floor ' .. rec.floor .. ')', 'success')
end)

RegisterNetEvent('wiwang:server:removeKey', function(citizenid)
    local src = source
    local rec = OwnedRoom(src)
    if not rec then return end
    for i = #rec.keys, 1, -1 do
        if rec.keys[i] == citizenid then table.remove(rec.keys, i) end
    end
    MySQL.update('UPDATE wiwang_apartments SET `keys` = ? WHERE room = ?', { json.encode(rec.keys), rec.id })
    PushOwner(rec)
    PushAccess(citizenid)
    Notify(src, 'Key taken back', 'success')
end)

RegisterNetEvent('wiwang:server:setFurniture', function(list)
    local src = source
    local rec = OwnedRoom(src)
    if not rec or not Wiwang.AllowFurnitureEditing or not NearRoom(src, rec, 8.0) then return end
    local clean = ValidFurniture(list)
    if not clean then return Notify(src, 'Invalid furniture data', 'error') end
    SaveFurniture(rec, clean)
end)

RegisterNetEvent('wiwang:server:resetFurniture', function()
    local src = source
    local rec = OwnedRoom(src)
    if not rec or not NearRoom(src, rec, 8.0) then return end
    SaveFurniture(rec, nil)
    Notify(src, 'Furniture reset to default')
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
        Notify(src, err == 'full' and 'The Wiwang Hotel is full, no room could be assigned' or 'Could not assign a room', 'error')
        SetPlayerRoutingBucket(src, 0)
        return
    end
    if err ~= 'already_owns' then
        Notify(src, ('Welcome! %s at the Wiwang Hotel is yours (floor %d)'):format(rec.label, rec.floor), 'success')
    end
    if firstSpawn then
        SetPlayerRoutingBucket(src, 0)
        TriggerClientEvent('apartments:client:SpawnInApartment', src, rec.id, Wiwang.ApartmentType)
    end
    TriggerClientEvent('apartments:client:SetHomeBlip', src, Wiwang.ApartmentType)
end)

RegisterNetEvent('apartments:server:UpdateApartment', function()
    Notify(source, 'There is only one Wiwang Hotel; use an admin command to move rooms', 'error')
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
    local src = source
    local rec = Data[roomId]
    local cid = Cid(src)
    if not rec or not cid or not HasAccess(rec, cid) or not NearRoom(src, rec, 8.0) then return end
    OpenStash(src, rec)
end)

RegisterNetEvent('apartments:server:RingDoor', function(roomId)
    TriggerEvent('wiwang:server:knock', roomId)
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
    if not rec then return Notify(source, 'You do not have a room at the Wiwang Hotel', 'error') end
    TriggerClientEvent('wiwang:client:showRoom', source, OwnerView(rec))
end)

QBCore.Commands.Add('wiwang_assign', 'Assign a Wiwang Hotel room to a player (admin)', {
    { name = 'id', help = 'Player server id' },
    { name = 'floor', help = 'Floor 1-' .. Rooms.Floors .. ' (optional)' },
    { name = 'room', help = 'Room 1-' .. #Rooms.Template .. ' (optional)' },
}, false, function(source, args)
    local Target = QBCore.Functions.GetPlayer(tonumber(args[1]))
    if not Target then return Notify(source, 'Player not found', 'error') end
    local rec, err = AssignRoom(Target.PlayerData.citizenid, args[2], args[3])
    if not rec or err == 'already_owns' then
        return Notify(source, 'Could not assign: ' .. tostring(err), 'error')
    end
    Notify(source, ('%s assigned to %s (floor %d)'):format(GetPlayerName(Target.PlayerData.source), rec.label, rec.floor), 'success')
    Notify(Target.PlayerData.source, 'You have been given ' .. rec.label .. ' at the Wiwang Hotel', 'success')
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
    if not roomId then return Notify(source, 'No room found for ' .. tostring(target), 'error') end
    local label = Data[roomId].label
    UnassignRoom(roomId)
    Notify(source, label .. ' is free again', 'success')
end, Wiwang.AdminPermission)

QBCore.Commands.Add('wiwang_free', 'How many Wiwang Hotel rooms are free (admin)', {}, false, function(source)
    local used = 0
    for _ in pairs(Data) do used = used + 1 end
    Notify(source, ('%d of %d rooms assigned, %d free'):format(used, TotalRooms, TotalRooms - used))
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
exports('AssignRoom', AssignRoom)
exports('UnassignRoom', UnassignRoom)
