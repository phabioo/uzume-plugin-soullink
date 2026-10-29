-- uz.save.snapshot("before Gym N") when a gym leader battle starts (synthetic data only).
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local controller = require("app.controller")
local gym = require("model.gym")
local oras = require("data.oras")

local function battle(kind, levels, active)
  local foes = {}
  for i, l in ipairs(levels) do foes[i] = { species = 900 + i, level = l } end
  return { active = active ~= false, kind = kind, foes = foes }
end

t.case("gym_number: trainer battle with a foe at the cap of the next gym", function()
  local cap = oras.level_cap
  t.eq(gym.gym_number(battle("trainer", { 12, cap(0) }), 0, cap), 1)
  t.eq(gym.gym_number(battle("trainer", { cap(3) + 2 }), 3, cap), 4)
  t.eq(gym.gym_number(battle("trainer", { cap(7) }), 7, cap), 8)
  t.eq(gym.gym_number(battle("trainer", { cap(0) - 1 }), 0, cap), nil, "a gym trainer stays below the cap")
  t.eq(gym.gym_number(battle("wild", { 99 }), 0, cap), nil)
  t.eq(gym.gym_number(battle("trainer", { 99 }, false), 0, cap), nil)
  t.eq(gym.gym_number(battle("trainer", { 99 }), 8, cap), nil, "all badges: no gym left")
  t.eq(gym.gym_number(battle("trainer", { 99 }), nil, cap), nil)
  t.eq(gym.gym_number(battle("trainer", {}), 0, cap), nil)
  t.eq(gym.gym_number(nil, 0, cap), nil)
  t.eq(gym.gym_number({ active = true, kind = "trainer", foes = { { level = "x" } } }, 0, cap), nil)
end)

local function boot(opts)
  opts = opts or {}
  local run = B.run({ "Lena", "Jonas" })
  run.settings = opts.settings or {}
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, save = opts.save })
  local world = { team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }) }, box = {}, battle = { active = false },
    badges = { count = opts.badges or 0 } }
  m.set_provider("pokemon.core", {
    team = function() return world.team end,
    box_count = function() return 1 end,
    box = function() return world.box end,
    battle = function() return world.battle end,
    badges = function() return world.badges end,
  })
  local app = controller.new(m.uz)
  app:start()
  local function step(ms) m.advance(ms or 600); m.tick(1) end
  return { m = m, world = world, app = app, step = step }
end

t.case("one snapshot per gym, labelled with the gym number", function()
  local e = boot{ save = true, badges = 2 }
  e.step()
  t.eq(e.m.snapshots, {})
  e.world.battle = battle("trainer", { 20, oras.level_cap(2) })
  e.step(); e.step(); e.step()
  t.eq(e.m.snapshots, { "before Gym 3" })
  e.world.battle = { active = false }
  e.step()
  e.world.battle = battle("trainer", { oras.level_cap(2) })
  e.step()
  t.eq(#e.m.snapshots, 2, "a repeated attempt after the battle ended is saved again, but only once per attempt")
  e.world.badges = { count = 3 }
  e.step(); e.step()
  e.world.battle = battle("trainer", { oras.level_cap(3) })
  e.step()
  t.eq(e.m.snapshots, { "before Gym 3", "before Gym 3", "before Gym 4" })
end)

t.case("wild battles and low-level trainers never snapshot", function()
  local e = boot{ save = true, badges = 0 }
  e.world.battle = battle("wild", { 99 })
  e.step(); e.step()
  e.world.battle = battle("trainer", { 5, 6 })
  e.step(); e.step()
  t.eq(e.m.snapshots, {})
end)

t.case("German reason", function()
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ language = "de", run = { current = run }, game = { code = "000400000011C400", language = "de" }, save = true })
  m.set_provider("pokemon.core", { team = function() return {} end, box_count = function() return 1 end,
    box = function() return {} end, battle = function() return battle("trainer", { 99 }) end,
    badges = function() return { count = 0 } end })
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(1)
  t.eq(m.snapshots, { "vor Arena 1" })
end)

t.case("an older app without uz.save: no error, no retries", function()
  local e = boot{ badges = 0 }
  t.eq(e.m.uz.save, nil)
  e.world.battle = battle("trainer", { 99 })
  e.step(); e.step(); e.step()
  t.eq(e.m.snapshots, {})
  t.eq(e.app.save_missing, true)
  for _, l in ipairs(e.m.logs) do t.ok(not l.text:find("snapshot", 1, true), l.text) end
end)

t.case("a refusing uz.save (rate limit) is retried a few times, then given up, with one log line", function()
  local e = boot{ save = { refuse = "rate limited" }, badges = 0 }
  e.world.battle = battle("trainer", { 99 })
  for _ = 1, 10 do e.step() end
  t.eq(e.m.snapshot_refusals, gym.MAX_ATTEMPTS)
  local n = 0
  for _, l in ipairs(e.m.logs) do if l.text:find("save snapshot refused", 1, true) then n = n + 1 end end
  t.eq(n, 1)
end)

t.case("a throwing uz.save.snapshot does not break polling", function()
  local e = boot{ save = true, badges = 0 }
  e.m.uz.save.snapshot = function() error("boom") end
  e.world.battle = battle("trainer", { 99 })
  e.step(); e.step()
  t.eq(e.app.errors.poll, nil)
  e.world.team[2] = B.rec({ p = 0xB3, sp = 901, hp = 30 })
  e.step()
  t.ok(e.m.run.states["u-lena"] ~= nil)
end)

t.case("the run view (read only) never snapshots", function()
  local run = B.run({ "Lena" })
  run.view = true
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400" }, save = true })
  m.set_provider("pokemon.core", { battle = function() return battle("trainer", { 99 }) end })
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(3)
  t.eq(m.snapshots, {})
end)

-- v0.9.5: Elite Four / champion stages, retry after a lost gym fight, run rule.
t.case("stage: Elite Four and champion with all eight badges", function()
  local cap, el = oras.level_cap, oras.ELITE_CAPS
  t.eq({ gym.stage(battle("trainer", { 20, el.elite4 }), 8, cap, el) }, { "elite4", 1 })
  t.eq({ gym.stage(battle("trainer", { el.champion }), 8, cap, el) }, { "champion", 1 })
  t.eq({ gym.stage(battle("trainer", { el.elite4 - 1 }), 8, cap, el) }, {})
  t.eq({ gym.stage(battle("wild", { 99 }), 8, cap, el) }, {})
  t.eq({ gym.stage(battle("trainer", { 99 }), 7, cap, el) }, { "gym", 8 })
  t.eq({ gym.stage(battle("trainer", { 99 }), 5, cap, nil) }, { "gym", 6 })
end)

t.case("snapshot before Elite Four and Champion, once per stage and session", function()
  local e = boot{ save = true, badges = 8 }
  e.world.battle = battle("trainer", { oras.ELITE_CAPS.elite4 })
  e.step(); e.step()
  e.world.battle = { active = false }
  e.step()
  e.world.battle = battle("trainer", { oras.ELITE_CAPS.elite4 })
  e.step(); e.step()
  t.eq(e.m.snapshots, { "before Elite Four" })
  e.world.battle = battle("trainer", { oras.ELITE_CAPS.champion })
  e.step(); e.step()
  t.eq(e.m.snapshots, { "before Elite Four", "before Champion" })
end)

t.case("German Elite Four and champion reasons", function()
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ language = "de", run = { current = run }, game = { code = "000400000011C400", language = "de" }, save = true })
  m.set_provider("pokemon.core", { team = function() return {} end, box_count = function() return 1 end,
    box = function() return {} end, battle = function() return battle("trainer", { oras.ELITE_CAPS.champion }) end,
    badges = function() return { count = 8 } end })
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(1)
  t.eq(m.snapshots, { "vor dem Champ" })
end)

t.case("a lost gym fight is snapshotted again on the next attempt, once per attempt", function()
  local e = boot{ save = true, badges = 2 }
  e.world.battle = battle("trainer", { oras.level_cap(2) })
  e.step(); e.step(); e.step()
  t.eq(e.m.snapshots, { "before Gym 3" })
  e.world.battle = { active = false } -- lost, no new badge
  e.step()
  e.world.battle = battle("trainer", { oras.level_cap(2) })
  e.step(); e.step(); e.step()
  t.eq(e.m.snapshots, { "before Gym 3", "before Gym 3" })
end)

t.case("run rule gym_snapshots off: no snapshots", function()
  local e = boot{ save = true, badges = 2, settings = { ["uzume.soullink"] = { rules = { gym_snapshots = false } } } }
  e.world.battle = battle("trainer", { oras.level_cap(2) })
  e.step(); e.step(); e.step()
  t.eq(e.m.snapshots, {})
  t.eq(require("model.rules").defaults().gym_snapshots, true)
end)
