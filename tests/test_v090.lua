-- v0.9.0: recap manifest block and the automatic badge event. Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local controller = require("app.controller")
local json = require("json")
local events = require("model.events")

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end

local function boot(run_events)
  local run = B.run({ "Lena", "Jonas" })
  run.settings = {}
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
  local world = { team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }), B.rec({ p = 0xB2, sp = 901, hp = 30 }) },
    box = {}, badges = { count = 0, flags = {} } }
  m.set_provider("pokemon.core", {
    team = function() return world.team end,
    box_count = function() return 1 end,
    box = function() return world.box end,
    badges = function() return world.badges end,
  })
  for _, ev in ipairs(run_events or {}) do m.run.add_event("u-lena", ev) end
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, world = world, app = app }
  function env.poll() m.advance(6000); m.tick(1) end
  function env.set_badges(n) world.badges = { count = n, flags = {} }; env.poll() end
  return env
end

local function badge_events(m)
  local out = {}
  for _, ev in ipairs(m.run.events) do if ev.type == "soullink.badge" then out[#out + 1] = ev end end
  return out
end

t.case("manifest: recap block maps catch, death, badge, correction", function()
  local m = json.decode(read("plugin/manifest.json"))
  t.eq(m.version, "0.9.1")
  t.eq(m.recap, {
    { type = "soullink.catch", glyph = "catch" },
    { type = "soullink.death", glyph = "lost" },
    { type = "soullink.badge", glyph = "badge" },
    { type = "soullink.correction", glyph = "note" },
  })
  local glyphs = { catch = true, lost = true, badge = true, note = true, screenshot = true }
  for _, r in ipairs(m.recap) do
    t.ok(r.type:match("^[a-z0-9_.-]+$") and #r.type <= 64)
    t.ok(glyphs[r.glyph])
  end
end)

t.case("badge event: payload and text, no names", function()
  local spec = events.from_fact({ kind = "badge", index = 2, count = 2 }, "u-lena")
  t.eq(spec, { type = "soullink.badge", payload = { user = "u-lena", index = 2, count = 2 }, source = "automatic" })
end)

t.case("badge event: first snapshot is baseline, a new badge posts one event", function()
  local e = boot()
  e.set_badges(3) -- tracking began with 0 badges; the core now reports 3
  local evs = badge_events(e.m)
  t.eq(#evs, 3)
  t.eq(evs[1].payload.index, 1); t.eq(evs[3].payload.index, 3)
  t.eq(evs[3].source, "automatic")
  t.eq(evs[3].text, "Lena earned badge 3.")
  e.set_badges(3); e.poll()
  t.eq(#badge_events(e.m), 3, "no repeat while unchanged")
  e.set_badges(4)
  t.eq(#badge_events(e.m), 4)
  t.eq(badge_events(e.m)[4].payload.count, 4)
end)

t.case("badge event: badges owned at the first snapshot are baseline", function()
  local run = B.run({ "Lena", "Jonas" })
  run.settings = {}
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
  m.set_provider("pokemon.core", {
    team = function() return { B.rec({ p = 0xB1, sp = 900, hp = 30 }) } end,
    box_count = function() return 1 end,
    box = function() return {} end,
    badges = function() return { count = 5, flags = {} } end,
  })
  local app = controller.new(m.uz)
  app:start()
  m.advance(6000); m.tick(1)
  t.eq(#badge_events(m), 0)
  t.eq(m.run.states["u-lena"].badges, 5)
end)

t.case("badge event: dedupe against events already in the run (restart, lost state)", function()
  local old = { type = "soullink.badge", source = "automatic", payload = { user = "u-lena", index = 1, count = 1 },
    text = "Lena earned badge 1." }
  local e = boot({ old })
  e.set_badges(2)
  local evs = badge_events(e.m)
  t.eq(#evs, 2, "the stored badge 1 plus the new badge 2")
  t.eq(evs[2].payload.index, 2)
end)

t.case("badge event: manual badge selection posts nothing", function()
  local e = boot()
  e.m.action("badges_select", 2)
  e.poll()
  t.eq(#badge_events(e.m), 0)
end)

t.case("demo tag: shown in the panel header only when the core reports demo", function()
  local panel = require("ui.panel")
  local ui_validator = require("ui_validator")
  local function app_with(info)
    local run = B.run({ "Lena", "Jonas" })
    local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
    m.set_provider("pokemon.core", {
      info = function() return info end,
      team = function() return { B.rec({ p = 0xB1, sp = 900, hp = 30 }) } end,
      box_count = function() return 1 end, box = function() return {} end,
    })
    local app = controller.new(m.uz)
    app:start()
    m.advance(600); m.tick(1)
    return m
  end
  local on = app_with({ demo = true })
  local chip = ui_validator.find(on.ui.trees.panel, "h-demo")
  t.eq(chip.text, "Demo data")
  local off = app_with({ demo = false })
  t.eq(ui_validator.find(off.ui.trees.panel, "h-demo"), nil)
  local none = app_with(nil)
  t.eq(ui_validator.find(none.ui.trees.panel, "h-demo"), nil)
  local en = json.decode(read("plugin/i18n/en.json")); local de = json.decode(read("plugin/i18n/de.json"))
  t.ok(en.demo_chip and de.demo_chip and en.ev_badge and de.ev_badge)
end)
