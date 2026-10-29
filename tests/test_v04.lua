-- v0.4: compact panel (5b), run screen opened with uz.ui.open, routes and detection from pokemon-core v0.3
-- (areas, encounters seq, live hp, badges, names, primary types). Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local view_mod = require("model.view")
local detect = require("model.detect")
local state_mod = require("model.state")
local oras = require("data.oras")
local util = require("model.util")

--- Run with Lena (me) and Jonas on the fake v0.3 core. o: settings, states, no_ui_open, core (override world)
local function boot(o)
  o = o or {}
  local run = B.run({ "Lena", "Jonas" })
  run.settings = B.no_balls_rule(o.settings)
  local m = mock.new({ run = { current = run, states = o.states }, game = { code = "000400000011C400", language = "en" },
    no_ui_open = o.no_ui_open, video = true })
  local core = fake_core.new(o.world)
  if o.setup then o.setup(core) end
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, world = core.world, app = app, run = run }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.full() env.step(6000) end
  function env.act(a, v, slot) m.action(a, v, slot or "panel"); env.step(300) end
  function env.state() return m.run.states["u-lena"] end
  function env.catch(p, sp, nick)
    core.world.box[#core.world.box + 1] = B.rec({ p = p, sp = sp, nick = nick, hp = 30 })
    env.full()
  end
  return env
end

local function count(tree)
  local n = 1
  for _, c in ipairs(tree.children or {}) do n = n + count(c) end
  return n
end

local function events_of(m, kind)
  local out = {}
  for _, ev in ipairs(m.run.events) do if ev.type == kind then out[#out + 1] = ev end end
  return out
end

local function texts(tree)
  local out = {}
  for _, b in ipairs(ui_validator.all(tree, "text")) do out[#out + 1] = b.text end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- panel (5b)

t.case("panel: no tabs, map, stats grid or filter chips; small and short", function()
  local e = boot()
  -- a full team with partners, a graveyard and an encounter hint
  for i = 1, 4 do
    e.world.team[#e.world.team + 1] = B.rec({ p = 0x70 + i, sp = 20 + i, nick = "Mon" .. i, hp = 20 })
  end
  e.core:go(302, "Synthetic Area Two", 11)
  e.full()
  e.core:go(303, "Synthetic Area Three", 12)
  e.core:encounter({ species = 910 })
  e.step()
  local panel = e.m.ui.trees.panel
  t.ok(panel and ui_validator.validate(panel))
  for _, ty in ipairs({ "tabs", "map", "grid", "table", "select" }) do
    t.eq(#ui_validator.all(panel, ty), 0, ty)
  end
  t.eq(ui_validator.find(panel, "badges-select"), nil, "badges come from the core")
  for _, c in ipairs(ui_validator.all(panel, "chip")) do t.eq(c.id, "grave-chip") end
  t.ok(count(panel) < 70, "block count " .. count(panel))
  -- no row with many children
  local function walk(b)
    if b.type == "row" then t.ok(#b.children <= 4, "row " .. tostring(b.id) .. " has " .. #b.children) end
    for _, c in ipairs(b.children or {}) do walk(c) end
  end
  walk(panel)
  -- short texts (fits 300 px)
  for _, b in ipairs(ui_validator.all(panel, "text")) do t.ok(#b.text <= 64, b.text) end
  -- order: header, location, hint, team, graveyard, footer
  local ids = {}
  for _, c in ipairs(panel.children) do ids[#ids + 1] = c.id end
  t.eq(ids, { "header", "loc", "enc", "team", "grave", "footer" })
  t.eq(ui_validator.find(panel, "h-open").action, "open_run")
  t.eq(ui_validator.find(panel, "f-open"), nil, "one Open run, in the header")
  t.eq(ui_validator.find(panel, "h-eyebrow"), nil, "the host draws the marker")
  t.eq(ui_validator.find(panel, "h-open").label, "Open run")
  t.eq(ui_validator.find(panel, "enc-text").text, "Wild Synthetic Species 910")
  t.eq(ui_validator.find(panel, "enc-meta").text, "first on this route")
  t.eq(ui_validator.find(panel, "enc-key").text, "Ctrl+D")
  t.eq(ui_validator.find(panel, "footer").children[1].text, "Graveyard 0 · Badges 0 / 8 · next cap Lv 15")
  t.eq(ui_validator.find(panel, "enc-no").action, "dc_open")
  t.eq(ui_validator.find(panel, "loc").title, "Synthetic Area Three")
end)

t.case("panel: at most two partner icons per row", function()
  local run = B.run({ "Lena", "Jonas", "Sam", "Max" })
  local m = mock.new({ run = { current = run }, game = { code = "x", language = "en" } })
  local core = fake_core.new()
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local function step(ms) m.advance(ms or 600); m.tick(1) end
  core.world.box[1] = B.rec({ p = 0x77, sp = 12, nick = "Zippy", hp = 30 })
  core.world.team[3] = B.rec({ p = 0x77, sp = 12, nick = "Zippy", hp = 30 })
  core.world.box = {}
  core:encounter({ species = 12 })
  step(6000); step(6000)
  for i, name in ipairs({ "u-jonas", "u-sam", "u-max" }) do
    local jt = B.tracker(name, B.cfg("soullink"), nil)
    jt:start({ 0xA1, 0xA2 })
    jt:place("loc:301")
    local facts = jt:catch(0x90 + i, 30 + i, { nick = "P" .. i })
    m.run.set_state_for(name, jt.st)
    for _, f in ipairs(facts) do
      local spec = require("model.events").from_fact(f, name)
      if spec then m.run.add_event(name, spec) end
    end
  end
  step(600)
  local panel = m.ui.trees.panel
  local row = ui_validator.find(panel, "m-pr1")
  t.ok(row, "partner row")
  local avatars = #ui_validator.all(row, "avatar") + #ui_validator.all(row, "image")
  t.eq(avatars, 2)
  t.ok(ui_validator.find(panel, "m-pm1"), "+1 for the rest")
  t.eq(ui_validator.find(panel, "m-pm1").text, "+1")
end)

t.case("panel: place picker only without a location, collapsed behind Set place", function()
  local e = boot({ setup = function(c) c:off("location", "unsupported") end })
  e.step()
  local p = e.m.ui.trees.panel
  t.ok(ui_validator.find(p, "place-toggle"))
  t.eq(ui_validator.find(p, "place-toggle").label, "Set place")
  t.eq(ui_validator.find(p, "place-picker"), nil)
  e.act("place_toggle")
  local pk = ui_validator.find(e.m.ui.trees.panel, "place-picker")
  t.ok(pk)
  local sel = ui_validator.find(pk, "place-select")
  t.eq(sel.options[1].value, "starter")
  t.eq(sel.options[2].value, "loc:400", "places of the game in game order, towns included")
  t.eq(sel.options[2].label, "Synthetic Town")
  t.eq(sel.options[3].value, "loc:301")
  t.eq(sel.options[3].label, "Synthetic Area One")
  t.ok(#sel.options <= 100)
  e.act("place_select", "loc:302")
  t.eq(e.state().place.key, "loc:302")
  t.eq(e.state().names.loc["302"], "Synthetic Area Two", "name stored for the manual place")
  -- with a location, no picker link at all
  local e2 = boot()
  e2.step()
  t.eq(ui_validator.find(e2.m.ui.trees.panel, "place-toggle"), nil)
  t.eq(ui_validator.find(e2.m.ui.trees.panel, "place-picker"), nil)
end)

-- ---------------------------------------------------------------- opening the screen

t.case("uz.ui.open: buttons, toast action and Ctrl+R open the screen slot", function()
  local e = boot()
  e.step()
  t.eq(#e.m.ui.opened, 0)
  e.act("open_run")
  t.eq(e.m.ui.opened, { "screen" })
  e.act("open-run", nil, "hotkey")
  t.eq(e.m.ui.opened, { "screen", "screen" })
  e.act("open_run", nil, "hotkey") -- not the hotkey id: ignored
  t.eq(#e.m.ui.opened, 2)
  -- the panel stays the panel (no in-panel run view any more)
  t.ok(ui_validator.find(e.m.ui.trees.panel, "panel"))
  t.eq(ui_validator.find(e.m.ui.trees.panel, "tabs"), nil)
  t.eq(e.app.ui.panel_run, nil)
  -- an error inside open is caught
  e.m.uz.ui.open = function() error("boom") end
  e.act("open_run")
  t.ok(e.m.ui.trees.panel)
end)

t.case("without uz.ui.open: meta text in the panel, no buttons, no in-panel run view", function()
  local e = boot({ no_ui_open = true })
  e.step()
  local p = e.m.ui.trees.panel
  t.eq(ui_validator.find(p, "h-open"), nil)
  t.eq(ui_validator.find(p, "f-open"), nil)
  t.eq(ui_validator.find(p, "f-update").text, "Update Uzume to open the run screen")
  e.act("open_run")
  e.act("open-run", nil, "hotkey")
  t.eq(#e.m.ui.opened, 0)
  t.eq(ui_validator.find(e.m.ui.trees.panel, "tabs"), nil)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "tabs"), "the screen slot is still built")
end)

-- ---------------------------------------------------------------- screen (5e)

t.case("screen: frame, tabs, corrections and rules live here", function()
  local e = boot()
  e.step()
  local s = e.m.ui.trees.screen
  t.ok(ui_validator.validate(s))
  local tabs = ui_validator.find(s, "tabs")
  t.eq(tabs.tabs[1]:sub(1, 6), "Routes", "no confirmed map yet: Routes first")
  t.eq(tabs.tabs[#tabs.tabs]:sub(1, 9), "Event log")
  t.ok(ui_validator.find(s, "head-summary") and not ui_validator.find(s, "head-stats"))
  t.eq(ui_validator.find(s, "rules-list"), nil)
  e.act("rules_toggle")
  t.eq(#ui_validator.find(e.m.ui.trees.screen, "rules-list").rows, 11)
  e.act("tab", 2)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "tabs").selected == 2)
  -- Team & box carries the per-mon corrections
  e.act("tab", 2)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "page-team"))
  e.act("missed_open", "loc:302")
  t.eq(ui_validator.find(e.m.ui.trees.screen, "corr").title, "Mark Synthetic Area Two as missed for you?")
  t.eq(ui_validator.find(e.m.ui.trees.panel, "corr"), nil, "not in the panel")
  e.act("corr_submit")
  local c = events_of(e.m, "soullink.correction")[1]
  t.eq(c.payload.route, "loc:302")
  t.ok(c.text:find("Synthetic Area Two", 1, true), c.text)
end)

t.case("screen: map tab shows an image only after the map was taken from the screen", function()
  local SIG = "\137PNG\r\n\26\n"
  local function png(w, h) return SIG .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4I4", w, h) .. string.rep("\0", 8) end
  local e = boot()
  e.step(3100)
  local s = e.m.ui.trees.screen
  local tabs = ui_validator.find(s, "tabs")
  t.eq(tabs.tabs[1]:sub(1, 6), "Routes")
  t.eq(tabs.tabs[2], "Map")
  e.act("tab", 2)
  s = e.m.ui.trees.screen
  t.eq(ui_validator.find(s, "map"), nil)
  t.ok(ui_validator.find(s, "map-empty").text:find("Routes and catches are listed in the Routes tab", 1, true), "empty state text of 5e")
  t.ok(ui_validator.find(s, "map-take"), "capture button")
  e.act("map_capture")
  e.m.video_result(true, png(320, 240), 320, 240)
  e.step(300)
  e.act("tab", 1)
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map"))
  -- calibration offers the game's areas
  e.act("calib_toggle")
  local sel = ui_validator.find(e.m.ui.trees.screen, "calib-route")
  t.eq(sel.options[1].value, "loc:400", "calibration offers every place, towns included")
  e.act("calib_route", "loc:302")
  e.act("calib_set")
  t.eq(e.m.cache_files["map/coords.json"], '{"crop":{"b":0,"l":0,"r":0,"t":0},"map":"000400000011C400","routes":{"loc:302":{"x":160,"y":120}}}')
end)

-- ---------------------------------------------------------------- routes from the game

t.case("routes: areas from the core give loc keys, labels and game order", function()
  local e = boot()
  e.step()
  local st = e.state()
  t.eq(st.areas, { 301, 302, 303 })
  t.eq(st.place.key, "loc:301"); t.eq(st.place.name, "Synthetic Area One"); t.eq(st.place.loc, 301)
  t.eq(st.names.loc["301"], "Synthetic Area One")
  local panel = e.m.ui.trees.panel
  t.eq(ui_validator.find(panel, "loc").status, "open")
  -- walking to another area changes the place and posts a place event
  e.core:go(302, "Synthetic Area Two", 11)
  e.step()
  t.eq(e.state().place.key, "loc:302")
  t.eq(events_of(e.m, "soullink.place")[2].payload.route, "loc:302")
  -- a town has no encounters: no key, "no encounters here"
  e.core:go(400, "Synthetic Town", 13)
  e.step()
  st = e.state()
  t.eq(st.place.key, nil); t.eq(st.place.name, "Synthetic Town")
  local loc = ui_validator.find(e.m.ui.trees.panel, "loc")
  t.eq(loc.title, "Synthetic Town"); t.eq(loc.sub, "No encounters here"); t.eq(loc.status, "none")
  -- Routes tab rows are in game order, labelled with the game's names
  e.core:go(303, "Synthetic Area Three", 12)
  e.step()
  for _, k in ipairs({ "loc:303", "loc:301", "loc:302" }) do e.act("missed_open", k); e.act("corr_submit") end
  local tbl = ui_validator.find(e.m.ui.trees.screen, "routes-table")
  local names = {}
  for _, r in ipairs(tbl.rows) do names[#names + 1] = r.cells[1] end
  t.eq(names, { "Synthetic Area One", "Synthetic Area Two", "Synthetic Area Three" }, "game order, not id order")
  -- stats: starter + 3 areas
  t.eq(e.app.view.stats.routes_total, 4)
end)

t.case("routes: areas not ready yet leaves the place alone, unsupported areas fall back to zones", function()
  local e = boot({ setup = function(c) c:off("areas", "not_ready") end })
  e.step(); e.step()
  t.eq(e.state().place.key, nil)
  e.core:on("areas")
  e.step(2500)
  t.eq(e.state().place.key, "loc:301")
  -- unsupported areas(): zone table fallback incl. the "which place?" card
  local e2 = boot({ setup = function(c) c:off("areas", "unsupported"); c:off("locations", "unsupported") end })
  e2.step(); e2.step()
  t.ok(ui_validator.find(e2.m.ui.trees.panel, "zone-new"), "fallback asks for unmapped zones")
  e2.act("place_select", "starter")
  t.eq(e2.state().place.key, "starter")
end)

t.case("legacy route-N state keeps working (labels, rows, panel)", function()
  local jt = B.tracker("u-lena", B.cfg("soullink"), nil)
  jt:start({ 0xB1, 0xB2 })
  jt:place("route-101")
  jt:catch(0x77, 12, { nick = "Old" })
  local e = boot({ states = { ["u-lena"] = jt.st }, setup = function(c) c:off("location", "unsupported"); c:off("areas", "unsupported"); c:off("locations", "unsupported") end })
  e.step()
  local panel = e.m.ui.trees.panel
  t.eq(ui_validator.find(panel, "loc").title, "Route 101")
  t.eq(ui_validator.find(panel, "loc").status, "caught")
  local tbl = ui_validator.find(e.m.ui.trees.screen, "routes-table")
  t.eq(tbl.rows[1].cells[1], "Route 101")
  t.eq(tbl.rows[1].cells[2], "Old")
  -- old keys sort before areas; mixed runs keep both
  e.act("missed_open", "loc:302"); e.act("corr_submit")
  tbl = ui_validator.find(e.m.ui.trees.screen, "routes-table")
  t.eq(tbl.rows[1].cells[1], "Route 101")
  t.eq(tbl.rows[2].cells[1], "Place #302")
  -- and the picker still lists the legacy key that has activity
  local view = e.app.view
  local ctx = e.app:ctx(view)
  local opts = require("ui.common").route_options(ctx, nil, nil)
  local found
  for _, o in ipairs(opts) do if o.value == "route-101" then found = o.label end end
  t.eq(found, "Route 101")
end)

t.case("route select options are capped at 100 and keep keys with activity", function()
  local areas = {}
  for i = 1, 150 do areas[i] = { id = 1000 + i, name = "A" .. i, zones = { i } } end
  local e = boot({ world = { areas = areas, location = { zone = 1, location = 1001, name = "A1" } } })
  e.step()
  e.act("missed_open", "place:Secret Cove"); e.act("corr_submit")
  local ctx = e.app:ctx(e.app.view)
  local opts = require("ui.common").route_options(ctx, "No group", "loc:1002")
  t.ok(#opts <= 100)
  t.eq(opts[1].value, "none"); t.eq(opts[2].value, "starter")
  local has = {}
  for _, o in ipairs(opts) do has[o.value] = true end
  t.ok(has["place:Secret Cove"] and has["loc:1002"] and has["loc:1001"])
  t.ok(not has["loc:1150"], "areas at the end are dropped first")
  t.ok(ui_validator.validate(e.app:ctx(e.app.view) and e.m.ui.trees.screen))
end)

-- ---------------------------------------------------------------- detection from core v0.3

t.case("encounters seq: first per area, once, old ones ignored", function()
  local e = boot({ setup = function(c) c:encounter({ species = 905 }); c:encounter({ species = 906 }) end })
  e.step()
  t.eq(e.state().enc_seq, 2, "encounters before tracking are baseline")
  t.eq(e.state().routes["loc:301"], nil)
  e.core:encounter({ species = 910 })
  e.step()
  t.eq(e.state().routes["loc:301"], { status = "encounter", species = 910, kind = "wild" })
  t.eq(e.state().enc_seq, 3)
  local n = #events_of(e.m, "soullink.encounter")
  e.step(); e.step(); e.step()
  t.eq(#events_of(e.m, "soullink.encounter"), n, "no double handling")
  -- second encounter on the same area: first only
  e.core:encounter({ species = 911 })
  e.step()
  t.eq(e.state().routes["loc:301"].species, 910)
  local evs = events_of(e.m, "soullink.encounter")
  t.eq(evs[#evs].payload.why, "used")
  t.eq(evs[#evs].payload.species_name, "Synthetic Species 911")
  -- another area: the encounter belongs to the area named in the entry
  e.core:go(302, "Synthetic Area Two", 11)
  e.core:encounter({ species = 913 })
  e.step()
  t.eq(e.state().routes["loc:302"].species, 913)
  -- the panel shows the hint for the current place
  t.eq(ui_validator.find(e.m.ui.trees.panel, "enc-text").text, "Wild Synthetic Species 913")
end)

t.case("encounters: hordes per rule, shiny clause, dupes clause", function()
  local e = boot()
  e.step()
  e.core:go(303, "Synthetic Area Three", 12)
  e.core:encounter({ species = 912, horde = true })
  e.step()
  t.eq(e.state().routes["loc:303"], nil, "hordes skipped by default")
  local evs = events_of(e.m, "soullink.encounter")
  t.eq(evs[#evs].payload.why, "horde")
  e.core:go(302, "Synthetic Area Two", 11)
  e.core:encounter({ species = 914, shiny = true })
  e.step()
  t.eq(e.state().routes["loc:302"], nil, "shiny clause keeps the route open")
  evs = events_of(e.m, "soullink.encounter")
  t.eq(evs[#evs].payload.why, "shiny")
  -- dupes: the line is owned after a catch
  e.core:go(301, "Synthetic Area One", 10)
  e.core:encounter({ species = 910 })
  e.step()
  e.catch(0x80, 910, "Dup")
  e.core:go(302, "Synthetic Area Two", 11)
  e.core:encounter({ species = 910 })
  e.step()
  t.eq(e.state().routes["loc:302"], nil, "dupe: not counted")
  -- hordes count with the rule on
  local e2 = boot({ settings = { ["uzume.soullink"] = { mode = "soullink", rules = { hordes_count = true } } } })
  e2.step()
  e2.core:go(303, "Synthetic Area Three", 12)
  e2.core:encounter({ species = 912, horde = true })
  e2.step()
  t.eq(e2.state().routes["loc:303"].kind, "horde")
end)

t.case("catch lands on the pending encounter's area; missed after the battle", function()
  local e = boot()
  e.step()
  e.core:encounter({ species = 910 })
  e.core:battle_start({ species = 910 })
  e.step()
  t.eq(e.app.view.players[1].place.status, "encounter")
  e.core:go(302, "Synthetic Area Two", 11) -- moved on before the catch showed up
  e.core:battle_end()
  e.catch(0x81, 910, "Catchy")
  t.eq(e.state().mons["00000081"].route, "loc:301")
  t.eq(e.state().routes["loc:301"].status, "caught")
  -- a battle that ends without a catch: missed
  e.core:go(303, "Synthetic Area Three", 12)
  e.core:encounter({ species = 915, location = 303 })
  e.core:battle_start({ species = 915 })
  e.step()
  e.core:battle_end()
  e.step()
  t.eq(e.state().routes["loc:303"].status, "encounter", "undecided right after the battle")
  e.step(61000)
  t.eq(e.state().routes["loc:303"].status, "missed")
end)

t.case("death: only from the party record, never from battle own data or right after a battle", function()
  local e = boot()
  e.step()
  e.core:encounter({ species = 910 })
  e.step()
  e.catch(0x82, 910, "Fighter")
  local mon = function() return e.state().mons["00000082"] end
  t.eq(mon().hp, 30)
  -- live hp 0 in the team record
  e.world.box[1].hp = 0
  e.full()
  t.eq(mon().deaths, 1)
  local d = events_of(e.m, "soullink.death")
  t.eq(#d, 1); t.eq(d[1].payload.species_name, "Synthetic Species 910")
  e.full(); e.full()
  t.eq(mon().deaths, 1, "counted once")
  -- revived, then the battle reports hp 0 for the own battler: ignored (it can be stale)
  e.world.box[1].hp = 20
  e.full()
  t.eq(mon().hp, 20)
  e.core:battle_start({ species = 911, own = { { personality = 0x82, species = 910, hp = 0, max_hp = 30 } } })
  e.step(); e.step(); e.step()
  t.eq(mon().deaths, 1, "battle own hp 0 does not count")
  t.eq(mon().hp, 20)
  -- the party record shows 0 during the battle: counted only once the battle is over and settled
  e.world.box[1].hp = 0
  e.full(); e.full()
  t.eq(mon().deaths, 1, "not during the battle")
  t.eq(mon().hp, 20, "last known hp kept meanwhile")
  e.core:battle_end()
  e.full()
  t.eq(mon().deaths, 1, "not in the snapshot where the battle ended")
  e.full()
  t.eq(mon().deaths, 2)
  t.eq(#events_of(e.m, "soullink.death"), 2)
  e.step(); e.full()
  t.eq(mon().deaths, 2, "counted once")
  t.ok(e.app.view.players[1].mons["00000082"].dead)
  -- an implausible record (max hp 0) is no death
  e.world.box[1].hp, e.world.box[1].max_hp = 10, 30
  e.full()
  e.world.box[1].hp, e.world.box[1].max_hp = 0, 0
  e.full()
  t.eq(mon().deaths, 2)
  -- untracked (baseline) mons never produce deaths
  e.world.team[1].hp = 0
  e.full()
  t.eq(#events_of(e.m, "soullink.death"), 2)
end)

t.case("badges: automatic from the core, manual select only when unsupported", function()
  local e = boot({ setup = function(c) c:off("badges", "not_ready") end })
  e.step()
  t.ok(ui_validator.find(e.m.ui.trees.panel, "badges-select"), "no badges() yet")
  e.core:on("badges")
  e.world.badges = { count = 3, flags = { true, true, true, false, false, false, false, false } }
  e.step()
  t.eq(e.state().badges, 3)
  local p = e.m.ui.trees.panel
  t.eq(ui_validator.find(p, "badges").text, "Graveyard 0 · Badges 3 / 8 · next cap Lv 29")
  t.eq(ui_validator.find(p, "badges-select"), nil)
  local e2 = boot({ setup = function(c) c:off("badges", "unsupported") end })
  e2.step()
  t.ok(ui_validator.find(e2.m.ui.trees.panel, "badges-select"))
  e2.act("badges_select", 2)
  t.eq(e2.state().badges, 2)
end)

t.case("pairs-differ-primary-type: the clause uses species_info and the partners' types", function()
  local jt = B.tracker("u-jonas", B.cfg("soullink"), nil)
  jt:start({ 0xA1, 0xA2 })
  jt.st.routes["loc:301"] = { status = "caught", mon = "000000c1", species = 30, kind = "wild" }
  jt.st.mons["000000c1"] = { species = 30, level = 5, where = "box", route = "loc:301", ty = 4, nickname = "Pal" }
  local settings = { ["uzume.soullink"] = { mode = "soullink", rules = { pairs_differ_primary_type = true } } }
  local e = boot({ settings = settings, states = { ["u-jonas"] = jt.st }, setup = function(c)
    c.world.types[910] = { 4 }; c.world.types[911] = { 7, 4 }
  end })
  e.step()
  e.core:encounter({ species = 910 })
  e.step()
  t.eq(e.state().routes["loc:301"], nil, "same primary type as Jonas' creature: re-roll")
  local evs = events_of(e.m, "soullink.encounter")
  t.eq(evs[#evs].payload.why, "type")
  e.core:encounter({ species = 911 })
  e.step()
  t.eq(e.state().routes["loc:301"].species, 911, "different primary type counts")
  e.catch(0x83, 911, "Typed")
  t.eq(e.state().mons["00000083"].ty, 7)
  -- rule off: species_info is never asked
  local e2 = boot({ setup = function(c) c.world.types[910] = { 4 } end })
  e2.core:encounter({ species = 910 })
  e2.step(); e2.step()
  t.eq(e2.world.calls.species_info, nil)
end)

t.case("every part may be unsupported or not ready: no crash, manual input remains", function()
  local e = boot({ setup = function(c)
    for _, fn in ipairs({ "location", "battle", "encounters", "badges", "areas", "name", "species_info" }) do c:off(fn, "unsupported") end
  end })
  for _ = 1, 4 do e.step() end
  t.ok(e.m.ui.trees.panel and e.m.ui.trees.screen and e.m.ui.trees.hud)
  e.act("place_toggle")
  e.act("place_select", "starter")
  t.eq(e.state().place.key, "starter")
  e.world.team[#e.world.team + 1] = B.rec({ p = 0x84, sp = 20, nick = "Hand", hp = 30 })
  e.full()
  t.eq(e.state().mons["00000084"].route, "starter")
  t.eq(e.app.view.players[1].mons["00000084"].species_name, nil)
  t.ok(texts(e.m.ui.trees.panel):find("#20", 1, true), "species id fallback without names")
  local e2 = boot({ setup = function(c)
    for _, fn in ipairs({ "location", "battle", "encounters", "badges", "areas", "name" }) do c:off(fn, "not_ready") end
  end })
  for _ = 1, 3 do e2.step(3000) end
  t.ok(e2.m.ui.trees.panel)
end)

-- ---------------------------------------------------------------- names in the run state

t.case("names: catch, encounter and place store display names; other players see them", function()
  local e = boot()
  e.step()
  e.core:encounter({ species = 910 })
  e.step()
  e.catch(0x85, 910, "Nick")
  local st = e.state()
  t.eq(st.names.sp["910"], "Synthetic Species 910")
  t.eq(st.names.loc["301"], "Synthetic Area One")
  t.eq(events_of(e.m, "soullink.catch")[1].text, "Lena caught Nick on Synthetic Area One.")
  t.eq(events_of(e.m, "soullink.catch")[1].payload.species_name, "Synthetic Species 910")
  -- team records carry species_name and win over the lookup
  e.world.box[1].species_name = "From Record"
  e.core:encounter({ species = 911 })
  e.step()
  e.full()
  t.eq(e.state().names.sp["910"], "From Record", "the record's own text updates the stored name")
  -- dedupe per id and short
  local before = util.json_size(e.state().names)
  e.step(); e.full()
  t.eq(util.json_size(e.state().names), before)
  t.ok(before < 400)
  -- Jonas (another app) shows names from Lena's state with no core involved
  local run = B.run({ "Lena", "Jonas" })
  run.me = "u-jonas"
  local states = { ["u-lena"] = e.state(), ["u-jonas"] = { v = 1 } }
  local v = view_mod.view(run, states, {}, B.cfg("soullink"))
  t.eq(v.players[1].mons["00000085"].species_name, "From Record")
  t.eq(v.players[1].mons["00000085"].route, "loc:301")
  local hud = require("ui.hud").build({ view = v, run = run, me = "u-lena", ui = {}, tr = e.app.tr })
  t.ok(texts(hud):find("Synthetic Area One", 1, true))
  local tile = require("ui.tile").build(e.app.tr, v.players[1], v)
  t.eq(tile.text, "SL Synthetic Area One · 1 alive")
  -- a place stored without a name (older state) uses the stored name of the key
  local st2 = util.copy(e.state())
  st2.place.name = nil
  local v2 = view_mod.view(run, { ["u-lena"] = st2 }, {}, B.cfg("soullink"))
  t.eq(require("ui.common").place_label(v2.players[1].place, e.app.tr, v2), "Synthetic Area One")
  t.eq(require("ui.tile").build(e.app.tr, v2.players[1], v2).text, "SL Synthetic Area One · 1 alive")
end)

t.case("names: Runs page run view (no game, no core) shows names, never #ids", function()
  local lena = B.tracker("u-lena", B.cfg("soullink"), nil, { names = { species = function(id) return "Name" .. id end } })
  lena:start({ 0xB1, 0xB2 })
  lena:place("loc:301")
  lena.st.names.loc["301"] = "Cove"
  lena:catch(0x77, 12, { nick = "Zip" })
  lena:catch(0x78, 13, { nick = "" })
  local run = B.run({ "Lena", "Jonas" })
  run.view = true
  local m = mock.new({ run = { current = run, states = { ["u-lena"] = lena.st } } })
  m.set_provider("pokemon.core", { team = function() error("no core") end })
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(3)
  local tree = m.ui.trees.run
  t.ok(tree)
  local all = texts(tree)
  t.ok(all:find("Cove", 1, true))
  local cells = {}
  for _, tb in ipairs(ui_validator.all(tree, "table")) do for _, r in ipairs(tb.rows) do cells[#cells + 1] = table.concat(r.cells, "|") end end
  t.ok(table.concat(cells, "\n"):find("Cove|Zip", 1, true))
  t.eq(#m.calls, 0)
end)

t.case("names: limits keep the state small", function()
  local st = state_mod.new()
  for i = 1, 600 do state_mod.note_name(st, "sp", i, string.rep("x", 60)) end
  local n = 0
  for _, v in pairs(st.names.sp) do n = n + 1; t.ok(#v <= 24) end
  t.eq(n, 400)
  t.ok(not state_mod.note_name(st, "sp", 1, nil))
  t.ok(not state_mod.note_name(st, "sp", "x", "Name"))
  t.ok(state_mod.note_name(st, "sp", 1, "Short"))
  t.eq(st.names.sp["1"], "Short")
  t.ok(not state_mod.note_name(st, "sp", 1, "Short"), "unchanged")
  t.ok(util.json_size(st) < 16 * 1024, util.json_size(st))
  -- compact drops names nothing refers to once the state is large
  local big = state_mod.new()
  for i = 1, 400 do state_mod.note_name(big, "sp", i, "Name " .. i) end
  for i = 1, 200 do state_mod.note_name(big, "loc", i, "Place " .. i) end
  big.mons["00000001"] = { species = 5, where = "box" }
  big.padding = string.rep("x", state_mod.MAX_BYTES)
  state_mod.compact(big)
  t.ok(big.names.sp["5"] == "Name 5" and big.names.sp["6"] == nil)
  t.eq(next(big.names.loc), nil)
end)

t.case("detect: stale area order and 400-area lists stay bounded", function()
  local areas = { set = {}, order = {}, names = {} }
  for i = 1, 500 do areas.set[i] = true; areas.order[i] = i end
  local st = detect.diff(nil, { location = { zone = 1, location = 7, name = "X" } }, B.cfg(), { areas = areas })
  t.eq(#st.areas, state_mod.MAX_AREAS)
  t.eq(st.place.key, "loc:7")
  -- manual place stays while the location stays, goes when it changes
  st = detect.set_place(st, "starter", nil, 1, 7)
  st = detect.diff(st, { location = { zone = 2, location = 7, name = "X" } }, B.cfg(), { areas = areas })
  t.eq(st.place.key, "starter")
  st = detect.diff(st, { location = { zone = 2, location = 8, name = "Y" } }, B.cfg(), { areas = areas })
  t.eq(st.place.key, "loc:8")
end)
