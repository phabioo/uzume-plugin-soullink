-- v0.9.3: rule "Encounters count only once you have Poke Balls" (balls_required). Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local rules = require("model.rules")
local corrections = require("model.corrections")
local view_mod = require("model.view")
local json = require("json")

local R1 = "route-101"
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end

local function setup(over)
  local run = B.run({ "Lena" })
  local cfg = B.cfg("nuzlocke", over)
  local log = B.log()
  local tr = B.tracker(run.me, cfg, log)
  tr:start()
  tr:place(R1)
  return run, cfg, log, tr
end
local ON = { balls_required = true }

t.case("rule: default on, parsed, in the manifest and both languages", function()
  t.eq(rules.defaults().balls_required, true)
  t.eq(rules.parse(B.run({ "Lena" })).rules.balls_required, true)
  local off = rules.parse(B.run({ "Lena" }, { ["uzume.soullink"] = { rules = { balls_required = false } } }))
  t.eq(off.rules.balls_required, false)
  local found
  for _, r in ipairs(json.decode(read("plugin/manifest.json")).run_settings) do
    if r.key == "rules.balls_required" then found = r end
  end
  t.ok(found and found.default == true)
  for _, lang in ipairs({ "en", "de" }) do
    local tr = json.decode(read("plugin/i18n/" .. lang .. ".json"))
    for _, k in ipairs({ "rs_balls_required", "rs_balls_required_hint", "balls_hint", "balls_have", "loc_no_balls",
        "ev_why_no_balls", "reopen_route", "c_title_reopen", "c_title_reopen_route", "c_reopen_text",
        "c_submit_reopen", "ev_c_reopen" }) do
      t.ok(tr[k] and tr[k] ~= "", lang .. " has " .. k)
    end
  end
end)

t.case("no balls: not counted, route not used, not missed afterwards", function()
  local run, cfg, log, tr = setup(ON)
  local f = tr:battle(930)
  local e = B.fact(f, "encounter")
  t.eq(e.counts, false); t.eq(e.why, "no_balls")
  t.eq(tr.st.routes[R1], nil)
  local more = tr:end_battle()
  t.eq(B.fact(more, "missed"), nil)
  t.eq(tr.st.routes[R1], nil)
  -- the next encounter without balls is not counted either
  t.eq(B.fact(tr:battle(931), "encounter").why, "no_balls")
end)

t.case("rule off: the first encounter counts as before", function()
  local _, _, _, tr = setup({ balls_required = false })
  t.eq(B.fact(tr:battle(930), "encounter").counts, true)
  t.eq(tr.st.routes[R1].status, "encounter")
end)

t.case("balls reported by the core (opts.balls) set the flag for good", function()
  local _, _, _, tr = setup(ON)
  tr.opts.balls = true
  t.eq(B.fact(tr:battle(930), "encounter").counts, true)
  t.eq(tr.st.balls, true)
  tr.opts.balls = nil
  tr:end_battle()
  t.eq(tr.st.balls, true, "stays true")
end)

t.case("a catch without the flag counts normally and sets it", function()
  local _, _, _, tr = setup(ON)
  t.eq(B.fact(tr:battle(930), "encounter").why, "no_balls")
  tr:end_battle_only()
  local c = B.fact(tr:catch(0x5000, 930), "catch")
  t.eq(c.counts, true)
  t.eq(tr.st.routes[R1].status, "caught")
  t.eq(tr.st.balls, true)
end)

t.case("starter counts before the first ball and does not set the flag", function()
  local tr = B.tracker("u-a", B.cfg("soullink", ON), nil)
  local c = B.fact(tr:start({ 0x1234 }), "catch")
  t.eq(c.starter, true); t.eq(c.counts, true); t.eq(c.why, nil)
  t.eq(tr.st.routes.starter.kind, "starter")
  t.eq(tr.st.routes.starter.status, "caught")
  t.eq(tr.st.balls, nil, "a gift implies no ball")
  tr:place(R1)
  t.eq(B.fact(tr:battle(930), "encounter").why, "no_balls")
  -- a gift egg does not set it either
  tr:end_battle()
  tr:catch(0x6000, 940, { egg = true })
  t.eq(tr.st.balls, nil)
end)

t.case("reopen: an automatically missed route is open again for its next encounter", function()
  local run, cfg, log, tr = setup({ balls_required = false })
  tr:battle(930); tr:end_battle()
  t.eq(tr.st.routes[R1].status, "missed")
  local v = view_mod.view(run, B.states(tr), log.events, cfg)
  local cell
  for _, row in ipairs(v.rows) do if row.route == R1 then cell = row.cells[run.me] end end
  t.eq(cell.state, "missed"); t.eq(cell.auto, true)
  local spec = corrections.reopen({ user = run.me, route = R1 })
  t.ok(corrections.validate_spec(spec))
  log:add(run.me, spec)
  v = view_mod.view(run, B.states(tr), log.events, cfg)
  for _, row in ipairs(v.rows) do if row.route == R1 then cell = row.cells[run.me] end end
  t.eq(cell.state, "open")
  local e = B.fact(tr:battle(931), "encounter")
  t.eq(e.counts, true, "the next encounter is the first again")
end)

-- ---------------------------------------------------------------- controller

local function boot(world, nocore_balls)
  local run = B.run({ "Lena" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, video = true })
  local core = fake_core.new(world)
  if nocore_balls then core.provider.balls = nil end
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, app = app, run = run }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.act(a, v) m.action(a, v, "panel"); env.step(300) end
  function env.state() return m.uz.run.state() end
  return env
end

t.case("controller: no balls, then core balls() > 0 counts the next encounter", function()
  local e = boot()
  e.step(); e.step()
  e.core:encounter({ species = 910 })
  e.step()
  t.eq(e.state().routes["loc:301"], nil, "not counted")
  t.ok(not e.state().balls)
  local p = e.m.ui.trees.panel
  t.ok(ui_validator.validate(p))
  t.ok(ui_validator.find(p, "balls-have") and ui_validator.find(p, "balls-text"))
  t.eq(ui_validator.find(p, "loc").sub, "Not counted: no Poké Balls yet")
  e.core.world.balls = { count = 5 }
  e.step(6000)
  e.core:encounter({ species = 911 })
  e.step()
  t.eq(e.state().balls, true)
  t.eq(e.state().routes["loc:301"].species, 911)
  t.eq(ui_validator.find(e.m.ui.trees.panel, "balls-have"), nil)
end)

t.case("controller: a core without balls() works; the manual action sets the flag, persisted over a restart", function()
  local e = boot(nil, true)
  e.step(); e.step()
  e.core:encounter({ species = 910 })
  e.step(6000)
  t.eq(e.state().routes["loc:301"], nil)
  e.act("have_balls")
  t.eq(e.state().balls, true)
  t.ok(ui_validator.validate(e.m.ui.trees.panel))
  t.eq(ui_validator.find(e.m.ui.trees.panel, "balls-have"), nil)
  e.core:encounter({ species = 911 })
  e.step()
  t.eq(e.state().routes["loc:301"].species, 911)
  local app2 = controller.new(e.m.uz)
  app2:start()
  e.step()
  t.eq(app2.st.balls, true, "flag survives a restart")
end)

t.case("controller: reopen offered for an automatically missed route", function()
  local e = boot()
  e.step(); e.step()
  e.act("have_balls")
  e.core:encounter({ species = 910 })
  e.core.world.battle = { active = true, kind = "wild", wild = true, foes = {} }
  e.step()
  e.core.world.battle = { active = false }
  e.step(); e.step(70000)
  t.eq(e.state().routes["loc:301"].status, "missed")
  local p = e.m.ui.trees.panel
  t.ok(ui_validator.validate(p))
  t.ok(ui_validator.find(p, "reopen"))
  e.act("reopen_open", "loc:301")
  t.eq(e.app.ui.corr.kind, "reopen")
  e.act("corr_submit")
  local posted
  for _, ev in ipairs(e.m.run.events) do
    if ev.type == "soullink.correction" and ev.payload.kind == "reopen" then posted = ev end
  end
  t.ok(posted and posted.payload.route == "loc:301")
  e.step()
  t.eq(e.app.view.players[1].place.status, "open")
end)
