-- Issue #39: the HUD status badge must not share a row with the place text (it was clipped to "GEFANGE...")
-- and every status label exists in both languages. Synthetic data only.
local t = require("t")
local B = require("build")
local V = require("model.view")
local json = require("json")
local hud = require("ui.hud")
local ui_validator = require("ui_validator")

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local EN = json.decode(read("plugin/i18n/en.json"))
local DE = json.decode(read("plugin/i18n/de.json"))

local function ctx_for(dict)
  local function tr(key, vars)
    local s = dict[key] or key
    return (s:gsub("{(%w+)}", function(k) return vars and vars[k] ~= nil and tostring(vars[k]) or "{" .. k .. "}" end))
  end
  local run = B.run({ "Lena", "Jonas" })
  local cfg = B.cfg("soullink")
  local log = B.log()
  local tk = B.tracker("u-lena", cfg, log)
  tk:start(); tk:place("route-101"); tk:catch(0x101, 11)
  local view = V.view(run, { ["u-lena"] = tk.st }, log.events, cfg)
  return { view = view, run = run, me = "u-lena", ui = {}, tr = tr, readonly = false, events = log.events }
end

t.case("HUD: status badge stands on its own line below the place, in both languages", function()
  for _, dict in ipairs({ EN, DE }) do
    local tree = hud.build(ctx_for(dict))
    t.ok(ui_validator.validate(tree))
    local compact = ui_validator.find(tree, "hud-row")
    t.eq(compact.type, "column")
    t.eq(compact.children[1].id, "hud-place")
    t.eq(compact.children[2].id, "hud-status")
    t.eq(ui_validator.find(tree, "hud-status").text, dict.hud_status_caught)
  end
end)

t.case("HUD and panel status labels exist in English and German", function()
  for _, s in ipairs({ "open", "encounter", "caught", "missed", "no_route", "unknown" }) do
    t.ok(EN["hud_status_" .. s] and DE["hud_status_" .. s], "hud_status_" .. s)
    t.ok(EN["loc_" .. s] and DE["loc_" .. s], "loc_" .. s)
  end
  t.eq(DE.loc_caught, "Gefangen")
end)
