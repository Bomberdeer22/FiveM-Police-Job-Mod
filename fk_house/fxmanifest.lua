fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fk_house'
author 'FiveM Police Job Mod'
description 'Interactive Michael De Santa mansion: wardrobe, kitchen, shower, bed, living room and a persistent personal vehicle in the garage.'
version '0.3.1'

shared_scripts {
    'config.lua',
    'shared/core.lua',
    'shared/house.lua',
    'shared/garage.lua',
}

server_scripts {
    'server/main.lua',
    'server/garage.lua',
}

client_scripts {
    'client/main.lua',
    'client/garage.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {}
