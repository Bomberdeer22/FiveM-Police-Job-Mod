--[[
    fk_boot — config.lua
    ---------------------------------------------------------------------------
    A big vehicle or map pack can take minutes to load. FiveM loads everything in
    server.cfg before the server answers on its HTTP port, and txAdmin restarts
    the server when a resource takes longer than its Resource Starting Tolerance
    (Settings -> FXServer -> Show Advanced, 1m30s by default):

        Resource "fk_house" failed to start within the 1m30s time limit

    Note that the resource named there is only the *last one txAdmin was told
    about* - a pack that blocks the boot never reports its own start, so the
    blame lands on the resource before it. Removing this pack from server.cfg is
    one fix; the other is to start it after the server is already up:

        # server.cfg
        # ensure military      <- remove this line
        ensure fk_boot         <- put this at the end of the file

    and list the pack below.
]]

Config = {}

Config.Deferred = {
    -- false: this resource does nothing at all (keep `ensure military` above).
    enabled = true,

    -- Resources to start *after* the boot sequence, in this order. Use the exact
    -- folder names, not the display names in `fxmanifest.lua`.
    packs = {
        -- 'military',
    },

    -- How long to wait after this resource starts before the first pack.
    -- This resource should be the last `ensure` line in server.cfg, so the wait
    -- begins once the rest of the boot has been handed off. Keep it generous
    -- (5-15 s): starting a pack while the server is still booting defeats the
    -- purpose.
    delay = 10000,

    -- Pause between two packs, so five heavy packs do not all load at once.
    gap = 2000,

    -- true: if a pack is already started (you left `ensure military` in the cfg,
    -- or another resource depends on it) leave it alone instead of restarting.
    skipIfStarted = true,

    -- true: print what is deferred and when it starts. Leave on; it is two lines.
    verbose = true,

    -- Hold new connections while the packs are still starting. A client that
    -- joins in the middle of a big resource download can sit on the loading
    -- screen at 100% for ever, because the files it is fetching keep changing.
    -- With this on, the loading screen shows "starting <pack>" instead and the
    -- player is let in as soon as the pack is up.
    gateJoins = true,

    -- Give up on the gate after this many seconds and let the player in with an
    -- explanation, so a broken pack cannot lock everybody out.
    gateTimeout = 300,
}

-- Shown in the startup banner. Nothing else reads this.
Config.PrintBanner = true
