-- Issue #38: the place event is not repeated on every session start. Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local controller = require("app.controller")

local function places(m)
  local out = {}
  for _, ev in ipairs(m.run.events) do if ev.type == "soullink.place" then out[#out + 1] = ev end end
  return out
end

local function session(m)
  local app = controller.new(m.uz)
  app:start()
  m.advance(6000); m.tick(1)
  return app
end

local function boot()
  local run = B.run({ "Lena", "Jonas" })
  run.settings = {}
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
  local core = fake_core.new()
  m.set_provider("pokemon.core", core.provider)
  return m, core
end

t.case("place event: unchanged location is not logged again when the state is lost", function()
  local m = boot()
  for _ = 1, 4 do
    m.run.states["u-lena"] = nil -- fresh state at every session start
    session(m)
  end
  t.eq(#places(m), 1)
end)

t.case("place event: unchanged location is not logged again with persisted state", function()
  local m = boot()
  for _ = 1, 3 do session(m) end
  t.eq(#places(m), 1)
end)

t.case("place event: a real change is logged, also back to the earlier place", function()
  local m, core = boot()
  session(m)
  m.run.states["u-lena"] = nil
  core:go(302, "Synthetic Area Two", 11)
  session(m)
  t.eq(#places(m), 2)
  m.run.states["u-lena"] = nil
  core:go(301, "Synthetic Area One", 10)
  session(m)
  t.eq(#places(m), 3)
  t.eq(places(m)[3].payload.route, "loc:301")
end)

t.case("place event: same name but different location ids are both logged, same id is deduped", function()
  local m, core = boot()
  for _, l in ipairs(core.world.locations) do
    if l.id == 400 or l.id == 401 then l.name = "Synthetic Twin" end
  end
  core:go(400, "Synthetic Twin", 13)
  session(m)
  m.run.states["u-lena"] = nil
  core:go(401, "Synthetic Twin", 14)
  session(m)
  t.eq(#places(m), 2)
  t.eq(places(m)[1].payload.loc, 400)
  t.eq(places(m)[2].payload.loc, 401)
  m.run.states["u-lena"] = nil
  session(m)
  t.eq(#places(m), 2)
end)
