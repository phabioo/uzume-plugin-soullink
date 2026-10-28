-- v0.6.0: region map from the game files (candidates of pokemon-core), source choice in the Map tab. Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local maps = require("app.maps")

local SIG = "\137PNG\r\n\26\n"
local function png(w, h) return SIG .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4I4", w, h) .. string.rep("\0", 8) end
local GAME = "000400000011C400"

local function world_maps(o)
  o = o or {}
  return { scan = o.scan or 0, selected = o.selected,
    list = o.list or { { id = "/a/0/6/7#1", w = 400, h = 240 }, { id = "/a/0/6/8#2", w = 320, h = 240 }, { id = "/a/2/4/8#3", w = 512, h = 256 } },
    images = o.images or { ["/a/0/6/7#1"] = png(400, 240), ["/a/0/6/8#2"] = png(320, 240), ["/a/2/4/8#3"] = png(512, 256) } }
end

local function boot(o)
  o = o or {}
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = GAME, language = "en" }, video = true })
  local core = fake_core.new(o.world)
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, app = app }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.act(a, v) m.action(a, v, "panel"); env.step(300) end
  function env.find(id) return ui_validator.find(m.ui.trees.screen, id) end
  function env.take(w, h)
    env.act("map_capture")
    m.video_result(true, png(w, h), w, h)
    env.step(300)
  end
  return env
end

local function open_files(e)
  e.step(); e.step(3100)
  e.act("tab", 2)
  e.act("map_src:files")
end

t.case("files: the source switch offers both sources and the scan state is shown while the core still searches", function()
  local e = boot({ world = { maps = world_maps({ scan = 2 }) } })
  e.step(); e.act("tab", 2)
  t.ok(e.find("msrc-screen") and e.find("msrc-files"), "both sources offered")
  t.ok(e.find("map-take"), "screen is the default")
  t.eq(e.find("mf-wait"), nil)
  e.act("map_src:files")
  t.eq(e.find("msrc-files").selected, true)
  t.ok(e.find("mf-wait").text:find("Still searching", 1, true), "still searching")
  t.eq(e.find("map-take"), nil)
  e.step(3100)
  t.ok(e.find("mf-wait"), "second ask is still not ready")
  e.step(3100)
  t.eq(e.find("mf-wait"), nil, "list arrived")
  t.eq(e.find("mf-pos").text, "Image 1 of 3 · 400 × 240 px")
  e.act("map_src:screen")
  t.ok(e.find("map-take") and e.find("mf-pos") == nil, "back to the screen source")
end)

t.case("files: browse with previous / next (wrapping), preview from the cache, suggested image marked", function()
  local e = boot({ world = { maps = world_maps({ selected = "/a/0/6/8#2" }) } })
  open_files(e)
  t.eq(e.find("mf-img").src, "cache:map/cand-1.png")
  t.eq(e.m.cache_files["map/cand-1.png"], png(400, 240))
  t.eq(e.find("mf-sug"), nil)
  e.act("map_next")
  t.eq(e.find("mf-pos").text, "Image 2 of 3 · 320 × 240 px")
  t.ok(e.find("mf-sug"), "the core's own pick is marked")
  t.eq(e.find("mf-img").src, "cache:map/cand-2.png")
  e.act("map_next"); e.act("map_next")
  t.eq(e.find("mf-pos").text, "Image 1 of 3 · 400 × 240 px", "wraps around")
  e.act("map_prev")
  t.eq(e.find("mf-pos").text, "Image 3 of 3 · 512 × 256 px", "previous wraps too")
  t.eq(e.app.maps.state, "none", "browsing does not change the map")
end)

t.case("files: Use this map stores it per game, keeps positions rescaled and survives a restart", function()
  local e = boot({ world = { maps = world_maps() } })
  e.step(); e.step(3100)
  e.take(320, 240)
  e.act("calib_toggle"); e.act("calib_route", "loc:302")
  e.app.ui.calib.x, e.app.ui.calib.y = 160, 120
  e.act("calib_set"); e.act("calib_toggle")
  e.act("tab", 1)
  e.act("map_src:files")
  t.eq(e.find("map").image_w, 320)
  e.act("map_next"); e.act("map_next") -- 512 x 256
  e.act("map_use")
  local map = e.find("map")
  t.eq(map.image_w, 512); t.eq(map.image_h, 256)
  t.eq(e.m.cache_files["map/" .. GAME .. ".png"], png(512, 256))
  t.eq(e.m.cache_files["map/current.txt"], GAME)
  t.eq(map.routes[1].x, 256); t.eq(map.routes[1].y, 128, "screen fraction kept")
  t.eq(e.m.cache_files["map/coords.json"],
    '{"crop":{"b":0,"l":0,"r":0,"t":0},"file":"/a/2/4/8#3","map":"' .. GAME .. '","routes":{"loc:302":{"x":256,"y":128}},"source":"files"}')
  t.ok(e.find("mf-cur"), "marked as the map in use")
  t.eq(e.find("mf-use"), nil)
  t.eq(e.app.maps:view().source, "files")
  -- restart: source and file are restored
  local m2 = mock.new({ run = { current = B.run({ "Lena", "Jonas" }) }, game = { code = GAME, language = "en" }, video = true })
  for k, v in pairs(e.m.cache_files) do m2.cache_files[k] = v end
  local mp = maps.new(m2.uz, true)
  t.eq(mp.state, "ready"); t.eq(mp.source, "files"); t.eq(mp.file_id, "/a/2/4/8#3"); t.eq(mp.w, 512)
  -- taking the map from the screen again switches the source back and rescales to the screen crop
  e.act("map_src:screen")
  e.take(320, 240)
  t.eq(e.app.maps.source, "screen")
  t.eq(e.m.cache_files["map/coords.json"],
    '{"crop":{"b":0,"l":0,"r":0,"t":0},"map":"' .. GAME .. '","routes":{"loc:302":{"x":160,"y":120}}}')
end)

t.case("files: removing a map from the game files forgets the source but keeps the positions", function()
  local e = boot({ world = { maps = world_maps() } })
  open_files(e)
  e.act("map_use")
  e.app.ui.calib = { step = 10 }
  e.act("calib_route", "loc:302"); e.act("calib_set")
  e.act("map_remove")
  t.eq(e.app.maps.state, "none")
  t.eq(e.app.maps.source, nil)
  t.ok(e.m.cache_files["map/coords.json"]:find('"loc:302"', 1, true))
  t.eq(e.m.cache_files["map/coords.json"]:find("files", 1, true), nil)
end)

t.case("files: a preview that cannot be made and an empty list are reported", function()
  local e = boot({ world = { maps = world_maps({ images = {} }) } })
  open_files(e)
  t.eq(e.find("mf-load").text, "This image could not be shown. Try the next one.")
  t.eq(e.find("mf-use"), nil, "nothing to use without a preview")
  e.act("map_use")
  t.eq(e.app.maps.state, "none")
  local e2 = boot({ world = { maps = world_maps({ list = {} }) } })
  open_files(e2)
  t.ok(e2.find("mf-none"))
end)

t.case("files: not_ready for an image is retried", function()
  local imgs = {}
  local e = boot({ world = { maps = world_maps({ images = imgs }) } })
  local n = 0
  e.core.provider.map_image = function(id)
    n = n + 1
    if n < 3 then return nil, "not_ready" end
    return png(400, 240)
  end
  open_files(e)
  t.eq(e.find("mf-img"), nil)
  t.eq(e.find("mf-load").text, "Loading the preview…")
  e.step(2100); e.step(2100)
  t.ok(e.find("mf-img"))
end)

t.case("files: a core without the map functions hides the option", function()
  local e = boot() -- the fake core has no map_candidates
  e.step(); e.step(3100)
  e.act("tab", 2)
  t.eq(e.find("msrc-files"), nil)
  t.eq(e.find("msrc-screen"), nil, "no switch with one source")
  t.ok(e.find("map-take"), "the screen source works as before")
  e.act("map_src:files")
  t.eq(e.find("mf-pos"), nil); t.eq(e.find("mf-wait"), nil)
  t.ok(e.find("map-take"))
  e.act("map_use"); e.act("map_next")
  t.eq(e.app.maps.state, "none")
  t.eq(e.app.maps.files.state, "unsupported")
  -- "unsupported" from the core is permanent too
  local e2 = boot({ world = { maps = world_maps() } })
  e2.core:off("map_candidates", "unsupported")
  e2.step(); e2.step(3100)
  e2.act("tab", 2)
  t.eq(e2.find("msrc-files"), nil)
  local calls = e2.core.world.calls.map_candidates
  e2.step(10000); e2.step(10000)
  t.eq(e2.core.world.calls.map_candidates, calls, "not asked again")
end)

t.case("files: without the game picture API the files source is the only one", function()
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = GAME, language = "en" } })
  m.set_provider("pokemon.core", fake_core.new({ maps = world_maps() }).provider)
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(1); m.advance(3100); m.tick(1)
  m.action("tab", 2, "panel"); m.advance(300); m.tick(1)
  t.eq(ui_validator.find(m.ui.trees.screen, "msrc-screen"), nil)
  t.ok(ui_validator.find(m.ui.trees.screen, "mf-pos"), "chooser shown directly")
  t.eq(ui_validator.find(m.ui.trees.screen, "map-take"), nil)
end)

t.case("files: the shell run view makes no core calls for maps", function()
  local run = B.run({ "Lena", "Jonas" })
  run.view = true
  local m = mock.new({ run = { current = run }, game = { code = GAME, language = "en" }, video = true })
  local core = fake_core.new({ maps = world_maps() })
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  m.advance(4000); m.tick(1); m.advance(4000); m.tick(1)
  t.eq(core.world.calls.map_candidates, nil)
end)
