-- Platform features: manifest run_settings, read-only run view (slot `run`), tiles by user_id.
local t = require("t")
local B = require("build")
local mock = require("uz_mock")
local json = require("json")
local ui_validator = require("ui_validator")
local controller = require("app.controller")
local rules = require("model.rules")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local manifest = json.decode(read("plugin/manifest.json"))
local en = mock.read_json_flat(read("plugin/i18n/en.json"))
local de = mock.read_json_flat(read("plugin/i18n/de.json"))

local function seg_ok(s) return s:match("^[a-z][a-z0-9_]?[a-z0-9_]*$") ~= nil and #s <= 32 end

--- What the Start dialog sends: entries nested by key segments, filled with the given values.
local function nest(values)
  local out = {}
  for _, e in ipairs(manifest.run_settings) do
    local v = values[e.key]
    if v == nil then v = e.default end
    local node = out
    local segs = {}
    for s in e.key:gmatch("[^.]+") do segs[#segs + 1] = s end
    for i = 1, #segs - 1 do
      node[segs[i]] = node[segs[i]] or {}
      node = node[segs[i]]
    end
    node[segs[#segs]] = v
  end
  return out
end

t.case("manifest run_settings follow the platform validator rules", function()
  local rs = manifest.run_settings
  t.ok(#rs >= 1 and #rs <= 32)
  local keys = {}
  for _, e in ipairs(rs) do
    t.ok(not keys[e.key], "duplicate key " .. e.key)
    keys[e.key] = true
    local n = 0
    for s in e.key:gmatch("[^.]+") do n = n + 1; t.ok(seg_ok(s), "segment " .. s) end
    t.ok(n >= 1 and n <= 2, "1 or 2 segments: " .. e.key)
    t.ok(e.type == "boolean" or e.type == "enum")
    t.ok(e.label:match("^[A-Za-z0-9_.-]+$") and #e.label <= 64)
    t.ok(en[e.label] and de[e.label], "i18n label " .. e.label)
    if e.hint then
      t.ok(e.hint:match("^[A-Za-z0-9_.-]+$") and #e.hint <= 64)
      t.ok(en[e.hint] and de[e.hint], "i18n hint " .. e.hint)
    end
    t.ok(e.default ~= nil, "default required")
    if e.type == "boolean" then
      t.eq(type(e.default), "boolean"); t.eq(e.options, nil)
    else
      t.ok(e.options and #e.options >= 2 and #e.options <= 8)
      local vals = {}
      for _, o in ipairs(e.options) do
        t.ok(seg_ok(o.value) and not vals[o.value]); vals[o.value] = true
        t.ok(en[o.label] and de[o.label], "i18n option " .. o.label)
      end
      t.ok(vals[e.default], "default is an option")
    end
  end
  for k in pairs(keys) do
    for other in pairs(keys) do
      t.ok(k == other or other:sub(1, #k + 1) ~= k .. ".", k .. " is a segment-prefix of " .. other)
    end
  end
end)

t.case("run_settings keys map exactly onto rules.parse input", function()
  local expect = { mode = true }
  for flag in pairs(rules.DEFAULTS) do expect["rules." .. flag] = true end
  local got = {}
  for _, e in ipairs(manifest.run_settings) do got[e.key] = e end
  for k in pairs(expect) do t.ok(got[k], "manifest lacks " .. k) end
  for k in pairs(got) do t.ok(expect[k], "manifest has unknown key " .. k) end
  -- defaults equal rules.DEFAULTS, mode default soullink
  for flag, d in pairs(rules.DEFAULTS) do t.eq(got["rules." .. flag].default, d, flag) end
  t.eq(got.mode.default, "soullink")
  -- default dialog values parse to the default cfg
  local cfg = rules.parse({ settings = { [rules.PLUGIN_ID] = nest({}) }, participants = {} })
  t.eq(cfg.mode, "soullink"); t.ok(cfg.mode_set)
  t.eq(cfg.rules, rules.defaults())
  -- every flipped value arrives
  local flipped, want = { mode = "nuzlocke" }, rules.defaults()
  for flag, d in pairs(rules.DEFAULTS) do flipped["rules." .. flag] = not d; want[flag] = not d end
  cfg = rules.parse({ settings = { [rules.PLUGIN_ID] = nest(flipped) }, participants = {} })
  t.eq(cfg.mode, "nuzlocke"); t.eq(cfg.rules, want)
  -- fallback only without settings: mode follows the number of joined players
  t.eq(rules.parse(B.run({ "A", "B" })).mode, "soullink")
  t.eq(rules.parse(B.run({ "A" })).mode, "nuzlocke")
  t.ok(not rules.parse(B.run({ "A", "B" })).mode_set)
end)

t.case("manifest declares the run slot and version 0.9.5", function()
  t.eq(manifest.version, "0.9.5")
  t.ok(manifest.ui.run and manifest.ui.run.title)
  t.ok(#manifest.ui.run.title >= 1 and #manifest.ui.run.title <= 40)
end)

--- Run view boot: shell context, no game, read-only uz.run.
local function boot_view(status)
  local run = B.run({ "Lena", "Jonas" })
  run.view = true
  run.status = status or "active"
  local m = mock.new({ run = { current = run } })
  m.set_provider("pokemon.core", {
    team = function() error("must not be called") end,
    box = function() error("must not be called") end,
    box_count = function() error("must not be called") end,
  })
  local app = controller.new(m.uz)
  app:start()
  return m, app
end

t.case("run view: run slot tree validates, screen points to Runs", function()
  local m = boot_view()
  m.advance(600); m.tick(3)
  local tree = m.ui.trees.run
  t.ok(tree, "run slot set")
  t.ok(ui_validator.find(tree, "tabs"))
  t.ok(ui_validator.find(tree, "head-summary"))
  t.ok(ui_validator.find(m.ui.trees.screen, "empty").text:find("Runs", 1, true))
  t.eq(m.ui.trees.panel, nil); t.eq(m.ui.trees.hud, nil)
  -- no action buttons that write, no correction forms
  for _, b in ipairs(ui_validator.all(tree, "button")) do
    t.ok(not b.action or b.action:match("^corr") == nil, "write button " .. tostring(b.id))
  end
  for _, id in ipairs({ "add-open", "rd-missed", "rd-dc", "rd-undo", "rd-group" }) do t.eq(ui_validator.find(tree, id), nil, id) end
end)

t.case("run view: no write attempted, actions only navigate", function()
  local m = boot_view("active")
  m.run.add_event("u-jonas", { type = "soullink.place", payload = { route = "route-101" } })
  m.advance(600); m.tick(5)
  -- every write action is ignored
  for _, a in ipairs({ "place_select", "badges_select", "mark_dead", "dc_open", "missed_open", "undo_open",
                       "group_open", "gift_open", "dead_open", "add_open", "revert_open", "corr_submit", "place_text" }) do
    m.action(a, "route-101", "run")
  end
  m.advance(600); m.tick(10)
  t.eq(m.run.attempts, 0, "write calls in view mode")
  t.eq(m.run.board, nil)
  t.eq(m.ui.trees.run and ui_validator.find(m.ui.trees.run, "corr-form"), nil)
  t.eq(#m.ui.notes, 0)
  t.eq(#m.calls, 0, "no core calls")
  -- reading and navigating work
  m.action("tab", 2, "run"); m.advance(600); m.tick(2)
  t.eq(ui_validator.find(m.ui.trees.run, "tabs").selected, 2)
end)

t.case("mock: view-mode writes return nil + read only", function()
  local m = boot_view()
  local a, why = m.uz.run.setState({ x = 1 })
  t.eq(a, nil); t.eq(why, "read only outside the game")
  a, why = m.uz.run.event({ type = "x" }); t.eq(a, nil); t.eq(why, "read only outside the game")
  a, why = m.uz.run.setBoard({ type = "text", text = "x" }); t.eq(a, nil); t.eq(why, "read only outside the game")
  t.eq(m.run.attempts, 3)
end)

t.case("tiles: user_id first, name as fallback", function()
  local run = B.run({ "Lena", "Jonas", "Mira" })
  local m = mock.new({ run = { current = run }, game = { code = "000400000011C400", language = "en" } })
  m.set_provider("pokemon.core", { team = function() return {} end, box_count = function() return 1 end, box = function() return {} end })
  local app = controller.new(m.uz)
  app:start()
  m.advance(600); m.tick(1)
  m.fire_event("uz", "tiles", {
    { id = "a", player = "SomeOtherName", user_id = "u-jonas", game = "x" },  -- id wins over a different name
    { id = "b", player = "mira", user_id = "", game = "x" },                  -- unknown id: name
    { id = "c", player = "Jonas", user_id = "u-unknown", game = "x" },        -- id without match: name fallback
    { id = "d", player = "nobody", user_id = "u-nobody", game = "x" },
    { id = "e", player = "Mira", user_id = "u-jonas", game = "x" },           -- id beats a conflicting name
  })
  m.advance(600); m.tick(1)
  local tile = require("ui.tile")
  local view = app.view
  local got = tile.match(app.tiles, view)
  t.eq(got.a.id, "u-jonas"); t.eq(got.b.id, "u-mira"); t.eq(got.c.id, "u-jonas")
  t.eq(got.d, nil); t.eq(got.e.id, "u-jonas")
  t.ok(m.ui.trees["tile:a"] and m.ui.trees["tile:b"] and m.ui.trees["tile:c"] and m.ui.trees["tile:e"])
  t.eq(m.ui.trees["tile:d"], nil)
end)

t.case("ui validator rejects duplicate block ids with the path", function()
  local ok, err = ui_validator.validate({ type = "column", id = "root", children = {
    { type = "stat", id = "dup", value = "1" },
    { type = "section", title = "s", children = { { type = "text", id = "dup", text = "x" } } },
  } })
  t.ok(not ok)
  t.ok(err:find("duplicate dup", 1, true) and err:find("children[2].children[1]", 1, true), err)
end)
