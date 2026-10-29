-- v0.4.1: places from areas() + locations(), pending encounters after a battle, no place flicker,
-- names resolved when they become known, run screen tab selection and collapsed rules.
-- Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local detect = require("model.detect")
local view_mod = require("model.view")
local common = require("ui.common")
local panel_ui = require("ui.panel")
local oras = require("data.oras")

local function boot(o)
  o = o or {}
  local run = B.run({ "Lena", "Jonas" }, B.no_balls_rule())
  local m = mock.new({ run = { current = run, states = o.states }, game = { code = "000400000011C400", language = "en" }, video = true })
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

local function events_of(m, kind)
  local out = {}
  for _, ev in ipairs(m.run.events) do if ev.type == kind then out[#out + 1] = ev end end
  return out
end

local function values(options)
  local out = {}
  for _, o in ipairs(options) do out[#out + 1] = o.value end
  return out
end

-- ---------------------------------------------------------------- 1. places

t.case("places: select lists areas and towns from the game in game order, deduplicated, names from the core", function()
  local e = boot({ setup = function(c) c:off("location", "unsupported") end })
  e.step()
  e.act("place_toggle")
  local sel = ui_validator.find(e.m.ui.trees.panel, "place-select")
  t.eq(values(sel.options), { "starter", "loc:400", "loc:301", "loc:401", "loc:302", "loc:303" })
  t.eq(sel.options[2].label, "Synthetic Town")
  t.eq(sel.options[4].label, "Synthetic Cave")
  t.eq(e.state().places, { 400, 301, 401, 302, 303 })
  t.eq(e.state().areas, { 301, 302, 303 }, "areas stay the encounter areas")
  t.eq(e.app.view.stats.routes_total, 4, "towns are no routes")
  -- a town is a valid manual place
  e.act("place_select", "loc:400")
  t.eq(e.state().place.key, "loc:400")
  t.eq(e.state().names.loc["400"], "Synthetic Town")
end)

t.case("places: locations() not ready yet / unsupported: areas alone work, locations are added when ready", function()
  local e = boot({ setup = function(c) c:off("locations", "not_ready"); c:off("location", "unsupported") end })
  e.step(); e.step()
  t.eq(e.state().areas, { 301, 302, 303 })
  e.act("place_toggle")
  t.eq(values(ui_validator.find(e.m.ui.trees.panel, "place-select").options), { "starter", "loc:301", "loc:302", "loc:303" })
  e.core:on("locations")
  e.step(6000)
  t.eq(values(ui_validator.find(e.m.ui.trees.panel, "place-select").options),
    { "starter", "loc:400", "loc:301", "loc:401", "loc:302", "loc:303" })
  local e2 = boot({ setup = function(c) c:off("locations", "unsupported"); c:off("location", "unsupported") end })
  e2.step()
  e2.act("place_toggle")
  t.eq(values(ui_validator.find(e2.m.ui.trees.panel, "place-select").options), { "starter", "loc:301", "loc:302", "loc:303" })
  -- locations() alone (no areas()): has_encounters decides which places are routes
  local e3 = boot({ setup = function(c) c:off("areas", "unsupported") end })
  e3.step(); e3.step()
  t.eq(e3.state().place.key, "loc:301")
  t.eq(e3.state().areas, { 301, 302, 303 })
end)

t.case("places: current place is preselected, a town without route key too", function()
  local e = boot()
  e.core:go(400, "Synthetic Town", 13)
  e.step(); e.step()
  t.eq(e.state().place.key, nil)
  t.eq(e.state().place.loc, 400)
  t.eq(e.state().place.name, "Synthetic Town")
  local ctx = e.app:ctx(e.app.view)
  ctx.location_ok = false -- the picker is shown
  ctx.ui = { place_open = true }
  local sel = ui_validator.find(panel_ui.build(ctx), "place-select")
  t.eq(sel.selected, "loc:400")
  local found
  for _, o in ipairs(sel.options) do if o.value == "loc:400" then found = o end end
  t.ok(found, "selected is an option")
  t.eq(common.place_value({ key = "loc:301", loc = 301 }), "loc:301")
  t.eq(common.place_value({ manual = false }), nil)
end)

t.case("places: name falls back to the stored name, then to Place #id", function()
  local ctx = { tr = function(k, v) return k == "area" and ("Place #" .. v.n) or k end,
                view = { names = { loc = { ["301"] = "Stored Name" } } }, area_name = function() return nil end }
  t.eq(common.route_label(ctx, "loc:301"), "Stored Name")
  t.eq(common.route_label(ctx, "loc:999"), "Place #999")
  local e = boot()
  e.step()
  t.eq(e.app.tr("area", { n = 12 }), "Place #12")
  local de = mock.new({ run = { current = B.run({ "Lena", "Jonas" }) }, language = "de" })
  t.eq(de.uz.i18n.t("area", { n = 12 }), "Ort #12")
end)

t.case("places: at most 100 options, the selected place and places in use stay", function()
  local locs = {}
  for i = 1, 150 do locs[i] = { id = 1000 + i, name = "Synthetic Place " .. i, zones = { 100 + i }, has_encounters = i % 2 == 0 } end
  local e = boot({ world = { locations = locs, areas = {} }, setup = function(c) c:off("location", "unsupported") end })
  e.step(); e.step()
  local ctx = e.app:ctx(e.app.view)
  local opts = common.route_options(ctx, nil, "loc:1150")
  t.ok(#opts <= 100, #opts)
  local has = {}
  for _, o in ipairs(opts) do has[o.value] = true end
  t.ok(has["loc:1150"], "selected kept although last in game order")
  t.ok(has["starter"] and has["loc:1001"])
  -- sorted in game order
  local last = 0
  for _, o in ipairs(opts) do
    local id = oras.area_id(o.value)
    if id then t.ok(id > last, o.value); last = id end
  end
  -- a place in use (activity) is kept too
  e.act("place_select", "loc:1149")
  ctx = e.app:ctx(e.app.view)
  has = {}
  for _, o in ipairs(common.route_options(ctx, nil, nil)) do has[o.value] = true end
  t.ok(has["loc:1149"])
end)

t.case("places: other players' places and legacy states give the order", function()
  local run = B.run({ "Lena", "Jonas" })
  local states = { ["u-lena"] = { v = 1, areas = { 301, 302 } }, ["u-jonas"] = { v = 1, places = { 400, 301 }, areas = { 301 } } }
  t.eq(view_mod.merge_places(run, states), { 301, 302, 400 }, "own places or areas first, then the others'")
  t.eq(view_mod.view(run, states, {}, B.cfg("soullink")).places, { 301, 302, 400 })
end)

-- ---------------------------------------------------------------- 2. pending encounters and deaths

local function fresh()
  local tr = B.tracker("u-a", B.cfg())
  tr:start()
  tr:place("route-101")
  return tr
end

t.case("pending: a finished wild battle stays an encounter until the mon shows up", function()
  local tr = fresh()
  tr:battle(30)
  t.eq(B.count(tr:end_battle_only(), "missed"), 0)
  t.eq(tr.st.routes["route-101"].status, "encounter")
  t.ok(tr.st.pend)
  -- the Pokedex page / nickname dialog: seconds pass without the mon
  t.eq(B.count(tr:wait(20000), "missed"), 0)
  t.eq(tr.st.routes["route-101"].status, "encounter")
  local c = B.fact(tr:catch(0x100, 30), "catch")
  t.eq(c.counts, true); t.eq(c.route, "route-101")
  t.eq(tr.st.routes["route-101"].status, "caught")
  t.eq(tr.st.pend, nil)
  t.eq(B.count(tr:wait(120000), "missed"), 0, "caught stays caught")
end)

t.case("pending: missed after the timeout", function()
  local tr = fresh()
  tr:battle(30)
  tr:end_battle_only()
  t.eq(B.count(tr:wait(59000), "missed"), 0)
  local m = B.fact(tr:wait(2000), "missed")
  t.ok(m); t.eq(m.route, "route-101")
  t.eq(tr.st.routes["route-101"].status, "missed")
  t.eq(tr.st.pend, nil)
end)

t.case("pending: missed when the player moves on, or the next wild battle starts", function()
  local function setup()
    local tr = B.tracker("u-a", B.cfg())
    tr.opts.areas = { set = { [301] = true, [302] = true }, order = { 301, 302 }, names = {} }
    tr.snap_extra.location = { zone = 10, location = 301, name = "A" }
    tr:start()
    tr:step()
    tr:battle(30)
    tr:end_battle_only()
    return tr
  end
  local tr = setup()
  t.eq(tr.st.routes["loc:301"].status, "encounter")
  tr.snap_extra.location = { location = nil, zone = nil } -- transient read
  t.eq(B.count(tr:step(), "missed"), 0)
  tr.snap_extra.location = { zone = 11, location = 302, name = "B" }
  t.ok(B.fact(tr:step(), "missed"), "location changed")
  t.eq(tr.st.routes["loc:301"].status, "missed")
  local tr2 = setup()
  local facts = tr2:battle(31)
  t.ok(B.fact(facts, "missed"), "next wild battle")
  t.eq(tr2.st.routes["loc:301"].status, "missed")
end)

t.case("pending: app level, no missed event while the catch is still coming", function()
  local e = boot()
  e.step()
  e.core:encounter({ species = 910 })
  e.core:battle_start({ species = 910 })
  e.step()
  e.core:battle_end()
  e.step(); e.step(5000)
  t.eq(e.state().routes["loc:301"].status, "encounter")
  t.eq(e.app.view.players[1].place.status, "encounter", "never shown as missed")
  for _, ev in ipairs(events_of(e.m, "soullink.encounter")) do t.ok(ev.payload.outcome ~= "missed") end
  e.catch(0x91, 910, "Late")
  t.eq(e.state().routes["loc:301"].status, "caught")
  e.step(61000)
  t.eq(e.state().routes["loc:301"].status, "caught")
  for _, ev in ipairs(events_of(e.m, "soullink.encounter")) do t.ok(ev.payload.outcome ~= "missed") end
end)

t.case("death: stale battle own data after the battle never counts", function()
  local tr = fresh()
  tr:catch(0x100, 30, { team = true })
  tr:battle(31)
  tr.snap_extra.battle.own = { { personality = 0x100, species = 30, hp = 0, max_hp = 30 } }
  tr:step()
  tr:end_battle_only()
  tr.snap_extra.battle = { active = false, wild = false, foes = {}, own = { { personality = 0x100, species = 30, hp = 0, max_hp = 30 } } }
  tr:step(); tr:step()
  t.eq(tr.st.mons["00000100"].deaths, nil)
  -- the party record decides, after the battle settled
  tr.recs[0x100].hp = 0
  t.eq(B.count(tr:step(), "death"), 1, "settled: counted")
  t.eq(tr.st.mons["00000100"].deaths, 1)
  -- hp 0 with max hp 0 is a transient record
  local tr2 = fresh()
  tr2:catch(0x101, 30, { team = true })
  tr2.recs[0x101].hp, tr2.recs[0x101].max_hp = 0, 0
  t.eq(B.count(tr2:step(), "death"), 0)
end)

-- ---------------------------------------------------------------- 3. place flicker

t.case("place: transient unknown locations create no place events", function()
  local e = boot()
  e.step(); e.step()
  local function places() return #events_of(e.m, "soullink.place") end
  local n = places()
  t.ok(n >= 1)
  e.world.location = nil
  e.step(); e.step()
  e.world.location = { zone = nil, location = nil, name = nil }
  e.step(); e.step()
  e.world.location = { zone = 77, name = nil } -- zone without a name and without a mapping
  e.step(); e.step()
  t.eq(places(), n, "no event for unknown places")
  for _, ev in ipairs(events_of(e.m, "soullink.place")) do t.ok(ev.text:find("No place yet", 1, true) == nil, ev.text) end
  -- real changes are logged once
  e.core:go(302, "Synthetic Area Two", 11)
  e.step(); e.step(); e.step()
  t.eq(places(), n + 1)
  e.core:go(400, "Synthetic Town", 13)
  e.step(); e.step()
  t.eq(places(), n + 2)
  -- a location whose name is not loaded yet (town, no key) keeps the last known place
  e.world.location = { zone = 14, location = 999, name = nil }
  e.step(); e.step()
  t.eq(places(), n + 2)
  t.eq(e.state().place.loc, 400)
end)

t.case("place: detect keeps the place on keyless and nameless reads", function()
  local areas = { set = { [301] = true }, order = { 301 }, names = { [301] = "A" } }
  local st, f = detect.diff(nil, { location = { zone = 1, location = 301 } }, B.cfg(), { areas = areas })
  t.eq(#f, 1); t.eq(st.place.key, "loc:301")
  st, f = detect.diff(st, { location = { zone = 2, location = 500 } }, B.cfg(), { areas = areas })
  t.eq(#f, 0); t.eq(st.place.key, "loc:301")
  st, f = detect.diff(st, { location = { zone = 2, location = 500, name = "Town" } }, B.cfg(), { areas = areas })
  t.eq(#f, 1); t.eq(f[1].name, "Town"); t.eq(st.place.key, nil)
  st, f = detect.diff(st, { location = { zone = 2, location = 500, name = "Town (renamed text)" } }, B.cfg(), { areas = areas })
  t.eq(#f, 0, "same location, no second event")
end)

-- ---------------------------------------------------------------- 4. names

t.case("names: events show ids until the name is known, then the name (render time)", function()
  local e = boot({ setup = function(c) c:off("name", "not_ready") end })
  e.step()
  e.core:encounter({ species = 910 })
  e.step(); e.step()
  local ev = events_of(e.m, "soullink.encounter")[1]
  t.ok(ev.text:find("#910", 1, true), ev.text)
  t.eq(ev.payload.species, 910)
  e.catch(0x92, 910, nil)
  local screen_log = function()
    e.act("tab", 5, "screen")
    local titles = {}
    for _, r in ipairs(ui_validator.find(e.m.ui.trees.screen, "log-list").rows) do titles[#titles + 1] = r.title end
    return table.concat(titles, "\n")
  end
  t.ok(screen_log():find("#910", 1, true))
  -- the team/box row shows the id too
  e.act("tab", 3, "screen")
  local box = ui_validator.find(e.m.ui.trees.screen, "box-list1")
  t.eq(box.rows[1].title, "#910")
  -- the game text becomes available
  e.core:on("name")
  e.full(); e.full()
  local log = screen_log()
  t.ok(log:find("Synthetic Species 910", 1, true), log)
  t.ok(not log:find("#910", 1, true), log)
  t.eq(e.state().names.sp["910"], "Synthetic Species 910", "cached in the run state")
  e.act("tab", 3, "screen")
  t.eq(ui_validator.find(e.m.ui.trees.screen, "box-list1").rows[1].title, "Synthetic Species 910")
  -- the stored event keeps ids only; its own text is unchanged
  t.ok(ev.text:find("#910", 1, true))
end)

t.case("names: record species_name wins; place names resolve at render time", function()
  local e = boot()
  e.step()
  e.world.team[1].species_name = "Record Name"
  e.full()
  t.eq(e.state().names.sp["900"], nil, "baseline mons are not tracked")
  e.core:encounter({ species = 911 })
  e.world.box[1] = B.rec({ p = 0x93, sp = 911, hp = 30 })
  e.world.box[1].species_name = "Boxed Name"
  e.full()
  t.eq(e.state().names.sp["911"], "Boxed Name")
  -- place event posted without a stored name: wording uses the game's name at render time
  local ev = { type = "soullink.place", source = "automatic", user_id = "u-lena", payload = { route = "loc:302", manual = false }, seq = 999 }
  t.eq(e.app:event_text(ev), "Lena is on Synthetic Area Two.")
end)

-- ---------------------------------------------------------------- 5. run screen

t.case("screen: the first tab is selected by default and the selection follows the tab, not the index", function()
  local e = boot()
  e.step()
  local tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.selected, 1)
  t.eq(tabs.tabs[tabs.selected]:sub(1, 6), "Routes")
  e.act("tab", 3, "screen") -- Team & box (the Map tab follows Routes)
  tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.tabs[tabs.selected], "Team & box")
  -- opening the run screen again starts on the first tab
  e.act("open_run", nil, "panel")
  tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.selected, 1)
  t.eq(tabs.tabs[1]:sub(1, 6), "Routes")
end)

t.case("screen: the Map tab moving to the front keeps the player on the Map tab", function()
  local SIG = "\137PNG\r\n\26\n"
  local function png(w, h) return SIG .. string.pack(">I4", 13) .. "IHDR" .. string.pack(">I4I4", w, h) .. string.rep("\0", 8) end
  local e = boot()
  e.step(3100)
  local tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.selected, 1)
  t.eq(tabs.tabs[1]:sub(1, 6), "Routes", "Routes first while there is no map")
  e.act("tab", 2, "screen")
  tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.tabs[tabs.selected], "Map")
  e.act("map_capture", nil, "screen")
  e.m.video_result(true, png(100, 60), 100, 60)
  e.step(300)
  tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.tabs[1], "Map", "the taken map leads")
  t.eq(tabs.tabs[tabs.selected], "Map", "selection stays on the Map tab")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "map"))
  e.act("tab", 2, "screen")
  tabs = ui_validator.find(e.m.ui.trees.screen, "tabs")
  t.eq(tabs.tabs[tabs.selected]:sub(1, 6), "Routes")
end)

t.case("screen: rules are collapsed to a summary, the list opens in a short scroll area", function()
  local e = boot()
  e.step()
  local s = e.m.ui.trees.screen
  t.ok(ui_validator.validate(s))
  t.eq(ui_validator.find(s, "rules-list"), nil)
  t.eq(ui_validator.find(s, "rules-scroll"), nil)
  t.eq(ui_validator.find(s, "rules-summary").text, "6 of 10 rules on")
  t.eq(ui_validator.find(s, "rules-chip").text, "Show rules")
  e.act("rules_toggle", nil, "screen")
  s = e.m.ui.trees.screen
  t.ok(ui_validator.validate(s))
  local sc = ui_validator.find(s, "rules-scroll")
  t.eq(sc.max_height, "s")
  t.ok(ui_validator.find(sc, "rules-list"))
  t.eq(ui_validator.find(s, "rules-chip").text, "Hide rules")
  e.act("rules_toggle", nil, "screen")
  t.eq(ui_validator.find(e.m.ui.trees.screen, "rules-list"), nil)
end)
