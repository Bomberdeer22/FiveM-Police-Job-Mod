fx_version 'cerulean'
game 'gta5'

name 'fk_police'
author 'fk'
description 'LSPDFR-style police job for a single-player server: duty, station services, MDT, dispatch callouts, traffic stops, citations, arrests, jail, backup and rank progression.'
version '0.1.0'

dependencies {
    'fk_economy',
}

shared_scripts {
    'config.lua',
    'shared/core.lua',
    'shared/mdt.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/app.js',
    'html/style.css',
}
