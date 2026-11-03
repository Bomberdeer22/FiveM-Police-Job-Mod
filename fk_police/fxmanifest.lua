fx_version 'cerulean'
game 'gta5'

name 'fk_police'
author 'fk'
description 'LSPDFR-style police job for a single-player server: duty, MDT, dispatch callouts, traffic stops, citations, arrests, jail, bail and court dates, backup, fines, warrants, BOLOs, reports, impound, pursuits, field work, a forensics lab, a stolen hotlist with ANPR, speed cameras, shifts and rank progression.'
version '0.4.0'

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
    'server/justice.lua',
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
