-- v0.3: panel run view, creature icons, zone-based route detection, map setup and calibration.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local detect = require("model.detect")
local view_mod = require("model.view")
local oras = require("data.oras")
local util = require("model.util")

local SIG = "\137PNG\r\n\26\n"
local function png(w, h) return SIG .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4I4", w, h) .. string.rep("\0", 8) end

--- core: extra functions of the fake pokemon.core; opts.cache: files to start with.
local function boot(core, opts)
  opts = opts or {}
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" },
    video = (not opts.no_video) and (opts.video or true) or nil })
  for k, v in pairs(opts.cache or {}) do m.cache_files[k] = v end
  local world = { team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }) }, box = {} }
  local provider = {
    team = function() return world.team end,
    box_count = function() return 1 end,
    box = function() return world.box end,
  }
  for k, v in pairs(core or {}) do provider[k] = v end
  m.set_provider("pokemon.core", provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, world = world, app = app, run = run }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.act(a, v, slot) m.action(a, v, slot or "panel"); env.step(300) end
  function env.calls(fn)
    local n = 0
    for _, c in ipairs(m.calls) do if c.fn == fn then n = n + 1 end end
    return n
  end
  return env
end

t.case("icons: lazy fetch, cache, image blocks, no spam on failure", function()
  local seen = {}
  local e = boot({
    info = function() return { features = { icons = true } } end,
    icon = function(sp, form) seen[#seen + 1] = sp .. "/" .. tostring(form); return png(24, 24) end,
  })
  e.step(); e.step(); e.step()
  t.ok(e.m.cache_files["icons/900-0.png"], "written to the own cache")
  local img = ui_validator.find(e.m.ui.trees.panel, "m-i1")
  t.eq(img.src, "cache:icons/900-0.png")
  local n = #seen
  for _ = 1, 10 do e.step() end
  t.eq(#seen, n, "fetched once")

  -- not_ready is retried later, not on every tick
  local tries = 0
  local e2 = boot({ icon = function() tries = tries + 1; if tries < 3 then return nil, "not_ready" end; return png(8, 8) end })
  for _ = 1, 5 do e2.step(100) end
  t.eq(tries, 1, "waits before the retry")
  for _ = 1, 30 do e2.step(6000) end
  t.eq(tries, 3)
  t.ok(ui_validator.find(e2.m.ui.trees.panel, "m-i1"))

  -- unsupported: remembered, bounded number of calls
  local calls = 0
  local e3 = boot({ icon = function() calls = calls + 1; return nil, "unsupported" end })
  for _ = 1, 40 do e3.step(2000) end
  t.ok(calls <= 2, "one call per creature at most: " .. calls)
  t.ok(not ui_validator.find(e3.m.ui.trees.panel, "m-i1"))
  t.ok(ui_validator.find(e3.m.ui.trees.panel, "m-t1"), "text fallback")

  -- features.icons = false: no icon calls at all
  local c4 = 0
  local e4 = boot({ info = function() return { features = { icons = false } } end,
    icon = function() c4 = c4 + 1; return png(8, 8) end })
  for _ = 1, 20 do e4.step(2000) end
  t.eq(c4, 0)
end)

t.case("detect: manual place wins until the zone changes", function()
  local zones = { [7] = "route-104", [8] = "route-105" }
  local st = detect.diff(nil, { location = { zone = 7 } }, B.cfg(), { zones = zones })
  t.eq(st.place.key, "route-104")
  st = detect.set_place(st, "route-110", nil, 7)
  st = detect.diff(st, { location = { zone = 7 } }, B.cfg(), { zones = zones })
  t.eq(st.place.key, "route-110"); t.ok(st.place.manual)
  st = detect.diff(st, { location = { zone = 8 } }, B.cfg(), { zones = zones })
  t.eq(st.place.key, "route-105"); t.ok(not st.place.manual)
  -- unmapped zone after a manual place: the place is open, not kept
  st = detect.set_place(st, "route-110", nil, 8)
  st = detect.diff(st, { location = { zone = 99 } }, B.cfg(), { zones = zones })
  t.eq(st.place.key, nil); t.eq(st.place.zone, 99)
end)

t.case("zones: unmapped prompt, learned mapping, shared across players, auto catch", function()
  local loc = { zone = 7 }
  local e = boot({ location = function() return loc end })
  e.step(); e.step()
  t.ok(ui_validator.find(e.m.ui.trees.panel, "zone-new"), "asks which route this is")
  e.act("place_select", "route-104")
  t.eq(e.m.run.states["u-lena"].zones["7"], "route-104")
  t.ok(not ui_validator.find(e.m.ui.trees.panel, "zone-new"))
  -- not a route
  loc.zone = 8
  e.step(); e.step()
  t.ok(ui_validator.find(e.m.ui.trees.panel, "zone-new"))
  e.act("zone_none")
  t.eq(e.m.run.states["u-lena"].zones["8"], false)
  t.ok(not ui_validator.find(e.m.ui.trees.panel, "zone-new"))
  -- Jonas' answer for zone 9 is used for Lena without asking
  e.m.run.set_state_for("u-jonas", { v = 1, zones = { ["9"] = "route-102" } })
  t.eq(view_mod.merge_zones(e.run, e.m.run.states)[9], "route-102")
  loc.zone = 9
  e.step(); e.step()
  local st = e.m.run.states["u-lena"]
  t.eq(st.place.key, "route-102"); t.ok(not st.place.manual)
  t.ok(not ui_validator.find(e.m.ui.trees.panel, "zone-new"))
  -- the first catch lands on the route without any manual choice (box 1 -> new mon)
  e.world.box[1] = B.rec({ p = 0x77, sp = 12, nick = "Zippy", hp = 30 })
  for _ = 1, 3 do e.step(6000) end
  st = e.m.run.states["u-lena"]
  t.eq(st.mons["00000077"].route, "route-102")
  t.eq(st.routes["route-102"].status, "caught")
  -- the own mapping wins over another player's; static table wins over both
  e.m.run.set_state_for("u-jonas", { v = 1, zones = { ["7"] = "route-120" } })
  t.eq(view_mod.merge_zones(e.run, e.m.run.states)[7], "route-104")
  oras.ZONES[7] = "route-111"
  t.eq(view_mod.merge_zones(e.run, e.m.run.states)[7], "route-111")
  oras.ZONES[7] = nil
end)

t.case("location unsupported: manual picker, no repeated calls", function()
  local n = 0
  local e = boot({ location = function() n = n + 1; return nil, "unsupported" end })
  for _ = 1, 20 do e.step(600) end
  t.eq(n, 1)
  local p = e.m.ui.trees.panel
  t.ok(ui_validator.find(p, "place-toggle") and not ui_validator.find(p, "zone-new"), "quiet link")
  t.ok(not ui_validator.find(p, "place-picker"), "picker collapsed")
  e.act("place_toggle")
  t.ok(ui_validator.find(e.m.ui.trees.panel, "place-picker"), "picker after the click")
end)

local function take_map(e, w, h)
  e.act("tab", 2)
  e.act("map_capture")
  e.m.video_result(true, png(w or 320, h or 240), w or 320, h or 240)
  e.step(300)
  e.act("tab", 1)
end

t.case("map: capture from the bottom screen, calibration, retake keeps positions, remove", function()
  local e = boot()
  e.step()
  local p = e.m.ui.trees.screen
  t.ok(ui_validator.find(p, "tabs").tabs[1]:find("^Routes"), "Routes first until a map was taken")
  t.eq(ui_validator.find(p, "tabs").tabs[2], "Map")
  e.act("tab", 2)
  p = e.m.ui.trees.screen
  t.eq(ui_validator.find(p, "map"), nil, "no image before the capture")
  t.ok(ui_validator.find(p, "map-hint").text:find("PokéNav AreaNav", 1, true), "instruction")
  t.eq(ui_validator.find(p, "map-take").label, "Take map from screen")
  e.act("map_capture")
  t.eq(e.m.video.requests[1].target, { x = 40, y = 240, w = 320, h = 240 }, "default crop: the full bottom screen")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map-wait"), "waiting text")
  e.act("map_capture")
  t.eq(#e.m.video.requests, 1, "one pending request at a time")
  e.m.video_result(true, png(320, 240), 320, 240)
  e.step(300)
  t.eq(e.m.cache_files["map/000400000011C400.png"], png(320, 240))
  t.eq(ui_validator.find(e.m.ui.trees.screen, "tabs").tabs[1], "Map", "Map leads once taken")
  e.act("tab", 1)
  local map = ui_validator.find(e.m.ui.trees.screen, "map")
  t.eq(map.image, "cache:map/000400000011C400.png"); t.eq(map.image_w, 320); t.eq(map.image_h, 240)
  t.eq(#map.routes, 0, "markers only for routes with positions")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map-retake") and ui_validator.find(e.m.ui.trees.screen, "map-remove"))

  -- calibration
  e.act("calib_toggle")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "calib"))
  e.act("calib_route", "route-101")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map").players[1].id == "cursor", "cursor marker")
  t.eq(e.app.ui.calib.x, 160); t.eq(e.app.ui.calib.y, 120)
  e.act("calib_move", "r"); e.act("calib_move", "d")
  e.act("calib_step", 40); e.act("calib_move", "r")
  e.act("calib_step", 2); e.act("calib_move", "u")
  t.eq(e.app.ui.calib.x, 210); t.eq(e.app.ui.calib.y, 128)
  e.act("calib_step", 7) -- not one of 2/10/40
  t.eq(e.app.ui.calib.step, 2)
  e.act("calib_set")
  t.eq(e.m.cache_files["map/coords.json"], '{"crop":{"b":0,"l":0,"r":0,"t":0},"map":"000400000011C400","routes":{"route-101":{"x":210,"y":128}}}')
  map = ui_validator.find(e.m.ui.trees.screen, "map")
  t.eq(#map.routes, 1); t.eq(map.routes[1].id, "route-101"); t.eq(map.routes[1].x, 210)
  -- clamped to the image
  for _ = 1, 20 do e.act("calib_step", 40); e.act("calib_move", "l") end
  t.eq(e.app.ui.calib.x, 0)
  -- export: one Lua table line in the log
  e.act("calib_route", "route-102"); e.act("calib_set")
  e.act("calib_export")
  local line
  for _, l in ipairs(e.m.logs) do if l.text:find("soullink positions:", 1, true) then line = l.text end end
  t.eq(line, 'soullink positions: COORDS["000400000011C400"] = { ["route-101"] = { x = 210, y = 128 }, ["route-102"] = { x = 160, y = 120 } }')

  -- retake: new image, same positions (also when the size differs)
  e.act("calib_toggle")
  e.act("map_capture")
  t.eq(#e.m.video.requests, 2)
  e.m.video_result(true, png(400, 240), 400, 240)
  e.step(300)
  map = ui_validator.find(e.m.ui.trees.screen, "map")
  t.eq(map.image_w, 400); t.eq(#map.routes, 2, "positions kept after the retake")
  t.eq(e.m.cache_files["map/000400000011C400.png"], png(400, 240))

  -- a restart keeps image and positions without a capture
  local cache = util.copy(e.m.cache_files)
  local e2 = boot(nil, { cache = cache })
  e2.step()
  local m2 = ui_validator.find(e2.m.ui.trees.screen, "map")
  t.eq(m2.image, "cache:map/000400000011C400.png")
  t.eq(#m2.routes, 2)
  t.eq(#e2.m.video.requests, 0)
  -- baked-in COORDS are merged under the recorded ones
  oras.COORDS["000400000011C400"] = { ["route-103"] = { x = 5, y = 6, area = "w" }, ["route-101"] = { x = 1, y = 1 } }
  e2.act("calib_toggle"); e2.act("calib_toggle")
  m2 = ui_validator.find(e2.m.ui.trees.screen, "map")
  t.eq(#m2.routes, 3)
  oras.COORDS["000400000011C400"] = nil
  -- remove: image gone, positions stay, the capture offer is back
  e2.act("map_remove")
  t.eq(e2.m.cache_files["map/000400000011C400.png"], "")
  t.eq(ui_validator.find(e2.m.ui.trees.screen, "map"), nil)
  t.ok(ui_validator.find(e2.m.ui.trees.screen, "tabs").tabs[1]:find("^Routes"))
  t.ok(e2.m.cache_files["map/coords.json"]:find("route-101", 1, true), "positions stay")
  take_map(e2, 320, 240)
  t.eq(#ui_validator.find(e2.m.ui.trees.screen, "map").routes, 2, "positions apply to the next map")
end)

t.case("map: screens fall back to main, errors are shown per code", function()
  local e = boot(nil, { video = { screens = { { name = "main", x = 0, y = 0, w = 240, h = 160 } } } })
  e.step(); e.act("tab", 2)
  e.act("map_capture")
  t.eq(e.m.video.requests[1].target, { x = 0, y = 0, w = 240, h = 160 }, "main screen, full")
  local codes = { "busy", "rate_limited", "no_frame", "unknown_screen", "invalid_rect", "too_large", "unsupported", "denied", "weird" }
  for _, code in ipairs(codes) do
    e.m.video_result(code)
    e.step(300)
    local err = ui_validator.find(e.m.ui.trees.screen, "map-error")
    t.ok(err and err.text ~= "" and not err.text:find("map_err", 1, true), "message for " .. code)
    t.ok(ui_validator.find(e.m.ui.trees.screen, "map-take"), "button stays")
    t.eq(ui_validator.find(e.m.ui.trees.screen, "map"), nil)
    e.act("map_capture")
  end
  e.m.video_result("no_frame"); e.step(300)
  t.eq(ui_validator.find(e.m.ui.trees.screen, "map-error").text, "No game picture yet. Make sure the game runs and is not paused.")
  -- a broken PNG is an error, not a map
  e.act("map_capture"); e.m.video_result(true, "junk", 1, 1); e.step(300)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map-error"))
  t.eq(e.m.cache_files["map/000400000011C400.png"], nil)
  -- no screens (no game picture): no request
  local e2 = boot(nil, { video = { screens = false } })
  e2.step(); e2.act("tab", 2); e2.act("map_capture")
  t.eq(#e2.m.video.requests, 0)
  t.ok(ui_validator.find(e2.m.ui.trees.screen, "map-error"))
  -- capture raising a Lua error is caught
  local e3 = boot(nil, { video = { raise = true } })
  e3.step(); e3.act("tab", 2); e3.act("map_capture")
  t.ok(ui_validator.find(e3.m.ui.trees.screen, "map-error"))
end)

t.case("map: an older app without uz.video says so and nothing else breaks", function()
  local e = boot(nil, { no_video = true })
  e.step(); e.step()
  local p = e.m.ui.trees.screen
  t.ok(ui_validator.find(p, "tabs").tabs[1]:find("^Routes"))
  t.eq(ui_validator.find(p, "tabs").tabs[2], "Map")
  e.act("tab", 2)
  p = e.m.ui.trees.screen
  t.ok(ui_validator.find(p, "map-empty").text:find("Update Uzume", 1, true))
  t.eq(ui_validator.find(p, "map-take"), nil)
  e.act("map_capture") -- ignored
  e.act("tab", 3)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "page-team"))
end)

t.case("map icons and route markers", function()
  oras.COORDS["000400000011C400"] = { ["route-101"] = { x = 10, y = 20 } }
  local ok, err = pcall(function()
    local e = boot({
      icon = function() return png(8, 8) end,
    })
    e.act("place_select", "route-101")
    e.step(3100)
    e.world.box[1] = B.rec({ p = 0x77, sp = 12, nick = "Zippy", hp = 30 })
    for _ = 1, 4 do e.step(6000) end
    e.act("tab", 2); e.act("map_capture"); e.m.video_result(true, png(100, 80), 100, 80); e.step(300); e.act("tab", 1)
    local map = ui_validator.find(e.m.ui.trees.screen, "map")
    t.eq(map.routes[1].id, "route-101")
    t.eq(map.routes[1].icons[1].src, "cache:icons/12-0.png")
    t.eq(map.players[1].x, 10)
  end)
  oras.COORDS["000400000011C400"] = nil
  if not ok then error(err, 0) end
end)
