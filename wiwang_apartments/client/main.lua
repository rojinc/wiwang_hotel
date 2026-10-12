--[[
    Wiwang Hotel apartments - client

    * door locks: native door system (this file) or delegated to ox_doorlock / qb-doorlock
    * doors: ox_target / qb-target options on the door model, or [E] prompts (ox_lib points), or a
      keybind when ox_doorlock owns the [E] prompt
    * inside a room you have access to: stash, wardrobe, keys, furniture, log out
    * reception desk in the lobby: check in, find your room, move out
    * qb-apartments compatible events so qb-spawn / qb-multicharacter can spawn you in your room
]]
local QBCore = exports['qb-core']:GetCoreObject()
local L = Wiwang.L

-- shared with client/furniture.lua (same Lua environment inside this resource)
WiwangClient = {
    rooms = {},     -- roomId -> { locked = bool, furniture = list|nil }  (assigned rooms only)
    cache = {},     -- roomId -> Rooms.Get() world data for all rooms
    mine = nil,     -- owner view of my own room (nil when I have none)
    access = {},    -- roomId -> true for every room I may open (own + keys)
    lockMode = 'native',
    target = 'none',
}
local S = WiwangClient

local DoorsReady = false
local StateLoaded = false
local DoorPoints = {}  -- lib.points for the door prompts
local ReceptionPoint
local DoorKeybind
local Zones = {}       -- roomId -> lib.zones.box (only rooms I can access)
local CurrentDoor      -- roomId of the door point I am standing at
local InsideRoom       -- roomId of the accessible room I am standing in
local AtReception = false
local HomeBlip
local InteractionReady = false

for floor = 1, Rooms.Floors do
    for number = 1, #Rooms.Template do
        local room = Rooms.Get(floor, number)
        S.cache[room.id] = room
    end
end

local running = Wiwang.Running

--- which key the door prompt should mention
local function DoorKeyLabel()
    if S.lockMode == 'native' then return Wiwang.InteractKeyLabel end
    local ok, key = pcall(function() return DoorKeybind and DoorKeybind:getCurrentKey() end)
    return ok and key and key ~= '' and key:upper() or Wiwang.DoorKeybind
end

---------------------------------------------------------------------------------------------------
-- Native door system (only when no door-lock resource owns the doors)
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
    if S.lockMode ~= 'native' then return end
    for roomId, room in pairs(S.cache) do
        local hash = DoorHash(roomId)
        if not IsDoorRegisteredWithSystem(hash) then
            AddDoorToSystem(hash, Rooms.DoorModel, room.door.x, room.door.y, room.door.z, false, false, false)
        end
    end
    DoorsReady = true
    for roomId in pairs(S.cache) do ApplyDoor(roomId) end
end

local function UnregisterDoors()
    if not DoorsReady then return end
    for roomId in pairs(S.cache) do RemoveDoorFromSystem(DoorHash(roomId)) end
    DoorsReady = false
end

---------------------------------------------------------------------------------------------------
-- Text UI (door prompt > reception > room prompt)
---------------------------------------------------------------------------------------------------

local function DoorLabel(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    return L('door_prompt', DoorKeyLabel(), room.label, st and L(st.locked and 'locked' or 'unlocked') or L('vacant'))
end

local function RefreshTextUI()
    if CurrentDoor then
        lib.showTextUI(DoorLabel(CurrentDoor))
    elseif AtReception then
        lib.showTextUI(L('reception_prompt', Wiwang.InteractKeyLabel))
    elseif InsideRoom then
        lib.showTextUI(L('room_menu_prompt', Wiwang.InteractKeyLabel, S.cache[InsideRoom].label))
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
            title = L('give_key'),
            description = L('give_key_desc'),
            icon = 'plus',
            onSelect = function()
                local input = lib.inputDialog(L('give_key'), { { type = 'number', label = L('player_id'), required = true, min = 1 } })
                if input and input[1] then TriggerServerEvent('wiwang:server:giveKey', input[1]) end
            end,
        },
    }
    for i = 1, #holders do
        local h = holders[i]
        options[#options + 1] = {
            title = h.name,
            description = L('take_key_desc'),
            icon = 'key',
            onSelect = function()
                TriggerServerEvent('wiwang:server:removeKey', h.citizenid)
            end,
        }
    end
    lib.registerContext({ id = 'wiwang_keys', title = S.cache[roomId].label .. ' - ' .. L('keys'), menu = 'wiwang_room', options = options })
    lib.showContext('wiwang_keys')
end

OpenRoomMenu = function(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    local isOwner = S.mine ~= nil and S.mine.id == roomId
    local locked = st and st.locked
    local options = {
        { title = L('stash'), icon = 'box-open', onSelect = function() TriggerServerEvent('wiwang:server:openStash', roomId) end },
        { title = L('wardrobe'), icon = 'shirt', onSelect = function() TriggerEvent(Wiwang.OutfitEvent) end },
        {
            title = L(locked and 'unlock_door' or 'lock_door'),
            icon = locked and 'lock-open' or 'lock',
            onSelect = function() TriggerServerEvent('wiwang:server:setLock', roomId, not locked) end,
        },
    }
    if isOwner then
        options[#options + 1] = { title = L('keys'), description = L('keys_desc'), icon = 'key', onSelect = function() OpenKeysMenu(roomId) end }
        if Wiwang.AllowFurnitureEditing then
            options[#options + 1] = { title = L('furniture'), description = L('furniture_desc'), icon = 'couch', onSelect = function() WiwangClient.OpenFurnitureMenu(roomId) end }
        end
        options[#options + 1] = {
            title = L('logout'),
            description = L('logout_desc'),
            icon = 'right-from-bracket',
            onSelect = function()
                local ok = lib.alertDialog({ header = L('logout'), content = L('logout_confirm'), centered = true, cancel = true })
                if ok == 'confirm' then TriggerServerEvent('wiwang:server:logout') end
            end,
        }
    end
    lib.registerContext({ id = 'wiwang_room', title = room.label .. ' - ' .. L('floor', room.floor), options = options })
    lib.showContext('wiwang_room')
end

local function OpenDoorMenu(roomId)
    local room = S.cache[roomId]
    local st = S.rooms[roomId]
    local options = {}
    if st then
        if S.access[roomId] then
            options[#options + 1] = {
                title = L(st.locked and 'unlock_door' or 'lock_door'),
                icon = st.locked and 'lock-open' or 'lock',
                onSelect = function() TriggerServerEvent('wiwang:server:setLock', roomId, not st.locked) end,
            }
            options[#options + 1] = { title = L('room_menu'), icon = 'house', onSelect = function() OpenRoomMenu(roomId) end }
        else
            options[#options + 1] = { title = L('knock'), icon = 'hand', onSelect = function() TriggerServerEvent('wiwang:server:knock', roomId) end }
        end
    else
        options[#options + 1] = { title = L('vacant_room'), description = L('vacant_room_desc'), icon = 'door-open', disabled = true }
    end
    lib.registerContext({ id = 'wiwang_door', title = room.label .. ' - ' .. L('floor', room.floor), options = options })
    lib.showContext('wiwang_door')
end

local function OpenReceptionMenu()
    local options = {}
    if S.mine then
        options[#options + 1] = {
            title = L('my_room'),
            description = L('my_room_desc', S.mine.label, S.mine.floor),
            icon = 'location-dot',
            onSelect = function() TriggerEvent('wiwang:client:showRoom', S.mine) end,
        }
        if Wiwang.AllowMoveOut then
            options[#options + 1] = {
                title = L('move_out'),
                description = L('move_out_desc', S.mine.label),
                icon = 'person-walking-arrow-right',
                onSelect = function()
                    local warning = Wiwang.ClearStashOnUnassign and L('move_out_stash_warning') or ''
                    local ok = lib.alertDialog({ header = L('move_out'), content = L('move_out_confirm', S.mine.label, warning), centered = true, cancel = true })
                    if ok == 'confirm' then TriggerServerEvent('wiwang:server:moveOut') end
                end,
            }
        end
    else
        options[#options + 1] = { title = L('check_in'), description = L('check_in_desc'), icon = 'bell-concierge', onSelect = function() TriggerServerEvent('wiwang:server:checkIn') end }
    end
    lib.registerContext({ id = 'wiwang_reception', title = L('hotel') .. ' - ' .. L('reception'), options = options })
    lib.showContext('wiwang_reception')
end

---------------------------------------------------------------------------------------------------
-- Door interaction: target options, [E] points, or a keybind
---------------------------------------------------------------------------------------------------

local function RoomFromEntity(entity)
    if not entity or entity == 0 then return nil end
    return Rooms.Nearest(GetEntityCoords(entity), 0.6)
end

local function ResolveTarget()
    local want = Wiwang.Target
    if want == 'auto' then
        return running('ox_target') and 'ox_target' or running('qb-target') and 'qb-target' or 'none'
    end
    if want ~= 'none' and not running(want) then return 'none' end
    return want
end

local function TargetOptions()
    local function access(entity) local r = RoomFromEntity(entity); return r and S.access[r.id] == true end
    local function assigned(entity) local r = RoomFromEntity(entity); return r and S.rooms[r.id] ~= nil end
    return {
        {
            name = 'wiwang_unlock', label = L('unlock_door'), icon = 'fa-solid fa-lock-open',
            canInteract = function(entity) local r = RoomFromEntity(entity); return r and S.access[r.id] and IsLocked(r.id) end,
            run = function(entity) local r = RoomFromEntity(entity); if r then TriggerServerEvent('wiwang:server:setLock', r.id, false) end end,
        },
        {
            name = 'wiwang_lock', label = L('lock_door'), icon = 'fa-solid fa-lock',
            canInteract = function(entity) local r = RoomFromEntity(entity); return r and S.access[r.id] and not IsLocked(r.id) end,
            run = function(entity) local r = RoomFromEntity(entity); if r then TriggerServerEvent('wiwang:server:setLock', r.id, true) end end,
        },
        {
            name = 'wiwang_menu', label = L('room_menu'), icon = 'fa-solid fa-house',
            canInteract = access,
            run = function(entity) local r = RoomFromEntity(entity); if r then OpenRoomMenu(r.id) end end,
        },
        {
            name = 'wiwang_knock', label = L('knock'), icon = 'fa-solid fa-hand',
            canInteract = function(entity) return assigned(entity) and not access(entity) end,
            run = function(entity) local r = RoomFromEntity(entity); if r then TriggerServerEvent('wiwang:server:knock', r.id) end end,
        },
    }
end

local function SetupTarget(kind)
    local opts = TargetOptions()
    if kind == 'ox_target' then
        local options = {}
        for i = 1, #opts do
            local o = opts[i]
            options[i] = { name = o.name, label = o.label, icon = o.icon, distance = 2.0, canInteract = o.canInteract, onSelect = function(data) o.run(data.entity) end }
        end
        exports.ox_target:addModel(Rooms.DoorModel, options)
    elseif kind == 'qb-target' then
        local options = {}
        for i = 1, #opts do
            local o = opts[i]
            options[i] = { label = o.label, icon = o.icon, canInteract = o.canInteract, action = o.run }
        end
        exports['qb-target']:AddTargetModel(Rooms.DoorModel, { options = options, distance = 2.0 })
    end
end

local function RemoveTarget(kind)
    if kind == 'ox_target' then
        pcall(function() exports.ox_target:removeModel(Rooms.DoorModel) end)
    elseif kind == 'qb-target' then
        pcall(function() exports['qb-target']:RemoveTargetModel(Rooms.DoorModel) end)
    end
end

local function DoorEnter(self)
    CurrentDoor = self.roomId
    RefreshTextUI()
end

local function DoorExit(self)
    if CurrentDoor == self.roomId then CurrentDoor = nil end
    RefreshTextUI()
end

--- [E] opens the door menu only in native mode; ox_doorlock / qb-doorlock use [E] themselves
local function DoorNearby(self)
    if S.lockMode == 'native' and IsControlJustReleased(0, Wiwang.InteractKey) then
        OpenDoorMenu(self.roomId)
    end
end

local function SetupDoorPoints()
    for roomId, room in pairs(S.cache) do
        DoorPoints[#DoorPoints + 1] = lib.points.new({
            coords = room.door,
            distance = 1.5,
            roomId = roomId,
            onEnter = DoorEnter,
            onExit = DoorExit,
            nearby = DoorNearby,
        })
    end
end

local function SetupDoorKeybind()
    if DoorKeybind then
        DoorKeybind:disable(false)
        return
    end
    DoorKeybind = lib.addKeybind({
        name = 'wiwang_door',
        description = L('keybind_door'),
        defaultKey = Wiwang.DoorKeybind,
        onPressed = function()
            if S.lockMode == 'native' then return end
            local room = Rooms.Nearest(GetEntityCoords(cache.ped), 1.8)
            if room then OpenDoorMenu(room.id) end
        end,
    })
end

local function SetupReception()
    local r = Wiwang.Reception
    if not r.enabled or ReceptionPoint then return end
    ReceptionPoint = lib.points.new({
        coords = r.coords,
        distance = r.distance,
        onEnter = function() AtReception = true; RefreshTextUI() end,
        onExit = function() AtReception = false; RefreshTextUI() end,
        nearby = function()
            if not CurrentDoor and IsControlJustReleased(0, Wiwang.InteractKey) then OpenReceptionMenu() end
        end,
    })
end

--- decide how doors are interacted with (needs the lock mode from the server); safe to call again
local function SetupInteraction()
    if InteractionReady then return end
    InteractionReady = true
    S.target = ResolveTarget()
    if S.target ~= 'none' then
        SetupTarget(S.target)
    else
        -- ox_doorlock shows its own text UI at the door, so only the other modes get a prompt
        if S.lockMode ~= 'ox_doorlock' then SetupDoorPoints() end
        -- ox_doorlock and qb-doorlock both use [E] at the door: our door menu moves to the keybind
        if S.lockMode ~= 'native' then SetupDoorKeybind() end
    end
    SetupReception()
end

local function TeardownInteraction()
    if not InteractionReady then return end
    InteractionReady = false
    for i = 1, #DoorPoints do DoorPoints[i]:remove() end
    DoorPoints = {}
    CurrentDoor = nil
    if DoorKeybind then DoorKeybind:disable(true) end
    RemoveTarget(S.target)
    S.target = 'none'
end

--- the server switched door-lock backend (a door-lock resource started after us)
local function ApplyLockMode(mode)
    if mode == S.lockMode then return end
    S.lockMode = mode
    if mode == 'native' then
        RegisterDoors()
    else
        UnregisterDoors()
    end
    TeardownInteraction()
    SetupInteraction()
    RefreshTextUI()
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
    if CurrentDoor or not IsControlJustReleased(0, Wiwang.InteractKey) then return end
    -- ox_doorlock toggles the lock with [E] near the door: keep the room menu away from it
    if S.lockMode == 'ox_doorlock' and #(GetEntityCoords(cache.ped) - S.cache[self.roomId].door) < 2.2 then return end
    OpenRoomMenu(self.roomId)
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
    local rooms, mine, access, lockMode = lib.callback.await('wiwang:getState', false)
    S.rooms = rooms or {}
    S.mine = mine or nil
    S.access = access or {}
    S.lockMode = lockMode or 'native'
    StateLoaded = true
    if S.lockMode == 'native' then
        if DoorsReady then for roomId in pairs(S.cache) do ApplyDoor(roomId) end else RegisterDoors() end
    else
        UnregisterDoors()
    end
    SetupInteraction()
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

RegisterNetEvent('wiwang:client:lockMode', function(mode)
    ApplyLockMode(mode)
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

--- someone knocked on my door: offer to open it for a while
RegisterNetEvent('wiwang:client:knock', function(roomId)
    local room = S.cache[roomId]
    if not room then return end
    local ok = lib.alertDialog({
        header = L('knock_title'),
        content = L('knock_body', room.label, Wiwang.KnockOpenTime),
        centered = true,
        cancel = true,
    })
    if ok == 'confirm' then TriggerServerEvent('wiwang:server:openForVisitor', roomId) end
end)

RegisterNetEvent('wiwang:client:showRoom', function(mine)
    local loc = Apartments.Locations[Wiwang.ApartmentType]
    SetNewWaypoint(loc.coords.enter.x, loc.coords.enter.y)
    lib.notify({ title = L('hotel'), description = L('room_hint', mine.label, mine.floor), type = 'inform', duration = 8000 })
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
    if not roomId or not S.cache[roomId] then return end
    local timeout = GetGameTimer() + 10000
    while not StateLoaded and GetGameTimer() < timeout do Wait(100) end
    if S.access[roomId] then EnterRoom(roomId) end -- the room may have changed hands since the last session
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
        lib.notify({ type = 'error', description = L('furni_not_inside') })
    end
end, false)

---------------------------------------------------------------------------------------------------
-- Exports / start / stop
---------------------------------------------------------------------------------------------------

exports('GetMyRoom', function() return S.mine end)
exports('GetRoomAt', function(coords) return Rooms.Nearest(coords or GetEntityCoords(cache.ped), 1.8) end)
exports('OpenRoomMenu', function(roomId) OpenRoomMenu(roomId) end)
exports('OpenDoorMenu', function(roomId) OpenDoorMenu(roomId) end)

CreateThread(function()
    Wait(0) -- let client/furniture.lua load first
    if LocalPlayer.state.isLoggedIn then Init() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    UnregisterDoors()
    TeardownInteraction()
    for _, zone in pairs(Zones) do zone:remove() end
    lib.hideTextUI()
    if HomeBlip then RemoveBlip(HomeBlip) end
    WiwangClient.DespawnAll()
end)
