-- Issue #37: choosing "From game files" must keep the files source even when the scan ends without an image
-- (pokemon-core then answers `nil, "unsupported"`). Synthetic data only.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")

local function boot(maps)
  local run = B.run({ "Lena", "Jonas" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" }, video = true })
  local core = fake_core.new({ maps = maps })
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, app = app }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  function env.act(a, v) m.action(a, v, "screen"); env.step(300) end
  function env.find(id) return ui_validator.find(m.ui.trees.screen, id) end
  return env
end

t.case("map source: a scan that ends empty keeps the files source and says nothing was found", function()
  local e = boot({ scan = 1, list = {}, images = {} })
  e.step() -- first ask: not ready, the scan runs
  e.act("tab", 2)
  t.ok(e.find("msrc-files") and e.find("msrc-screen"), "both sources offered while scanning")
  e.act("map_src:files")
  t.eq(e.find("msrc-files").selected, true)
  t.ok(e.find("mf-wait"), "still searching")
  e.core:off("map_candidates", "unsupported") -- the core ended the scan without any image
  e.step(3100); e.step(3100)
  t.ok(e.find("msrc-files"), "the switch stays")
  t.eq(e.find("msrc-files").selected, true, "the choice is kept")
  t.eq(e.find("msrc-screen").selected, false)
  t.ok(e.find("mf-none"), "nothing found is shown")
  t.eq(e.find("map-take"), nil)
  e.act("map_src:screen")
  t.eq(e.find("msrc-screen").selected, true)
  t.ok(e.find("map-take"))
end)
