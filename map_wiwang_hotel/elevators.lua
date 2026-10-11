--- optional file for elevator functionality - can be removed if not needed
--- this file works in conjunction with ipl.lua to provide elevator functionality
local points = {}
local floors = {
    {
        coords = vec4(-819.82, -699.8, 28.07, 90.216),
        label = "Lobby",
    },
    {
        coords = vec4(-824.11, -717.47, 41.57, 223.66),
        label = "Floor 1",
    },
    {
        coords = vec4(-824.11, -717.47, 45.36, 221.24),
        label = "Floor 2",
    },
    {
        coords = vec4(-824.1, -717.47, 49.16, 221.29),
        label = "Floor 3",
    },
    {
        coords = vec4(-824.09, -717.47, 52.96, 221.34),
        label = "Floor 4",
    },
    {
        coords = vec4(-824.08, -717.47, 56.76, 221.75),
        label = "Floor 5",
    },
    {
        coords = vec4(-824.07, -717.48, 60.56, 220.95),
        label = "Floor 6",
    },
    {
        coords = vec4(-824.06, -717.48, 64.36, 221.71),
        label = "Floor 7",
    },
    {
        coords = vec4(-824.06, -717.48, 68.16, 221.38),
        label = "Floor 8",
    },
    {
        coords = vec4(-824.32, -717.23, 71.97, 223.36),
        label = "Floor 9",
    },
    {
        coords = vec4(-824.27, -717.32, 75.77, 221.08),
        label = "Floor 10",
    },
    {
        coords = vec4(-824.2, -717.39, 79.57, 220.42),
        label = "Floor 11",
    },
    {
        coords = vec4(-824.12, -717.46, 83.37, 223.31),
        label = "Floor 12",
    },
    {
        coords = vec4(-824.05, -717.53, 87.17, 219.96),
        label = "Floor 13",
    },
    {
        coords = vec4(-824.05, -717.54, 90.96, 219.93),
        label = "Floor 14",
    },
    {
        coords = vec4(-824.04, -717.54, 94.76, 220.04),
        label = "Floor 15",
    },
    {
        coords = vec4(-823.97, -717.61, 98.57, 219.73),
        label = "Floor 16",
    },
    {
        coords = vec4(-823.96, -717.62, 102.36, 219.9),
        label = "Floor 17",
    },
    {
        coords = vec4(-823.95, -717.62, 106.16, 220.07),
        label = "Floor 18",
    },
    {
        coords = vec4(-823.88, -717.69, 109.97, 219.83),
        label = "Floor 19",
    },
    {
        coords = vec4(-823.81, -717.77, 113.77, 218.5),
        label = "Floor 20",
    },
}

function onElevatorEnter(self)
    lib.showTextUI('[ E ] Elevator')
end
 
function onElevatorExit(self)
    lib.hideTextUI()
end
 
--- floor of the player's own apartment when wiwang_apartments (or its qb-apartments rename) is running
local function myRoom()
    for _, res in ipairs({ 'wiwang_apartments', 'qb-apartments' }) do
        if GetResourceState(res) == 'started' then
            local ok, room = pcall(function() return exports[res]:GetMyRoom() end)
            if ok and type(room) == 'table' then return room end
        end
    end
end

function ElevatorNearby(self)
    if self.currentDistance < self.distance and IsControlJustReleased(0, 38) then
        local elements = {}
        local pedcoords = GetEntityCoords(cache.ped)
        local room = myRoom()
        for i = 1, #floors do
            local floor = floors[i]
            local currentFloor = #(pedcoords - vec3(floor.coords.x, floor.coords.y, floor.coords.z)) < 1.0
            local mine = room and room.floor == i - 1 -- floors[1] is the lobby
            elements[#elements + 1] = {
                title = floor.label .. (mine and (' - ' .. room.label) or ''),
                description = currentFloor and 'You are here' or 'Go to ' .. floor.label,
                icon = mine and 'house' or nil,
                disabled = currentFloor,
                onSelect = function()
                    DoScreenFadeOut(800)
                    Wait(1000)
                    SetEntityCoords(cache.ped, floor.coords.x, floor.coords.y, floor.coords.z - 1.0, false, false, false, false)
                    SetEntityHeading(cache.ped, floor.coords.w)
                    Wait(500)
                    DoScreenFadeIn(800)
                end,
            }
        end
        if #elements <= 0 then return end 
        lib.registerContext({
            id = 'wiwang_menu',
            title = 'Elevator Menu',
            options = elements,
        })
        lib.showContext('wiwang_menu')
    end
end

for i = 1, #floors do
    local floor = floors[i]
    points[i] = lib.points.new({
        coords = floor.coords,
        distance = 1,
        onEnter = onElevatorEnter,
        onExit = onElevatorExit,
        nearby = ElevatorNearby,
        label = floor.label,
        teleport = floor.coords,
    })
end