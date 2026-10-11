fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Floky (map) / Wiwang apartments integration'
description 'Wiwang Hotel apartments - qb-apartments style room assignment for the walkable MLO (380 real rooms, proximity-rendered furniture)'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/rooms.lua',
}

client_scripts {
    'client/main.lua',
    'client/furniture.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qb-core',
    'map_wiwang_hotel',
}
