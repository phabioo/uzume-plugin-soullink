-- End-to-end of the model through the fake uz (what the package 2 wiring will do).
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local snapshot = require("model.snapshot")
local detect = require("model.detect")
local rules = require("model.rules")
local events = require("model.events")
local corrections = require("model.corrections")
local view = require("model.view")

t.case("poll core, post events and state, derive the view", function()
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run } })
  local uz = m.uz
  local team = { B.rec({ p = 0xB1, sp = 900, hp = 30 }), B.rec({ p = 0xB2, sp = 901, hp = 30 }) }
  local box = {}
  m.set_provider("pokemon.core", {
    team = function() return team end,
    box_count = function() return 1 end,
    box = function() return box end,
    location = function() return nil, "unsupported" end,
  })
  local cfg = rules.parse(uz.run.current())
  t.eq(cfg.mode, "soullink")
  local st
  local function poll()
    local snap = snapshot.from_core(uz)
    local facts
    st, facts = detect.diff(st, snap, cfg, {})
    for _, spec in ipairs(events.from_facts(facts, run.me)) do uz.run.event(spec) end
    uz.run.setState(st)
    return facts
  end
  poll()
  local st0
  st0, _ = detect.set_place(st, "route-101")
  st = st0
  box[1] = B.rec({ p = 0x77, sp = 12, nick = "Z", hp = 30 })
  local facts = poll()
  t.eq(facts[1].kind, "catch")
  t.eq(uz.run.events(0, 10)[1].type, "soullink.catch")
  -- Jonas' state arrives through the run
  local jonas = detect.diff(nil, { team = { B.rec({ p = 1, sp = 9 }), B.rec({ p = 2, sp = 9 }) }, boxes = {} }, cfg, {})
  jonas = detect.set_place(jonas, "route-101")
  jonas = detect.diff(jonas, { team = { B.rec({ p = 1, sp = 9 }), B.rec({ p = 2, sp = 9 }) },
    boxes = { { B.rec({ p = 3, sp = 15, nick = "J", hp = 30 }) } } }, cfg, {})
  m.run.set_state_for("u-jonas", jonas)
  local v = view.view(uz.run.current(), uz.run.states(), uz.run.events(0, 500), cfg)
  t.eq(v.groups[1].state, "linked")
  -- a correction goes through the event API as manual
  local spec = corrections.mark_dead({ user = "u-jonas", mon = "00000003" })
  t.ok(uz.run.event(spec))
  v = view.view(uz.run.current(), uz.run.states(), uz.run.events(0, 500), cfg)
  t.eq(v.groups[1].state, "dead")
  t.eq(uz.run.events(0, 500)[2].source, "manual")
end)
