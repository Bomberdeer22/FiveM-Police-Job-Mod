fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fk_spawn'
author 'FiveM Police Job Mod'
description 'Spawn manager: players wake up in Michael De Santa\'s bedroom. Staff can move the spawn point in game.'
version '0.1.2'

shared_scripts {
    'config.lua',
    'shared/spawns.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

dependencies {}
