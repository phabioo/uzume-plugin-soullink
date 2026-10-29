-- v0.9.4: location blocks carry a status_label from i18n; older apps that reject it get the tree without it.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local fake_core = require("fake_core")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local json = require("json")

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end

local function boot(over, lang)
  local run = B.run({ "Lena" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = lang or "en" }, video = true,
    no_status_label = over and over.no_status_label, language = lang })
  local core = fake_core.new()
  m.set_provider("pokemon.core", core.provider)
  local app = controller.new(m.uz)
  app:start()
  local env = { m = m, core = core, app = app }
  function env.step(ms) m.advance(ms or 600); m.tick(1) end
  return env
end

t.case("i18n: every location status has a tag in both languages, at most 40 characters", function()
  for _, lang in ipairs({ "en", "de" }) do
    local tr = json.decode(read("plugin/i18n/" .. lang .. ".json"))
    for _, s in ipairs({ "open", "encounter", "caught", "missed", "none" }) do
      local v = tr["loc_tag_" .. s]
      t.ok(type(v) == "string" and #v > 0 and #v <= 40, lang .. " loc_tag_" .. s)
    end
  end
end)

t.case("panel: the location block carries the status_label of its status", function()
  local e = boot()
  e.step(); e.step()
  local p = e.m.ui.trees.panel
  t.ok(ui_validator.validate(p))
  local loc = ui_validator.find(p, "loc")
  t.ok(loc and loc.status_label and #loc.status_label > 0, "status_label set")
  local en = json.decode(read("plugin/i18n/en.json"))
  t.eq(loc.status_label, en["loc_tag_" .. loc.status])
end)

t.case("sync: an app that rejects status_label gets the tree without it and keeps working", function()
  local e = boot({ no_status_label = true })
  e.step(); e.step()
  local p = e.m.ui.trees.panel
  t.ok(p, "panel shown")
  t.ok(ui_validator.find(p, "loc") and ui_validator.find(p, "loc").status_label == nil)
  t.eq(e.app.sync.no_label, true, "fallback remembered")
  -- later updates (set and patch) keep working without raising
  e.core:encounter({ species = 910 })
  e.core.world.battle = { active = true, kind = "wild", wild = true, foes = {} }
  e.step(); e.step()
  t.ok(ui_validator.find(e.m.ui.trees.panel, "loc").status_label == nil)
end)
