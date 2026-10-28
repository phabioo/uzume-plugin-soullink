-- v0.5.1: place picker lists every place, game data diagnostics, map crop. Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local maps = require("app.maps")
local common = require("ui.common")

local SIG = "\137PNG\r\n\26\n"
local function png(w, h) return SIG .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4I4", w, h) .. string.rep("\0", 8) end

local function boot(o)
  o = o or {}
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, video = true })
  local core = fake_core.new(o.world)
  if o.setup then o.setup(core) end
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

local function values(options)
  local out = {}
  for _, o in ipairs(options) do out[#out + 1] = o.value end
  return out
end

-- ---------------------------------------------------------------- 1. place picker

t.case("picker: every place of the game, towns included, current place preselected", function()
  local e = boot()
  e.step(); e.step(6000)
  e.take(250, 219)
  e.act("calib_toggle")
  local sel = e.find("calib-route")
  t.eq(values(sel.options), { "loc:400", "loc:301", "loc:401", "loc:302", "loc:303" }, "towns and caves too, no starter")
  t.eq(sel.selected, "loc:301", "current place preselected")
  t.eq(e.app.ui.calib.route, "loc:301")
  t.ok(e.find("calib-pos"), "cursor ready for the current place")
  -- moving into a town: the town is preselected the next time
  e.act("calib_toggle")
  e.core:go(400, "Synthetic Town")
  e.step(2000)
  e.act("calib_toggle")
  t.eq(e.find("calib-route").selected, "loc:400")
end)

t.case("picker: current place and areas appear even when locations() is missing", function()
  local e = boot({ setup = function(c) c:off("locations", "unsupported") end })
  e.step(); e.step(6000)
  e.take(250, 219)
  e.act("calib_toggle")
  t.eq(values(e.find("calib-route").options), { "loc:301", "loc:302", "loc:303" })
end)

t.case("picker: nothing known says so with a localized hint, never 'No place yet'", function()
  local e = boot({ world = { areas = {}, locations = {} }, setup = function(c)
    c:off("location", "not_ready"); c:off("areas", "not_ready"); c:off("locations", "not_ready") end })
  e.step(); e.step(6000)
  e.take(250, 219)
  e.act("calib_toggle")
  local sel = e.find("calib-route")
  t.eq(#sel.options, 1)
  t.eq(sel.options[1].label, "No places from the game yet")
  t.ok(sel.options[1].label ~= "No place yet")
end)

-- ---------------------------------------------------------------- 2. diagnostics

t.case("diagnostics: Game data block is closed by default, opened with the chip, one wrapped line per key group, state kept", function()
  local e = boot()
  e.step(); e.step(6000)
  local chip = e.find("diag-chip")
  t.ok(chip, "toggle present with a core that has diagnostics()")
  t.eq(chip.text, "Show game data", "clearly labelled")
  t.ok(not chip.selected)
  t.eq(e.find("diag-1"), nil, "closed by default")
  e.act("diag_toggle")
  t.eq(e.find("diag-chip").text, "Hide game data")
  t.eq(e.find("diag-chip").selected, true)
  -- groups by prefix: areas, first, ids, language, lines, locations, revision, text, zo, zone, zones
  local l1 = e.find("diag-1")
  t.ok(l1 and l1.wrap == true, "wrapped line")
  t.eq(l1.text, "areas=3")
  t.ok(e.find("diag-hint"))
  local found = {}
  for i = 1, 20 do local l = e.find("diag-" .. i); if l then found[#found + 1] = l.text end end
  local all = table.concat(found, " | ")
  t.ok(all:find("zone_files=3", 1, true) and all:find("zones_state=ready zones_with_encounters=40", 1, true), "every key shown")
  e.step(6000); e.step(6000)
  t.ok(e.find("diag-1"), "stays open across refreshes")
  e.act("diag_toggle")
  t.eq(e.find("diag-1"), nil, "closed")
  t.eq(e.find("diag-chip").text, "Show game data")
  e.step(6000); e.step(6000)
  t.eq(e.find("diag-1"), nil, "stays closed across refreshes")
end)

t.case("diagnostics: shown in the Routes tab while the place list is empty", function()
  local e = boot({ world = { areas = {}, locations = {} }, setup = function(c)
    c:off("areas", "not_ready"); c:off("locations", "not_ready") end })
  e.step(); e.step(6000)
  -- closed by default on the overview: the Routes tab shows it while no places are known
  t.ok(e.find("routes-diag-1"), "block in the Routes tab")
  e.core:on("areas"); e.core:on("locations")
  e.core.world.areas = { { id = 301, name = "Synthetic Area One", zones = { 10 }, encounters = {} } }
  e.core.world.locations = { { id = 301, name = "Synthetic Area One", zones = { 10 }, has_encounters = true } }
  e.step(6000); e.step(6000)
  t.eq(e.find("routes-diag-1"), nil, "gone once places are known")
end)

t.case("diagnostics: an older core without diagnostics() shows no block and no toggle", function()
  local e = boot({ world = { areas = {}, locations = {} }, setup = function(c)
    c:off("diagnostics", "unsupported"); c:off("areas", "not_ready"); c:off("locations", "not_ready") end })
  e.step(); e.step(6000)
  t.eq(e.find("diag-chip"), nil)
  t.eq(e.find("routes-diag-1"), nil)
  e.act("diag_toggle")
  t.eq(e.find("diag-1"), nil)
end)

t.case("diagnostics: every key is shown, grouped by prefix, sorted, strings cut", function()
  local lines = common.diag_lines({ b = 2, a = "x", c = string.rep("z", 100), d = true })
  t.eq(#lines, 4, "keys without a prefix are their own group")
  t.eq(lines[1], "a=x")
  t.ok(not table.concat(lines, " "):find(string.rep("z", 41), 1, true))
  t.eq(common.diag_lines(nil), {})
  local d, n = {}, 0
  for _, p in ipairs({ "icons", "icon_e1", "icon_e25", "icon_e700", "text", "personal", "zone" }) do
    for i = 1, 12 do d[p .. "_k" .. string.format("%02d", i)] = i; n = n + 1 end
  end
  d.text_first_rejection = "bad"; n = n + 1
  t.ok(n > 40)
  lines = common.diag_lines(d)
  -- the prefix is the text before the first "_": icons, icon, text, personal, zone
  t.eq(#lines, 5)
  t.ok(lines[1]:find("^icon_e1_k01=1 "), "sorted within the group")
  local joined = table.concat(lines, " ")
  local count = 0
  for _ in joined:gmatch("=") do count = count + 1 end
  t.eq(count, n, "no key dropped")
  t.ok(joined:find("text_first_rejection=bad", 1, true))
  t.eq(common.diag_lines({ "x" }), {}, "non-string keys are ignored")
end)

-- ---------------------------------------------------------------- 3. map crop

t.case("crop: capture rect inside the bottom screen, steppers and presets stay within limits", function()
  local sc = { name = "bottom", x = 40, y = 240, w = 320, h = 240 }
  t.eq(maps.crop_rect(sc, { t = 10, b = 0, l = 0, r = 25 }), { x = 40, y = 264, w = 240, h = 216 })
  t.eq(maps.crop_rect(sc, {}), { x = 40, y = 240, w = 320, h = 240 })
  local e = boot()
  e.step(); e.step(6000)
  e.act("tab", 2)
  e.act("crop_toggle")
  t.eq(e.find("crop-vt").text, "Top 0 %", "default crop = full screen")
  t.eq(e.find("crop-vr").text, "Right 0 %")
  t.eq(e.find("crop-suggest"), nil, "no estimated default any more")
  e.act("crop_adj", "t:5"); e.act("crop_adj", "r:5"); e.act("crop_adj", "l:1"); e.act("crop_adj", "r:-1")
  t.eq(e.app.maps.edit, { t = 5, b = 0, l = 1, r = 4 })
  for _ = 1, 20 do e.act("crop_adj", "b:5") end
  t.eq(e.app.maps.edit.b, 45, "limited to 45 percent")
  e.act("crop_adj", "q:5"); e.act("crop_adj", "t:x")
  e.act("crop_preset", "none")
  t.eq(e.app.maps.edit, { t = 0, b = 0, l = 0, r = 0 })
  e.act("crop_preset", "suggest")
  t.eq(e.app.maps.edit, { t = 0, b = 0, l = 0, r = 0 }, "unknown preset ignored")
  e.act("crop_adj", "t:10"); e.act("crop_adj", "r:5")
  e.act("map_capture")
  t.eq(e.m.video.requests[1].target, { x = 40, y = 264, w = 304, h = 216 }, "10 % top, 5 % right of the bottom screen")
  e.m.video_result(true, png(304, 216), 304, 216)
  e.step(300)
  t.ok(e.m.cache_files["map/coords.json"] == nil or e.m.cache_files["map/coords.json"]:find('"t":10', 1, true))
end)

t.case("crop: the first capture takes the full screen", function()
  local e = boot()
  e.step(); e.step(6000)
  e.act("tab", 2)
  e.act("map_capture")
  t.eq(e.m.video.requests[1].target, { x = 40, y = 240, w = 320, h = 240 })
end)

t.case("crop: Crop map is offered with the map and retaking with a new crop rescales positions", function()
  local e = boot()
  e.step(); e.step(6000)
  e.take(320, 240)
  e.act("tab", 1)
  t.ok(e.find("map-crop"), "Crop map offered after the capture")
  e.act("calib_toggle")
  e.act("calib_route", "loc:302")
  e.app.ui.calib.x, e.app.ui.calib.y = 160, 120
  e.act("calib_set")
  e.act("calib_toggle")
  e.act("crop_toggle")
  t.eq(e.app.maps.edit.t, 0, "edits start from the crop of the stored map")
  e.act("crop_adj", "t:10")
  t.ok(e.find("crop-apply") and e.find("crop-rescale"))
  e.act("map_capture")
  t.eq(e.m.video.requests[2].target, { x = 40, y = 264, w = 320, h = 216 }, "10 % off the top")
  e.m.video_result(true, png(320, 216), 320, 216)
  e.step(300)
  local c = e.app.maps:merged()["loc:302"]
  -- screen fraction (0.5, 0.5) stays: x = 0.5 * 320, y = (0.5 - 0.1) / 0.9 * 216
  t.eq(c.x, 160); t.eq(c.y, 96)
  t.eq(e.m.cache_files["map/coords.json"],
    '{"crop":{"b":0,"l":0,"r":0,"t":10},"map":"000400000011C400","routes":{"loc:302":{"x":160,"y":96}}}')
end)

t.case("crop: stored crop survives a restart, malformed values are cleaned", function()
  local e = boot()
  e.step(); e.step(6000)
  e.take(250, 219)
  local cache = {}
  for k, v in pairs(e.m.cache_files) do cache[k] = v end
  cache["map/coords.json"] = '{"crop":{"b":99,"l":3,"r":22,"t":9},"map":"000400000011C400","routes":{}}'
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, video = true })
  for k, v in pairs(cache) do m.cache_files[k] = v end
  local mp = maps.new(m.uz, true)
  t.eq(mp.crop, { t = 9, b = 45, l = 3, r = 22 })
  t.eq(mp.edit, mp.crop)
end)

-- ---------------------------------------------------------------- 4. lists are asked again

t.case("lists: not_ready, then empty, then a list fills the picker; unsupported stays permanent", function()
  local e = boot({ setup = function(c)
    c:off("areas", "not_ready"); c:off("locations", "not_ready"); c:off("location", "not_ready") end })
  e.step(); e.step(6000)
  e.take(250, 219)
  e.act("calib_toggle")
  t.eq(#e.find("calib-route").options, 1, "nothing yet")
  -- core answers an empty list (names still loading)
  local full_a, full_l = e.core.world.areas, e.core.world.locations
  e.core.world.areas, e.core.world.locations = {}, {}
  e.core:on("areas"); e.core:on("locations")
  e.step(6000); e.step(6000)
  t.eq(#e.find("calib-route").options, 1, "an empty list is not final")
  local asked = e.core.world.calls.locations
  e.step(6000)
  t.ok(e.core.world.calls.locations > asked, "asked again")
  -- the list arrives
  e.core.world.areas, e.core.world.locations = full_a, full_l
  e.step(6000); e.step(6000)
  t.eq(values(e.find("calib-route").options), { "loc:400", "loc:301", "loc:401", "loc:302", "loc:303" })
  -- a complete list is refreshed after 30 s
  table.insert(e.core.world.locations, { id = 402, name = "Synthetic Isle", zones = {}, has_encounters = false })
  e.step(6000); e.step(6000); e.step(6000); e.step(6000); e.step(6000); e.step(6000)
  t.ok(table.concat(values(e.find("calib-route").options), ","):find("loc:402", 1, true), "refreshed")
end)

t.case("lists: unsupported locations() is not asked again", function()
  local e = boot({ setup = function(c) c:off("locations", "unsupported") end })
  e.step(); e.step(6000); e.step(6000); e.step(6000)
  t.eq(e.core.world.calls.locations, 1)
end)

-- ---------------------------------------------------------------- 5. more than 100 places

t.case("picker: 250 places are grouped, current place and used places in the first group", function()
  local locs = {}
  for i = 1, 250 do locs[i] = { id = 1000 + i, name = "Synthetic Place " .. i, zones = {}, has_encounters = false } end
  local e = boot({ world = { locations = locs, areas = {},
      location = { zone = 5, location = 1200, name = "Synthetic Place 200", source = "memory" } } })
  e.step(); e.step(6000)
  e.take(250, 219)
  e.act("calib_toggle")
  local grp, sel = e.find("calib-group"), e.find("calib-route")
  t.ok(grp, "group select in front")
  t.eq(#grp.options, 3)
  t.eq(grp.options[1].label, "Places 1-90")
  t.ok(#sel.options <= 100)
  t.eq(sel.selected, "loc:1200", "current place preselected in the first group")
  local has = {}
  for _, o in ipairs(sel.options) do has[o.value] = true end
  t.ok(has["loc:1200"] and has["loc:1001"] and not has["loc:1150"])
  e.act("calib_group", 2)
  grp, sel = e.find("calib-group"), e.find("calib-route")
  t.eq(grp.selected, 2)
  t.ok(#sel.options <= 100 and #sel.options > 0)
  t.ok(sel.selected ~= "loc:1200" and e.app.ui.calib.x, "a place of the group is selected")
  e.act("calib_group", 9) -- ignored
  t.eq(e.find("calib-group").selected, 2)
  e.act("calib_route", sel.options[#sel.options].value)
  t.eq(e.find("calib-group").selected, 2, "stays in the group")
end)
