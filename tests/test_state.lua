local t = require("t")
local B = require("build")
local state = require("model.state")
local util = require("model.util")
local mock = require("uz_mock")

t.case("fresh state is small and versioned", function()
  local st = state.new({ id = "g", language = "de" })
  t.eq(st.v, 1)
  t.eq(st.game, { id = "g", language = "de" })
  t.ok(state.size(st) < 400)
  t.eq(state.deaths({ deaths = 3 }), 3)
  t.eq(state.deaths({}), 0)
end)

t.case("ensure completes foreign states", function()
  local st = state.ensure({ v = 1 })
  t.eq(st.mons, {}); t.eq(st.routes, {}); t.eq(st.baseline, {})
  t.ok(state.ensure(nil).place)
end)

local function big_state()
  -- display names are stored too (one per species id): the worst realistic size
  local tr = B.tracker("u-a", B.cfg("soullink"), nil, { names = { species = function(id) return "Synthetic Species " .. id end } })
  tr:start()
  local routes = {}
  for n = 1, 40 do routes[#routes + 1] = "loc:" .. (200 + n) end
  for i = 1, 126 do
    tr:place(routes[(i - 1) % #routes + 1])
    local team = i <= 6
    tr.recs[0x1000 + i * 7919] = B.rec({ p = 0x1000 + i * 7919, sp = 300 + i, nick = "NickName" .. i, lv = 50,
      hp = 30, form = i % 3 })
    local list = team and tr.team or tr.box
    list[#list + 1] = 0x1000 + i * 7919
    tr:step()
  end
  -- many baseline mons as well
  return tr.st
end

t.case("size guard: 6 team + 120 box mons stay well below 64 KiB", function()
  local st = big_state()
  local n = 0
  for _ in pairs(st.mons) do n = n + 1 end
  t.eq(n, 126)
  local size = state.size(st)
  t.ok(size < 32 * 1024, "size " .. size)
  local ok, bytes = state.guard(st)
  t.ok(ok); t.eq(bytes, size)
  -- the fake setState enforces the platform limit
  local m = mock.new({ run = { current = { status = "active", me = "u-a", participants = {} } } })
  t.ok(m.uz.run.setState(st))
  t.eq(m.run.states["u-a"].v, 1)
end)

t.case("baseline of a full save fits too", function()
  local tr = B.tracker("u-a", B.cfg())
  local base = {}
  for i = 1, 126 do base[i] = 0x2000 + i * 104729 end
  tr:start(base)
  t.ok(state.size(tr.st) < 8 * 1024)
end)

t.case("guard compacts gone mons and reports when still too large", function()
  local st = state.new()
  for i = 1, 2000 do
    st.mons[string.format("%08x", i)] = { species = i, where = "gone", nickname = "abcdefghijklmnopqrstuvwx", level = 5 }
  end
  t.ok(state.size(st) > state.MAX_BYTES)
  local ok = state.guard(st)
  t.ok(ok)
  t.eq(next(st.mons), nil)
  local huge = state.new()
  for i = 1, 6000 do huge.baseline[string.format("%08x", i)] = true end
  local ok2, bytes = state.guard(huge)
  t.ok(not ok2); t.ok(bytes > state.MAX_BYTES)
end)

t.case("util.encode is deterministic JSON", function()
  t.eq(util.encode({ b = 1, a = { 1, 2 }, c = "x\"y\n", d = true }), '{"a":[1,2],"b":1,"c":"x\\"y\\n","d":true}')
  t.eq(util.hex8(0xABCDEF), "00abcdef")
  t.eq(util.hex8(-1), "ffffffff")
  t.eq(util.hex8("x"), nil)
  t.eq(util.clean_text("  a   b ", 10), "a b")
  t.eq(util.clean_text("äöüäöü", 3), "äöü")
end)
