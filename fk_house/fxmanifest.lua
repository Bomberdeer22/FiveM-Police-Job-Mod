fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fk_house'
author 'FiveM Police Job Mod'
description 'Interactive Michael De Santa mansion: wardrobe, kitchen, shower, bed and living room.'
version '0.1.1'

shared_scripts {
    'config.lua',
    'shared/house.lua',
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
    'html/style.css',
    'html/app.js',
}

dependencies {}
