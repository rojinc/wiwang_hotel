--[[
    Wiwang Hotel apartments - client

    * registers the 380 room doors with the native door system and keeps them locked / unlocked
      from the server state
    * [E] at a door: lock / unlock / knock
    * [E] inside a room you have access to: stash, wardrobe, keys, furniture, log out
    * qb-apartments compatible events so qb-spawn / qb-multicharacter can spawn you in your room
]]
local QBCore = exports['qb-core']:GetCoreObject()

-- shared with client/furniture.lua (same Lua environment inside this resource)
WiwangClient = {
    rooms = {},   -- roomId -> { locked = bool, furniture = list|nil }  (assigned rooms only)
    cache = {},   -- roomId -> Rooms.Get() world data for all rooms
    mine = nil,   -- owner view of my own room (nil when I have none)
    access = {},  -- roomId -> true for every room I may open (own + keys)
}
local S = WiwangClient

local DoorsReady = false
local Zones = {}       -- roomId -> lib.zones.box (only rooms I can access)
local CurrentDoor      -- roomId of the door point I am standing at
local InsideRoom       -- roomId of the accessible room I am standing in
local HomeBlip

for floor = 1, Rooms.Floors do
    for number = 1, #Rooms.Template do
        local room = Rooms.Get(floor, number)
        S.cache[room.id] = room
    end
end

---------------------------------------------------------------------------------------------------
-- Doors
---------------------------------------------------------------------------------------------------

local function DoorHash(roomId)
    return joaat('wiwang_door_' .. roomId)
end

local function IsLocked(roomId)
    local st = S.rooms[roomId]
    if st then return st.locked end
    return Wiwang.LockVacantRooms
end

local function ApplyDoor(roomId)
    if not DoorsReady then return end
    -- door system states: 0 = unlocked, 1 = locked
    DoorSystemSetDoorState(DoorHash(roomId), IsLocked(roomId) and 1 or 0, false, false)
end

local function RegisterDoors()
    for roomId, room in pairs(S.cache) do
        local hash = DoorHash(roomId)
        if not IsDoorRegisteredWithSystem(hash) then
            AddDoorToSystem(hash, Rooms.DoorModel, room.door.x, room.door.y, room.door.z, false, false, false)
        end
    end
    DoorsReady = true
    for roomId in pairs(S.cache) do ApplyDoor(roomId) end
end

---------------------------------------------------------------------------------------------------
-- Text UI (door prompt has priority over the room prompt)
---------------------------------------------------------------------------------------------------

local function DoorLabel(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    if not st then return ('[E] %s - vacant'):format(room.label) end
    return ('[E] %s - %s'):format(room.label, st.locked and 'locked' or 'unlocked')
end

local function RefreshTextUI()
    if CurrentDoor then
        lib.showTextUI(DoorLabel(CurrentDoor))
    elseif InsideRoom then
        lib.showTextUI('[E] ' .. S.cache[InsideRoom].label .. ' menu')
    else
        lib.hideTextUI()
    end
end

---------------------------------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------------------------------

local OpenRoomMenu

local function OpenKeysMenu(roomId)
    local holders = lib.callback.await('wiwang:getKeyHolders', false) or {}
    local options = {
        {
            title = 'Give a key',
            description = 'Enter the server id of the player',
            icon = 'plus',
            onSelect = function()
                local input = lib.inputDialog('Give key to', { { type = 'number', label = 'Player server id', required = true, min = 1 } })
                if input and input[1] then TriggerServerEvent('wiwang:server:giveKey', input[1]) end
            end,
        },
    }
    for i = 1, #holders do
        local h = holders[i]
        options[#options + 1] = {
            title = h.name,
            description = 'Select to take this key back',
            icon = 'key',
            onSelect = function()
                TriggerServerEvent('wiwang:server:removeKey', h.citizenid)
            end,
        }
    end
    lib.registerContext({ id = 'wiwang_keys', title = S.cache[roomId].label .. ' - keys', menu = 'wiwang_room', options = options })
    lib.showContext('wiwang_keys')
end

OpenRoomMenu = function(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    local isOwner = S.mine ~= nil and S.mine.id == roomId
    local options = {
        { title = 'Stash', icon = 'box-open', onSelect = function() TriggerServerEvent('wiwang:server:openStash', roomId) end },
        { title = 'Wardrobe', icon = 'shirt', onSelect = function() TriggerEvent(Wiwang.OutfitEvent) end },
        {
            title = (st and st.locked) and 'Unlock door' or 'Lock door',
            icon = (st and st.locked) and 'lock-open' or 'lock',
            onSelect = function() TriggerServerEvent('wiwang:server:setLock', roomId, not (st and st.locked)) end,
        },
    }
    if isOwner then
        options[#options + 1] = { title = 'Keys', description = 'Give or take back keys', icon = 'key', onSelect = function() OpenKeysMenu(roomId) end }
        if Wiwang.AllowFurnitureEditing then
            options[#options + 1] = { title = 'Furniture', description = 'Add, remove or reset props', icon = 'couch', onSelect = function() WiwangClient.OpenFurnitureMenu(roomId) end }
        end
        options[#options + 1] = {
            title = 'Log out',
            description = 'Back to character selection',
            icon = 'right-from-bracket',
            onSelect = function()
                local ok = lib.alertDialog({ header = 'Log out', content = 'Go back to character selection?', centered = true, cancel = true })
                if ok == 'confirm' then TriggerServerEvent('wiwang:server:logout') end
            end,
        }
    end
    lib.registerContext({ id = 'wiwang_room', title = room.label .. ' - floor ' .. room.floor, options = options })
    lib.showContext('wiwang_room')
end

local function OpenDoorMenu(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    local options = {}
    if st then
        if S.access[roomId] then
            options[#options + 1] = {
                title = st.locked and 'Unlock door' or 'Lock door',
                icon = st.locked and 'lock-open' or 'lock',
                onSelect = function() TriggerServerEvent('wiwang:server:setLock', roomId, not st.locked) end,
            }
            options[#options + 1] = { title = 'Room menu', icon = 'house', onSelect = function() OpenRoomMenu(roomId) end }
        else
            options[#options + 1] = { title = 'Knock', icon = 'hand', onSelect = function() TriggerServerEvent('wiwang:server:knock', roomId) end }
        end
    else
        options[#options + 1] = { title = 'Vacant', description = 'Nobody lives here yet', icon = 'door-open', disabled = true }
    end
    lib.registerContext({ id = 'wiwang_door', title = room.label .. ' - floor ' .. room.floor, options = options })
    lib.showContext('wiwang_door')
end

---------------------------------------------------------------------------------------------------
-- Door interaction points (one per room, ox_lib only checks them every few hundred ms)
---------------------------------------------------------------------------------------------------

local function DoorEnter(self)
    CurrentDoor = self.roomId
    RefreshTextUI()
end

local function DoorExit(self)
    if CurrentDoor == self.roomId then CurrentDoor = nil end
    RefreshTextUI()
end

local function DoorNearby(self)
    if IsControlJustReleased(0, Wiwang.InteractKey) then
        OpenDoorMenu(self.roomId)
    end
end

for roomId, room in pairs(S.cache) do
    lib.points.new({
        coords = room.door,
        distance = 1.5,
        roomId = roomId,
        onEnter = DoorEnter,
        onExit = DoorExit,
        nearby = DoorNearby,
    })
end

---------------------------------------------------------------------------------------------------
-- Zones for the rooms I can access (room menu + "inside" metadata)
---------------------------------------------------------------------------------------------------

local function ZoneEnter(self)
    InsideRoom = self.roomId
    RefreshTextUI()
    if S.mine and S.mine.id == self.roomId then
        TriggerServerEvent('qb-apartments:server:SetInsideMeta', Wiwang.ApartmentType, self.roomId, true, false)
    end
end

local function ZoneExit(self)
    if InsideRoom == self.roomId then InsideRoom = nil end
    RefreshTextUI()
    if S.mine and S.mine.id == self.roomId then
        TriggerServerEvent('qb-apartments:server:SetInsideMeta', Wiwang.ApartmentType, self.roomId, false, false)
    end
end

local function ZoneInside(self)
    if not CurrentDoor and IsControlJustReleased(0, Wiwang.InteractKey) then
        OpenRoomMenu(self.roomId)
    end
end

local function RebuildZones()
    for _, zone in pairs(Zones) do zone:remove() end
    Zones = {}
    InsideRoom = nil
    for roomId in pairs(S.access) do
        local room = S.cache[roomId]
        if room then
            local size = room.bbMax - room.bbMin
            Zones[roomId] = lib.zones.box({
                coords = (room.bbMin + room.bbMax) / 2,
                size = vec3(size.x, size.y, size.z + 0.5),
                rotation = 0,
                roomId = roomId,
                onEnter = ZoneEnter,
                onExit = ZoneExit,
                inside = ZoneInside,
            })
        end
    end
    RefreshTextUI()
end

---------------------------------------------------------------------------------------------------
-- Blip / teleport
---------------------------------------------------------------------------------------------------

local function UpdateBlip()
    if HomeBlip then
        RemoveBlip(HomeBlip)
        HomeBlip = nil
    end
    local loc = Apartments.Locations[Wiwang.ApartmentType]
    if not loc then return end
    local c = loc.coords.enter
    HomeBlip = AddBlipForCoord(c.x, c.y, c.z)
    SetBlipSprite(HomeBlip, Wiwang.Blip.sprite)
    SetBlipDisplay(HomeBlip, 4)
    SetBlipScale(HomeBlip, Wiwang.Blip.scale)
    SetBlipColour(HomeBlip, Wiwang.Blip.colour)
    SetBlipAsShortRange(HomeBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(S.mine and (loc.label .. ' - ' .. S.mine.label) or loc.label)
    EndTextCommandSetBlipName(HomeBlip)
end

--- teleport into a room (used for first spawn / last location)
local function EnterRoom(roomId)
    local room = S.cache[roomId]
    if not room then return end
    local ped = PlayerPedId()
    DoScreenFadeOut(500)
    Wait(500)
    SetEntityCoords(ped, room.spawn.x, room.spawn.y, room.spawn.z, false, false, false, false)
    SetEntityHeading(ped, room.spawn.w)
    local timeout = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < timeout do Wait(50) end
    Wait(500)
    FreezeEntityPosition(ped, false)
    TriggerServerEvent('qb-apartments:returnBucket')
    DoScreenFadeIn(500)
end

---------------------------------------------------------------------------------------------------
-- State from the server
---------------------------------------------------------------------------------------------------

local function Init()
    local rooms, mine, access = lib.callback.await('wiwang:getState', false)
    S.rooms = rooms or {}
    S.mine = mine or nil
    S.access = access or {}
    if not DoorsReady then RegisterDoors() else for roomId in pairs(S.cache) do ApplyDoor(roomId) end end
    RebuildZones()
    UpdateBlip()
    WiwangClient.DespawnAll()
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', Init)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    S.mine = nil
    S.access = {}
    RebuildZones()
    UpdateBlip()
end)

RegisterNetEvent('wiwang:client:setApartment', function(mine, access)
    S.mine = mine or nil
    S.access = access or {}
    RebuildZones()
    UpdateBlip()
end)

RegisterNetEvent('wiwang:client:setAccess', function(access)
    S.access = access or {}
    RebuildZones()
end)

RegisterNetEvent('wiwang:client:roomState', function(roomId, state)
    S.rooms[roomId] = state or nil
    ApplyDoor(roomId)
    WiwangClient.Dirty(roomId)
    RefreshTextUI()
end)

RegisterNetEvent('wiwang:client:lockState', function(roomId, locked)
    local st = S.rooms[roomId]
    if st then st.locked = locked end
    if S.mine and S.mine.id == roomId then S.mine.locked = locked end
    ApplyDoor(roomId)
    RefreshTextUI()
end)

RegisterNetEvent('wiwang:client:furniture', function(roomId, list)
    local st = S.rooms[roomId]
    if st then st.furniture = list or nil end
    if S.mine and S.mine.id == roomId then S.mine.furniture = list or nil end
    WiwangClient.Dirty(roomId)
end)

RegisterNetEvent('wiwang:client:openOldStash', function(stash, data)
    TriggerEvent('inventory:client:SetCurrentStash', stash)
    TriggerServerEvent('inventory:server:OpenInventory', 'stash', stash, data)
end)

RegisterNetEvent('wiwang:client:showRoom', function(mine)
    local loc = Apartments.Locations[Wiwang.ApartmentType]
    SetNewWaypoint(loc.coords.enter.x, loc.coords.enter.y)
    lib.notify({
        title = 'Wiwang Hotel',
        description = ('%s on floor %d. Take the elevator in the lobby (waypoint set).'):format(mine.label, mine.floor),
        type = 'inform',
        duration = 8000,
    })
end)

---------------------------------------------------------------------------------------------------
-- qb-apartments compatible client events (qb-spawn / qb-multicharacter / qb-target menus)
---------------------------------------------------------------------------------------------------

RegisterNetEvent('apartments:client:setupSpawnUI', function(cData)
    QBCore.Functions.TriggerCallback('apartments:GetOwnedApartment', function(result)
        if result then
            TriggerEvent('qb-spawn:client:setupSpawns', cData, false, nil)
            TriggerEvent('qb-spawn:client:openUI', true)
            TriggerEvent('apartments:client:SetHomeBlip', result.type)
        elseif Apartments.Starting then
            TriggerEvent('qb-spawn:client:setupSpawns', cData, true, Apartments.Locations)
            TriggerEvent('qb-spawn:client:openUI', true)
        else
            TriggerEvent('qb-spawn:client:setupSpawns', cData, false, nil)
            TriggerEvent('qb-spawn:client:openUI', true)
        end
    end, cData.citizenid)
end)

RegisterNetEvent('apartments:client:SpawnInApartment', function(roomId)
    EnterRoom(roomId)
end)

RegisterNetEvent('qb-apartments:client:LastLocationHouse', function(_, roomId)
    if roomId and S.cache[roomId] then EnterRoom(roomId) end
end)

RegisterNetEvent('apartments:client:SetHomeBlip', function()
    UpdateBlip()
end)

RegisterNetEvent('apartments:client:OpenStash', function()
    if InsideRoom then TriggerServerEvent('wiwang:server:openStash', InsideRoom) end
end)

RegisterNetEvent('apartments:client:ChangeOutfit', function()
    TriggerEvent(Wiwang.OutfitEvent)
end)

RegisterNetEvent('apartments:client:Logout', function()
    TriggerServerEvent('wiwang:server:logout')
end)

RegisterCommand('roomfurni', function()
    if S.mine and InsideRoom == S.mine.id and Wiwang.AllowFurnitureEditing then
        WiwangClient.OpenFurnitureMenu(S.mine.id)
    else
        lib.notify({ type = 'error', description = 'Stand inside your own room first' })
    end
end, false)

---------------------------------------------------------------------------------------------------
-- Start / stop
---------------------------------------------------------------------------------------------------

CreateThread(function()
    Wait(0) -- let client/furniture.lua load first
    RegisterDoors()
    if LocalPlayer.state.isLoggedIn then Init() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for roomId in pairs(S.cache) do RemoveDoorFromSystem(DoorHash(roomId)) end
    for _, zone in pairs(Zones) do zone:remove() end
    lib.hideTextUI()
    if HomeBlip then RemoveBlip(HomeBlip) end
    WiwangClient.DespawnAll()
end)
