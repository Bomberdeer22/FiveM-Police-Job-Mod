fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fk_economy'
author 'FiveM Police Job Mod'
description 'Standalone cash/bank economy, on-screen money HUD, HUD customiser and staff money tools. Dependency for the police job mod.'
version '0.3.0'

shared_scripts {
    'config.lua',
    'shared/utils.lua',
    'shared/core.lua',
}

server_scripts {
    'server/accounts.lua',
    'server/player.lua',
    'server/staff.lua',
    'server/main.lua',
    'server/commands.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {}
