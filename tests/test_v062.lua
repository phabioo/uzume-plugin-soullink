-- v0.6.2: corrections and detection agree (a route reopened / marked missed / added by hand is seen
-- the same way by the view and by detection), icon check in the "Game data" block. Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local detect = require("model.detect")
local corrections = require("model.corrections")
local view_mod = require("model.view")

local R1, R2 = "route-101", "route-102"

local function cell(log, run, cfg, trackers, route, uid)
  local v = view_mod.view(run, B.states(table.unpack(trackers)), log.events, cfg)
  for _, row in ipairs(v.rows) do
    if row.route == route then return row.cells[uid], v end
  end
  return nil, v
end

local function setup(names, mode, over)
  local run = B.run(names)
  local cfg = B.cfg(mode or "nuzlocke", over)
  local log = B.log()
  local tr = B.tracker(run.me, cfg, log)
  tr:start()
  tr:place(R1)
  return run, cfg, log, tr
end

t.case("Fabio: encounter without balls, doesn't count, later encounter counts and the catch lands", function()
  local run, cfg, log, tr = setup({ "Lena" })
  local f = tr:battle(930)
  t.ok(B.fact(f, "encounter").counts, "first encounter counts")
  tr:end_battle() -- no ball: the encounter is missed
  t.eq(tr.st.routes[R1].status, "missed")
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "missed")
  log:add(run.me, corrections.doesnt_count({ user = run.me, route = R1 }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "open", "route shows open again")
  -- back with balls: new wild encounter on the same route
  f = tr:battle(931)
  local e = B.fact(f, "encounter")
  t.ok(e.counts and not e.why, "new encounter counts as the first one")
  t.eq(tr.st.routes[R1].status, "encounter")
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "encounter", "shown while pending")
  tr:end_battle_only()
  f = tr:catch(0xC1, 931, { team = true })
  local c = B.fact(f, "catch")
  t.ok(c.counts and c.route == R1 and not c.why, "catch counted on the route")
  t.eq(tr.st.routes[R1].status, "caught")
  local cl = cell(log, run, cfg, { tr }, R1, run.me)
  t.eq(cl.state, "caught"); t.eq(cl.mon, "000000c1")
  -- a further encounter on the route is used again (rule: first encounter only)
  tr:end_battle_only()
  f = tr:battle(932)
  t.eq(B.fact(f, "encounter").why, "used")
end)

t.case("doesn't count while the encounter is still pending: no stale missed fact, the catch is the new first", function()
  local run, cfg, log, tr = setup({ "Lena" })
  tr:battle(930)
  tr:end_battle_only()
  log:add(run.me, corrections.doesnt_count({ user = run.me, route = R1 }))
  local f = tr:wait(detect.PENDING_MS + 1000)
  t.eq(B.count(f, "missed"), 0, "the hidden encounter does not expire as missed")
  f = tr:battle(931)
  t.ok(B.fact(f, "encounter").counts)
  tr:end_battle_only()
  f = tr:catch(0xC2, 931)
  t.ok(B.fact(f, "catch").counts)
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "caught")
end)

t.case("revert of the correction restores the old route state and the old detection", function()
  local run, cfg, log, tr = setup({ "Lena" })
  tr:battle(930); tr:end_battle()
  local seq = log:add(run.me, corrections.doesnt_count({ user = run.me, route = R1 }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "open")
  log:add(run.me, corrections.revert({ target = seq }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "missed", "view back to missed")
  local f = tr:battle(931)
  t.eq(B.fact(f, "encounter").why, "used", "detection agrees: route is used")
end)

t.case("mark_missed: a later encounter is not the first; doesn't count after it reopens", function()
  local run, cfg, log, tr = setup({ "Lena" })
  local seq = log:add(run.me, corrections.mark_missed({ user = run.me, route = R1 }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "missed")
  local f = tr:battle(930)
  t.eq(B.fact(f, "encounter").why, "used", "route was marked missed")
  t.ok(not B.fact(f, "encounter").counts)
  tr:end_battle_only()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "missed")
  -- reopened later: the next encounter counts
  log:add(run.me, corrections.doesnt_count({ user = run.me, route = R1 }))
  f = tr:battle(931)
  t.ok(B.fact(f, "encounter").counts)
  -- revert of mark_missed alone (fresh run): open route
  local run2, cfg2, log2, tr2 = setup({ "Lena" })
  local s2 = log2:add(run2.me, corrections.mark_missed({ user = run2.me, route = R1 }))
  log2:add(run2.me, corrections.revert({ target = s2 }))
  tr2:step()
  f = tr2:battle(930)
  t.ok(B.fact(f, "encounter").counts, "reverted mark_missed leaves the route open")
end)

t.case("doesn't count on the caught mon reopens the route; the dupes clause forgets the excluded mon", function()
  local run, cfg, log, tr = setup({ "Lena" })
  tr:battle(940); tr:end_battle_only()
  tr:catch(0xD1, 940)
  t.eq(tr.st.routes[R1].status, "caught")
  log:add(run.me, corrections.doesnt_count({ user = run.me, mon = "000000d1", route = R1 }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "open")
  local f = tr:battle(941)
  t.ok(B.fact(f, "encounter").counts, "route is open for a new first encounter")
  tr:end_battle_only()
  f = tr:catch(0xD2, 941)
  t.ok(B.fact(f, "catch").counts)
  -- the same line on another route: the excluded mon does not make it a dupe
  tr:place(R2)
  tr:battle(940); tr:end_battle_only()
  f = tr:catch(0xD3, 940)
  local c = B.fact(f, "catch")
  t.ok(c.counts and c.route == R2 and not c.why, "excluded mon is not part of the dupes check")
end)

t.case("add by hand holds the route for detection too", function()
  local run, cfg, log, tr = setup({ "Lena" })
  log:add(run.me, corrections.add({ user = run.me, route = R1, species = 77, state = "box" }))
  tr:step()
  t.eq(cell(log, run, cfg, { tr }, R1, run.me).state, "caught")
  local f = tr:battle(930)
  t.eq(B.fact(f, "encounter").why, "used")
  tr:end_battle_only()
  f = tr:catch(0xE1, 930)
  t.eq(B.fact(f, "catch").why, "extra", "the hand-added mon is the route's mon")
  -- doesn't count on the hand-added mon reopens the route
  local run2, cfg2, log2, tr2 = setup({ "Lena" })
  local aseq = log2:add(run2.me, corrections.add({ user = run2.me, route = R1, species = 77, state = "box" }))
  log2:add(run2.me, corrections.doesnt_count({ user = run2.me, mon = "add-" .. aseq }))
  tr2:step()
  t.eq(cell(log2, run2, cfg2, { tr2 }, R1, run2.me).state, "open")
  f = tr2:battle(930)
  t.ok(B.fact(f, "encounter").counts)
end)

t.case("rule off (every encounter counts): a reopened route still starts a fresh entry", function()
  local run, cfg, log, tr = setup({ "Lena" }, "nuzlocke", { first_encounter_only = false })
  tr:battle(930); tr:end_battle()
  log:add(run.me, corrections.doesnt_count({ user = run.me, route = R1 }))
  tr:step()
  tr:battle(931); tr:end_battle_only()
  local f = tr:catch(0xF1, 931)
  t.ok(B.fact(f, "catch").counts and tr.st.routes[R1].status == "caught")
end)

t.case("SoulLink with 2 players: a route reopened for one player keeps the link group correct", function()
  local run, cfg, log, lena = setup({ "Lena", "Jonas" }, "soullink")
  local jonas = B.tracker("u-jonas", cfg, log)
  jonas:start(); jonas:place(R1)
  -- Jonas catches on the route right away
  jonas:battle(950); jonas:end_battle_only(); jonas:catch(0xA1, 950)
  -- Lena meets something without balls, it is missed, she says it doesn't count
  lena:battle(930); lena:end_battle()
  local grp = view_mod.view(run, B.states(lena, jonas), log.events, cfg).groups[1]
  t.eq(grp.state, "broken", "missed for Lena breaks the group")
  log:add("u-jonas", corrections.doesnt_count({ user = run.me, route = R1 })) -- author Jonas, about Lena
  lena:step(); jonas:step()
  grp = view_mod.view(run, B.states(lena, jonas), log.events, cfg).groups[1]
  t.eq(grp.state, "open", "pending again: Lena has no catch yet")
  t.eq(jonas.st.routes[R1].status, "caught", "Jonas is untouched")
  lena:battle(931); lena:end_battle_only(); lena:catch(0xB5, 931)
  local v = view_mod.view(run, B.states(lena, jonas), log.events, cfg)
  t.eq(v.groups[1].state, "linked", "both caught: linked")
  t.eq(v.groups[1].count, 2)
  -- a correction about Lena never changes Jonas' detection
  local f = jonas:battle(951)
  t.eq(B.fact(f, "encounter").why, "used")
end)

t.case("state stored by 0.6.1 (no reset stamps) loads: the correction already in the log applies at once", function()
  local run, cfg = B.run({ "Lena" }), B.cfg("nuzlocke")
  local old = { v = 1, started = true, inb = false, game = {}, place = { key = R1, manual = true }, baseline = { ["000000b1"] = true },
    mons = {}, routes = { [R1] = { status = "missed", species = 930, kind = "wild" } }, order = {}, badges = 0,
    names = { sp = {}, loc = {} }, enc_seq = 0 }
  local events = { { seq = 4, user_id = run.me, type = "soullink.correction", source = "manual",
    payload = corrections.doesnt_count({ user = run.me, route = R1 }).payload } }
  local v = view_mod.view(run, { [run.me] = old }, events, cfg)
  t.eq(v.rows[1].cells[run.me].state, "open")
  local ov, ex = corrections.route_overrides(corrections.effective(events), run.me, old)
  local snap = { team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }) }, boxes = { {} },
    battle = { active = true, wild = true, foes = { B.rec({ p = 0xF00D, sp = 931 }) } } }
  local st, facts = detect.diff(old, snap, cfg, { overrides = ov, excluded = ex })
  t.ok(B.fact(facts, "encounter").counts)
  t.eq(st.routes[R1].status, "encounter"); t.eq(st.routes[R1].rs, 4)
  -- without overrides (old behaviour) the same state still works
  local st2, f2 = detect.diff(old, snap, cfg, {})
  t.eq(B.fact(f2, "encounter").why, "used")
  t.eq(st2.routes[R1].status, "missed")
end)

-- ---------------------------------------------------------------- controller

local function boot(world)
  local run = B.run({ "Lena" }, B.no_balls_rule())
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, video = true })
  local core = fake_core.new(world)
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, app = app, run = run }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.act(a, v) m.action(a, v, "panel"); env.step(300) end
  function env.find(id) return ui_validator.find(m.ui.trees.screen, id) end
  return env
end

t.case("controller: the Fabio scenario with encounters() of the core", function()
  local e = boot()
  e.step(); e.step()
  local K = "loc:301"
  e.core:encounter({ species = 910 })
  e.step()
  t.eq(e.m.uz.run.state().routes[K].status, "encounter")
  e.m.uz.run.event(corrections.doesnt_count({ user = e.run.me, route = K }))
  e.step()
  e.core:encounter({ species = 911 })
  e.step()
  local r = e.m.uz.run.state().routes[K]
  t.ok(r.status == "encounter" and r.species == 911 and r.rs, "the new encounter is the first one")
  local found
  for _, ev in ipairs(e.m.uz.run.events(0, 200)) do
    if ev.type == "soullink.encounter" and ev.payload.species == 911 then found = ev end
  end
  t.ok(found and found.payload.counts, "event says it counts")
  table.insert(e.core.world.box, B.rec({ p = 0x1234, sp = 911, hp = 30, nick = "Fresh" }))
  e.step(6000); e.step()
  r = e.m.uz.run.state().routes[K]
  t.eq(r.status, "caught"); t.eq(r.mon, "00001234")
  t.eq(e.app.view.players[1].place.status, "caught")
end)

-- ---------------------------------------------------------------- icon check

local function open_diag(e)
  e.step(); e.step(6000)
  e.act("diag_toggle")
  e.step(6000)
end

t.case("icon check: 4 variants of the first team creature, shown only while the Game data block is open", function()
  local e = boot()
  e.step(); e.step(6000)
  t.eq(e.find("diag-ic-row"), nil, "closed: nothing")
  t.eq(e.core.world.calls.icon_variants, nil, "not asked while closed")
  e.act("diag_toggle")
  e.step(6000)
  local row = e.find("diag-ic-row")
  t.ok(row and #row.children == 4, "four variants side by side")
  t.eq(e.find("diag-ic-title").text, "Icon check")
  t.eq(e.find("diag-ic-hint").text, "Tell us which picture looks right")
  local img = e.find("diag-ic-img-B")
  t.eq(img.src, "cache:diag/icon-B.png"); t.eq(img.size, "m")
  t.eq(e.m.cache_files["diag/icon-B.png"], "PNG-B-900-0", "png written to the cache, first team creature")
  t.ok(e.find("diag-ic-desc-C").text:find("variant C", 1, true))
  e.step(6000); e.step(6000); e.step(6000)
  t.eq(e.core.world.calls.icon_variants, 1, "asked once per opening")
  e.act("diag_toggle"); e.step(6000)
  t.eq(e.find("diag-ic-row"), nil, "hidden when closed")
  e.act("diag_toggle"); e.step(6000)
  t.eq(e.core.world.calls.icon_variants, 2, "asked again at the next opening")
  t.ok(e.find("diag-ic-row"))
end)

t.case("icon check: hidden with an older core, retried while not ready", function()
  local e = boot()
  e.core:off("icon_variants", "unsupported")
  open_diag(e)
  t.eq(e.find("diag-ic-row"), nil); t.eq(e.find("diag-ic-title"), nil)
  t.ok(e.find("diag-hint"), "the rest of the block is unaffected")
  e.step(6000); e.step(6000)
  t.eq(e.core.world.calls.icon_variants, 1, "unsupported is not asked again")

  local e2 = boot({ variants = { scan = 2, count = 2 } })
  open_diag(e2)
  e2.step(6000); e2.step(6000); e2.step(6000)
  local row = e2.find("diag-ic-row")
  t.ok(row and #row.children == 2, "shown once the core is ready")
end)
