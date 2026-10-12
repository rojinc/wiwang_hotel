--[[
    Wiwang Hotel apartments - proximity furniture renderer + owner editor

    Props are local, non-networked objects. Every client only spawns the rooms on ITS OWN floor
    within Wiwang.RenderDistance and deletes them again when it walks away or changes floor.
    Everybody nearby sees the same furniture because everybody spawns it from the same server data.
]]
local S = WiwangClient
local L = Wiwang.L

local Spawned = {}      -- roomId -> { object handles }
local CurrentFloor      -- floor the local player is currently on (nil = not in the hotel)

local function EffectiveList(roomId)
    local st = S.rooms[roomId]
    if not st then return nil end            -- vacant room: nothing to show
    return st.furniture or Wiwang.DefaultFurniture
end

local function Despawn(roomId)
    local objs = Spawned[roomId]
    if not objs then return end
    Spawned[roomId] = nil
    for i = 1, #objs do
        if DoesEntityExist(objs[i]) then DeleteObject(objs[i]) end
    end
end

local function Spawn(roomId, list)
    local room = S.cache[roomId]
    local objs = {}
    Spawned[roomId] = objs -- mark first so the next tick does not spawn it twice
    for i = 1, #list do
        local f = list[i]
        local model = type(f.model) == 'string' and joaat(f.model) or f.model
        if IsModelInCdimage(model) and IsModelValid(model) then
            local ok = pcall(lib.requestModel, model, 3000)
            if Spawned[roomId] ~= objs then return end -- despawned while we were loading the model
            if ok then
                local pos, heading = Rooms.ToWorld(room, f.x, f.y, f.z, f.h)
                local obj = CreateObjectNoOffset(model, pos.x, pos.y, pos.z, false, false, false)
                SetEntityHeading(obj, heading)
                FreezeEntityPosition(obj, true)
                SetModelAsNoLongerNeeded(model)
                objs[#objs + 1] = obj
            end
        end
    end
end

function WiwangClient.DespawnAll()
    for roomId in pairs(Spawned) do Despawn(roomId) end
end

--- furniture of this room changed: drop it, the loop below respawns it if it is still in range
function WiwangClient.Dirty(roomId)
    Despawn(roomId)
end

CreateThread(function()
    local maxDistSq = Wiwang.RenderDistance * Wiwang.RenderDistance
    while true do
        local coords = GetEntityCoords(cache.ped)
        local floor = Rooms.FloorAt(coords)
        if floor ~= CurrentFloor then
            WiwangClient.DespawnAll()
            CurrentFloor = floor
        end
        if floor then
            for number = 1, #Rooms.Template do
                local roomId = Rooms.RoomId(floor, number)
                local list = EffectiveList(roomId)
                local want = false
                if list and #list > 0 then
                    local c = S.cache[roomId].centre
                    local dx, dy = coords.x - c.x, coords.y - c.y
                    want = (dx * dx + dy * dy) < maxDistSq
                end
                if want and not Spawned[roomId] then
                    Spawn(roomId, list)
                elseif not want and Spawned[roomId] then
                    Despawn(roomId)
                end
            end
        end
        Wait(Wiwang.RenderInterval)
    end
end)

---------------------------------------------------------------------------------------------------
-- Owner editor (room menu -> Furniture, or /roomfurni inside your room)
---------------------------------------------------------------------------------------------------

function WiwangClient.OpenFurnitureMenu(roomId)
    local room = S.cache[roomId]
    local list = EffectiveList(roomId) or {}
    local options = {
        {
            title = L('furni_add'),
            description = L('furni_add_desc'),
            icon = 'plus',
            onSelect = function()
                local input = lib.inputDialog(L('furni_add'), {
                    { type = 'input', label = L('furni_model'), description = L('furni_model_desc'), required = true },
                    { type = 'number', label = L('furni_height'), default = 0, step = 0.05 },
                    { type = 'number', label = L('furni_rotate'), default = 0 },
                })
                if not input then return end
                local model = tostring(input[1])
                if not IsModelInCdimage(joaat(model)) then
                    return lib.notify({ type = 'error', description = L('furni_unknown', model) })
                end
                local ped = cache.ped
                local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 1.0, 0.0)
                local x, y, _, h = Rooms.ToLocal(room, vec3(pos.x, pos.y, room.centre.z), GetEntityHeading(ped))
                if math.abs(x) > 3.3 or math.abs(y) > 3.0 then
                    return lib.notify({ type = 'error', description = L('furni_outside') })
                end
                if #list >= Wiwang.MaxFurniture then
                    return lib.notify({ type = 'error', description = L('furni_full', Wiwang.MaxFurniture) })
                end
                local new = {}
                for i = 1, #list do new[i] = list[i] end
                new[#new + 1] = { model = model, x = x, y = y, z = tonumber(input[2]) or 0.0, h = (h + (tonumber(input[3]) or 0.0)) % 360.0 }
                TriggerServerEvent('wiwang:server:setFurniture', new)
            end,
        },
        {
            title = L('furni_remove'),
            icon = 'minus',
            onSelect = function()
                local ped = GetEntityCoords(cache.ped)
                local best, bestDist
                for i = 1, #list do
                    local pos = Rooms.ToWorld(room, list[i].x, list[i].y, list[i].z, 0.0)
                    local dist = #(ped - pos)
                    if dist < 3.0 and (not bestDist or dist < bestDist) then best, bestDist = i, dist end
                end
                if not best then return lib.notify({ type = 'error', description = L('furni_none_near') }) end
                local new = {}
                for i = 1, #list do
                    if i ~= best then new[#new + 1] = list[i] end
                end
                TriggerServerEvent('wiwang:server:setFurniture', new)
            end,
        },
        {
            title = L('furni_reset'),
            icon = 'rotate-left',
            onSelect = function() TriggerServerEvent('wiwang:server:resetFurniture') end,
        },
        { title = L('furni_count', #list, Wiwang.MaxFurniture), icon = 'couch', disabled = true },
    }
    lib.registerContext({ id = 'wiwang_furniture', title = room.label .. ' - ' .. L('furniture'), menu = 'wiwang_room', options = options })
    lib.showContext('wiwang_furniture')
end
