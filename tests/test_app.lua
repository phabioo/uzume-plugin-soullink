-- Wiring tests: controller with mocked fb.run, fb.ui and pokemon.core. The mock validates every
-- fb.ui tree and patch against the documented block catalog (tests/support/ui_validator.lua).
local t = require("t")
local B = require("build")
local mock = require("fb_mock")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local oras = require("data.oras")

local function find_text(tree, needle)
  for _, b in ipairs(ui_validator.all(tree, "text")) do
    if b.text:find(needle, 1, true) then return b end
  end
  return nil
end

--- Boot a run with Lena (me) and Jonas; the fake core exposes `world.team` / `world.box`.
local function boot(opts)
  opts = opts or {}
  local run = B.run({ "Lena", "Jonas" })
  run.settings = opts.settings or {}
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
  local world = { team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }), B.rec({ p = 0xB2, sp = 901, hp = 30 }) }, box = {} }
  m.set_provider("pokemon.core", {
    team = function() return world.team end,
    box_count = function() return 1 end,
    box = function() return world.box end,
  })
  local app = controller.new(m.fb)
  app:start()
  local env = { m = m, world = world, app = app, run = run }
  function env.step(ms)
    m.advance(ms or 600)
    m.tick(1)
  end
  function env.full_poll() env.step(6000) end
  function env.catch(p, sp, nick)
    world.box[#world.box + 1] = B.rec({ p = p, sp = sp, nick = nick, hp = 30 })
    env.full_poll()
  end
  function env.act(a, v, slot) m.action(a, v, slot) env.step(300) end
  return env
end

local function events_of(m, kind)
  local out = {}
  for _, ev in ipairs(m.run.events) do if ev.type == kind then out[#out + 1] = ev end end
  return out
end

--- Jonas joins a route with a mon: own state via a tracker, plus the catch event.
local function jonas_catches(env, route, pid, sp)
  local jt = B.tracker("u-jonas", B.cfg("soullink"), nil)
  jt:start({ 0xA1, 0xA2 })
  jt:place(route)
  local facts = jt:catch(pid, sp, { nick = "Spark" })
  env.m.run.set_state_for("u-jonas", jt.st)
  for _, f in ipairs(facts) do
    local E = require("model.events")
    local spec = E.from_fact(f, "u-jonas")
    if spec then env.m.run.add_event("u-jonas", spec) end
  end
  return jt
end

t.case("no run: empty states, no tracking", function()
  local m = mock.new()
  m.set_provider("pokemon.core", { team = function() error("must not be called") end })
  local app = controller.new(m.fb)
  app:start()
  for _, slot in ipairs({ "panel", "hud", "screen" }) do t.ok(m.ui.trees[slot], slot) end
  t.ok(ui_validator.find(m.ui.trees.panel, "empty").text:find("Play run", 1, true))
  t.ok(find_text(m.ui.trees.hud, "Play run"))
  t.ok(ui_validator.find(m.ui.trees.screen, "empty").text:find("Runs", 1, true))
  m.tick(200)
  t.eq(#m.calls, 0)
  m.action("open_run", nil, "panel") -- harmless
end)

t.case("fact text without a route has no place phrase", function()
  local e = boot()
  local txt = e.app:fact_text({ kind = "catch", nickname = "Zippy", species = 1, why = "no_place" })
  t.eq(txt, "Lena caught Zippy. Place unknown.")
  t.ok(not txt:find("No place yet", 1, true))
  t.eq(e.app:fact_text({ kind = "missed" }), "Lena missed a place.")
  t.ok(not e.app:fact_text({ kind = "encounter", species = 5 }):find("No place yet", 1, true))
end)

t.case("catch: state, event and panel", function()
  local e = boot()
  local st = e.m.run.states["u-lena"]
  t.ok(st and st.started, "baseline state written")
  e.act("place_select", "route-101")
  t.eq(e.m.run.states["u-lena"].place.key, "route-101")
  e.catch(0x77, 12, "Zippy")
  st = e.m.run.states["u-lena"]
  t.eq(st.mons["00000077"].route, "route-101")
  t.eq(st.routes["route-101"].status, "caught")
  local catches = events_of(e.m, "soullink.catch")
  t.eq(#catches, 1)
  t.eq(catches[1].source, "automatic")
  t.eq(catches[1].payload.mon, "00000077")
  t.eq(catches[1].text, "Lena caught Zippy on Route 101.")
  t.eq(#events_of(e.m, "soullink.place"), 1)
  local panel = e.m.ui.trees.panel
  t.eq(ui_validator.find(panel, "loc").title, "Route 101")
  t.eq(ui_validator.find(panel, "loc").status, "caught")
  t.eq(ui_validator.find(e.m.ui.trees.hud, "hud-status").text, "Caught")
  t.eq(ui_validator.find(e.m.ui.trees.hud, "hud-status").tone, "ok")
  -- state is only written when it changed
  local n = e.m.run.events and #e.m.run.events
  e.step(); e.step()
  t.eq(#e.m.run.events, n)
end)

t.case("state changed only: setState count", function()
  local e = boot()
  local writes = 0
  local orig = e.m.fb.run.setState
  e.m.fb.run.setState = function(s) writes = writes + 1; return orig(s) end
  for _ = 1, 10 do e.step() end
  t.eq(writes, 0)
  e.act("badges_select", 3)
  t.eq(writes, 1)
  t.eq(e.m.run.states["u-lena"].badges, 3)
  t.eq(ui_validator.find(e.m.ui.trees.panel, "badges").text, "Graveyard 0 · Badges 3 / 8 · next cap Lv 29")
end)

t.case("remote death in a linked group: notice, HUD, view", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.catch(0x77, 12, "Zippy")
  local jt = jonas_catches(e, "route-101", 0x99, 15)
  e.step()
  t.eq(e.app.view.groups[1].state, "linked")
  local notes = #e.m.ui.notes
  t.eq(e.m.ui.notes[notes].tone, "info", "catch of others")
  t.ok(e.m.ui.notes[notes].text:find("Jonas caught Spark on Route 101", 1, true))
  -- Jonas' creature faints
  local facts = jt:hp(0x99, 0)
  e.m.run.set_state_for("u-jonas", jt.st)
  local E = require("model.events")
  for _, f in ipairs(facts) do
    local spec = E.from_fact(f, "u-jonas")
    if spec then e.m.run.add_event("u-jonas", spec) end
  end
  e.step()
  local note = e.m.ui.notes[#e.m.ui.notes]
  t.eq(note.tone, "important")
  t.ok(note.text:find("Your linked Zippy is dead too", 1, true), note.text)
  t.eq(note.actions[1].action, "open_run")
  t.eq(note.actions[2].action, "undo_open")
  t.eq(note.actions[2].value, "route-101")
  t.eq(e.app.view.groups[1].state, "dead")
  t.ok(ui_validator.find(e.m.ui.trees.hud, "hud-death"), "HUD expanded")
  t.ok(e.app.view.players[1].mons["00000077"].dead)
  -- HUD returns to compact after the delay
  e.step(4000)
  t.eq(ui_validator.find(e.m.ui.trees.hud, "hud-death"), nil)
  -- undo through the toast action
  e.act("undo_open", "route-101", "toast")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "corr"))
  e.act("corr_submit")
  local corr = events_of(e.m, "soullink.correction")
  t.eq(#corr, 1)
  t.eq(corr[1].source, "manual")
  t.eq(corr[1].payload.kind, "undo_death")
  t.eq(#corr[1].payload.undone, 2)
  t.eq(e.app.view.groups[1].state, "linked")
  t.eq(e.app.ui.corr, nil)
end)

t.case("correction actions post manual events", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.act("missed_open", "route-105")
  t.eq(ui_validator.find(e.m.ui.trees.screen, "corr").title, "Mark Route 105 as missed for you?")
  e.act("corr_submit")
  local c = events_of(e.m, "soullink.correction")[1]
  t.eq(c.payload, { kind = "mark_missed", user = "u-lena", route = "route-105" })
  t.eq(c.source, "manual")
  t.ok(c.text:find("Lena marked Route 105 as missed for Lena", 1, true), c.text)
  t.eq(e.app.view.rows[2].cells["u-lena"].state, "missed")

  -- add by hand with field validation
  e.act("add_open")
  e.act("corr_submit")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "c-error"), "invalid form shows an error")
  e.act("cf:species", "25")
  e.act("cf:level", "7")
  e.act("cf:nickname", "Hand")
  e.act("cf:state", "team")
  e.act("cf:route", "route-105")
  e.act("corr_submit")
  local add = events_of(e.m, "soullink.correction")[2]
  t.eq(add.payload.kind, "add"); t.eq(add.payload.species, 25); t.eq(add.payload.level, 7)
  t.eq(e.app.view.players[1].team[#e.app.view.players[1].team].nickname, "Hand")

  -- Ctrl+D on a caught route: doesn't count, with the mon
  e.catch(0x77, 12, "Zippy")
  e.act("doesnt-count", nil, "hotkey")
  local corr = e.app.ui.corr
  t.eq(corr.kind, "doesnt_count"); t.eq(corr.route, "route-101"); t.eq(corr.mon, "00000077")
  e.act("cf:reason", "dupe")
  e.act("corr_submit")
  local dc = events_of(e.m, "soullink.correction")[3]
  t.eq(dc.payload.reason, "dupe")
  t.eq(e.app.view.rows[1].cells["u-lena"].state, "open")

  -- mark dead from the panel (own team mon)
  e.act("cf:route", "x") -- no form open: ignored
  e.world.team[#e.world.team + 1] = B.rec({ p = 0x55, sp = 33, hp = 20, nick = "Tank" })
  e.act("place_select", "route-102")
  e.catch(0x56, 34, "Tank2")
  e.act("mark_dead", "00000056")
  t.eq(events_of(e.m, "soullink.correction")[4].payload.kind, "mark_dead")
  -- revert
  local seq = events_of(e.m, "soullink.correction")[4].seq
  e.act("revert_open", seq)
  e.act("corr_submit")
  t.eq(events_of(e.m, "soullink.correction")[5].payload.target, seq)
  e.act("corr_cancel")
  t.eq(e.app.ui.corr, nil)
end)

t.case("every correction form and screen tab builds valid trees", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.catch(0x77, 12, "Zippy")
  jonas_catches(e, "route-101", 0x99, 15)
  e.step()
  local forms = {
    { "dc_open", nil }, { "missed_open", "route-101" }, { "undo_open", "route-101" }, { "group_open", "00000077" },
    { "gift_open", "00000077" }, { "dead_open", "00000077" }, { "add_open", nil }, { "revert_open", 1 },
  }
  for _, f in ipairs(forms) do
    e.act(f[1], f[2])
    t.ok(ui_validator.find(e.m.ui.trees.screen, "corr"), f[1])
    -- the panel only carries the "Doesn't count" form; every other correction lives on the run screen
    t.eq(ui_validator.find(e.m.ui.trees.panel, "corr") ~= nil, f[1] == "dc_open", f[1] .. " panel")
    e.act("corr_cancel")
  end
  for tab = 1, 4 do
    e.act("tab", tab)
    t.ok(ui_validator.find(e.m.ui.trees.screen, "tabs").selected == tab)
  end
  for _, a in ipairs({ "rf:open", "rf:done", "rf:all", "lf:manual", "lf:automatic", "lf:all", "grave_toggle", "hud_toggle" }) do e.act(a) end
  e.act("route_select", "route-101")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "route-detail"))
  e.act("place_text", "Secret Cove")
  t.eq(e.m.run.states["u-lena"].place.key, "place:Secret Cove")
  t.eq(ui_validator.find(e.m.ui.trees.panel, "loc").title, "Secret Cove")
  e.act("place_text", "")
  t.eq(e.m.run.states["u-lena"].place.key, nil)
end)

t.case("paused run is read only", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.m.run.current.status = "paused"
  e.step()
  e.catch(0x77, 12, "Zippy")
  t.eq(e.m.run.states["u-lena"].mons["00000077"], nil, "no tracking while paused")
  t.ok(ui_validator.find(e.m.ui.trees.panel, "h-ro"))
  t.eq(ui_validator.find(e.m.ui.trees.panel, "place-picker"), nil)
  local before = #e.m.run.events
  e.act("badges_select", 4)
  e.act("missed_open", "route-105")
  t.eq(#e.m.run.events, before)
  t.eq(e.m.run.states["u-lena"].badges, 0)
end)

t.case("tile strip for a friend's tile", function()
  local e = boot()
  e.act("place_select", "route-101")
  jonas_catches(e, "route-101", 0x99, 15)
  e.step()
  e.m.fire_event("fb", "tiles", { { id = "t1", player = "jonas", game = "x" }, { id = "t2", player = "nobody", game = "x" } })
  e.step()
  t.eq(e.m.ui.trees["tile:t1"].text, "SL Route 101 · 1 alive")
  t.eq(e.m.ui.trees["tile:t2"], nil)
  e.m.fire_event("fb", "tiles", {})
  e.step()
  t.eq(e.m.ui.trees["tile:t1"], nil)
end)

t.case("board: compact tree, at most every 5 s, only when changed", function()
  local e = boot()
  e.act("place_select", "route-101")
  t.ok(e.m.run.board)
  t.ok(ui_validator.validate(e.m.run.board))
  local n = e.m.run.board_sets
  e.step(); e.step()
  t.eq(e.m.run.board_sets, n, "unchanged")
  e.act("badges_select", 2)
  t.eq(e.m.run.board_sets, n, "changed but inside the pause")
  e.step(6000)
  t.eq(e.m.run.board_sets, n + 1)
end)

t.case("ui updates use patch when only props change", function()
  local e = boot()
  e.act("place_select", "route-101")
  local patches = e.app.sync.patches
  e.act("badges_select", 1)
  t.ok(e.app.sync.patches > patches)
end)

t.case("notices: new route hint and rate-limit tolerance", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.act("place_select", "route-102")
  -- manual place changes do not toast; detected ones do
  e.app:note_place("route-103")
  t.ok(e.m.ui.notes[#e.m.ui.notes].text:find("New route: Route 103", 1, true))
  local orig = e.m.fb.ui.notify
  e.m.fb.ui.notify = function() return nil end -- dropped by the rate limit
  e.app:note_place("route-104")
  e.m.fb.ui.notify = orig
end)

t.case("map tab only when the core offers a map", function()
  local screen = require("ui.screen")
  local e = boot()
  e.step()
  t.eq(screen.tab_ids({}), { "routes", "team", "grave", "log" })
  t.eq(screen.tab_ids({ map = { state = "none", live = false } }), { "routes", "team", "grave", "log" }, "run view without a map")
  t.eq(screen.tab_ids({ map = { state = "none", live = true } }), { "routes", "map", "team", "grave", "log" })
  t.eq(screen.tab_ids({ map = { state = "ready", live = false } })[1], "map")
end)

t.case("validator rejects bad trees", function()
  local bad = {
    { type = "foo" }, { type = "text" }, { type = "text", text = "x", color = "red" },
    { type = "column", children = { { type = "text", text = "x", id = "a" }, { type = "text", text = "y", id = "a" } } },
    { type = "text", text = "x", children = {} }, { type = "bar", value = 2 },
    { type = "select", options = { { value = 1, label = "a" } } },
    { type = "segmented", options = { { value = 1, label = "a" } }, action = "x" },
    { type = "tabs", tabs = { "a" }, children = { { type = "text", text = "1" }, { type = "text", text = "2" } } },
    { type = "table", columns = { "a" }, rows = { { cells = { "1", "2" } } } },
    { type = "avatar", initial = "TOOLONG" },
  }
  for i, tree in ipairs(bad) do t.ok(not ui_validator.validate(tree), "tree " .. i) end
  t.ok(ui_validator.validate({ type = "column", children = { { type = "text", text = "ok" } } }))
end)

t.case("i18n: every static key used in the sources exists in en and de", function()
  local en = mock.read_json_flat(io.open("plugin/i18n/en.json"):read("a"))
  local de = mock.read_json_flat(io.open("plugin/i18n/de.json"):read("a"))
  local p = assert(io.popen("ls src/*/*.lua src/*.lua"))
  for path in p:lines() do
    local src = io.open(path):read("a")
    for key in src:gmatch('tr%("([%w_]+)"') do
      if not key:find("_$") then
        t.ok(en[key], path .. ": en lacks " .. key)
        t.ok(de[key], path .. ": de lacks " .. key)
      end
    end
    for key in src:gmatch('common%.empty%(%w+, "([%w_]+)", "([%w_]+)"') do t.ok(en[key]) end
    for a, b in src:gmatch('common%.empty%(%w+, "([%w_]+)", "([%w_]+)"') do t.ok(en[a] and en[b], a .. "/" .. b) end
  end
  p:close()
  -- dynamic families
  local families = {
    c_title_ = { "doesnt_count", "undo_death", "set_group", "add", "mark_missed", "mark_dead", "set_gift", "revert" },
    c_submit_ = { "doesnt_count", "undo_death", "set_group", "add", "mark_missed", "mark_dead", "set_gift", "revert" },
    ev_c_ = { "doesnt_count", "undo_death", "set_group", "add", "mark_missed", "mark_dead", "set_gift", "revert" },
    c_confirm_title_ = { "undo_death", "mark_dead", "mark_missed", "revert" },
    c_confirm_text_ = { "undo_death", "mark_dead", "mark_missed", "revert" },
    group_state_ = { "linked", "open", "dead", "broken", "gift", "nolink" },
    hud_status_ = { "open", "encounter", "caught", "missed", "no_route", "unknown" },
    ev_why_ = { "extra", "dupe", "shiny", "additional", "gift", "no_place", "horde", "used", "type" },
    run_status_ = { "starting", "active", "paused", "finished", "abandoned" },
    run_readonly_ = { "paused", "finished", "abandoned" },
    cause_ = { "own", "linked", "nil", "doa" },
    source_ = { "automatic", "manual", "hub" },
    mode_ = { "nuzlocke", "soullink" },
    tab_ = { "map", "routes", "team", "grave", "log" },
    log_type_ = { "soullink_catch", "soullink_death", "soullink_encounter", "soullink_place", "soullink_correction" },
    loc_ = { "open", "encounter", "caught", "missed", "no_route", "unknown" },
  }
  for prefix, names in pairs(families) do
    for _, n in ipairs(names) do
      t.ok(en[prefix .. n], "en lacks " .. prefix .. n)
      t.ok(de[prefix .. n], "de lacks " .. prefix .. n)
    end
  end
end)

t.case("panel team rows: hp bar, partners; mark dead lives on the screen", function()
  local e = boot()
  e.act("place_select", "route-101")
  e.world.team[#e.world.team + 1] = B.rec({ p = 0x77, sp = 12, nick = "Zippy", hp = 15, lv = 9 })
  e.world.team[#e.world.team].max_hp = 30
  e.full_poll()
  jonas_catches(e, "route-101", 0x99, 15)
  e.step()
  local panel = e.m.ui.trees.panel
  local mon = ui_validator.find(panel, "mon1")
  t.ok(mon, "team row")
  t.eq(ui_validator.find(panel, "m-hp1").value, 0.5)
  t.ok(ui_validator.find(panel, "m-p1-2") or ui_validator.find(panel, "m-p1-1"), "partner avatar")
  t.ok(find_text(panel, "Zippy · Lv 9"))
  t.eq(ui_validator.find(panel, "m-dead1"), nil, "no inline 5f actions in the panel")
  -- the screen's Team & box tab has the button (with the danger confirm)
  e.act("tab", 3)
  local btn = ui_validator.find(e.m.ui.trees.screen, "tm-d1")
  t.ok(btn, "button on the screen")
  t.eq(btn.action, "dead_open"); t.eq(btn.value, "00000077")
  e.act("dead_open", "00000077")
  t.ok(ui_validator.find(e.m.ui.trees.screen, "corr").title)
  t.eq(ui_validator.find(e.m.ui.trees.screen, "corr-submit").confirm.danger, true)
  e.act("corr_submit")
  e.act("grave_toggle")
  t.ok(ui_validator.find(e.m.ui.trees.panel, "grave-list"))
end)

t.case("package builds and verifies", function()
  local ok = os.execute("python3 -c 'import sys' >/dev/null 2>&1")
  if not ok then return t.skip("python3 not available") end
  local dir = os.tmpname() .. ".d"
  local ok2 = os.execute("python3 -I tools/package.py --out " .. dir .. " --tag v0.8.1 >/dev/null && python3 -I tools/package.py --verify " .. dir .. "/uzume.soullink-0.8.1.fbplugin >/dev/null")
  t.ok(ok2, "package.py failed")
  local bad = os.execute("python3 -I tools/package.py --out " .. dir .. " --tag v9.9.9 >/dev/null 2>&1")
  t.ok(not bad, "tag/version mismatch must fail")
  os.execute("rm -rf " .. dir)
end)
