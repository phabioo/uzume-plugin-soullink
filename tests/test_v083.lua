-- v0.8.3: the run's randomizer shown in header, board, panel and per player. Synthetic data only.
local t = require("t")
local B = require("build")
local V = require("model.view")
local json = require("json")
local screen = require("ui.screen")
local board = require("ui.board")
local panel = require("ui.panel")
local ui_validator = require("ui_validator")

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local EN = json.decode(read("plugin/i18n/en.json"))
local DE = json.decode(read("plugin/i18n/de.json"))
local function mk(map)
  return function(key, vars)
    local s = map[key] or key
    return (s:gsub("{(%w+)}", function(k) return vars and vars[k] ~= nil and tostring(vars[k]) or "{" .. k .. "}" end))
  end
end
local tr = mk(EN)

local function setup(rand, kinds)
  local run = B.run({ "Lena", "Jonas" })
  run.randomizer = rand
  for i, k in ipairs(kinds or {}) do run.participants[i].variant_kind = k end
  local cfg = B.cfg("soullink")
  local log = B.log()
  local st = {}
  for _, n in ipairs({ "Lena", "Jonas" }) do
    local tk = B.tracker("u-" .. n:lower(), cfg, log)
    tk:start(); tk:place("route-101")
    st[tk.uid] = tk.st
  end
  local view = V.view(run, st, log.events, cfg)
  return { view = view, run = run, me = "u-lena", ui = {}, tr = tr, readonly = false, events = log.events, can_open = true }
end

local function find(tree, id) return ui_validator.find(tree, id) end

t.case("randomizer each: header, board and panel show it", function()
  local ctx = setup({ mode = "each", preset_id = "nuzlocke", preset_label = "Nuzlocke friendly", tool_version = "1.6.2", allow_own = true })
  local want = "Randomized · each person their own world · Nuzlocke friendly"
  t.eq(find(screen.build(ctx), "head-randomizer").text, want)
  t.eq(find(board.build(ctx), "b-randomizer").text, want)
  t.eq(find(panel.build(ctx), "h-rand").text, "Randomized")
end)

t.case("randomizer same: wording and German strings", function()
  local ctx = setup({ mode = "same", preset_label = "Chaos" })
  t.eq(find(board.build(ctx), "b-randomizer").text, "Randomized · same world for everyone · Chaos")
  ctx.tr = mk(DE)
  t.eq(find(board.build(ctx), "b-randomizer").text, "Randomisiert · dieselbe Welt für alle · Chaos")
end)

t.case("randomizer without label shows mode only; no seeds or settings leak", function()
  local ctx = setup({ mode = "same", seed = "SECRET", settings = "SECRET" })
  t.eq(find(board.build(ctx), "b-randomizer").text, "Randomized · same world for everyone")
  local r = V.randomizer(ctx.run)
  t.eq(r.seed, nil); t.eq(r.settings, nil)
end)

t.case("no randomizer: nothing is shown", function()
  for _, r in ipairs({ false, "x", {}, { mode = "bogus", preset_label = "X" }, { mode = 5 } }) do
    local ctx = setup(r ~= false and r or nil)
    t.eq(ctx.view.randomizer, nil)
    t.eq(find(screen.build(ctx), "head-randomizer"), nil)
    t.eq(find(board.build(ctx), "b-randomizer"), nil)
    t.eq(find(panel.build(ctx), "h-rand"), nil)
  end
  t.eq(V.randomizer(nil), nil)
end)

t.case("variant_kind own is shown next to the person only", function()
  local ctx = setup({ mode = "each" }, { "own", "run" })
  t.eq(ctx.view.players[1].own_variant, true)
  t.eq(ctx.view.players[2].own_variant, nil)
  local bd = board.build(ctx)
  local rows = find(bd, "b-plist").rows
  t.ok(rows[1].sub:find("own variant", 1, true), "first has the note")
  t.eq(rows[2].sub:find("own variant", 1, true), nil)
  ctx.ui.screen_tab_id = "team"
  local sc = screen.build(ctx)
  t.eq(find(sc, "pl-variant1").text, "own variant")
  t.eq(find(sc, "pl-variant2"), nil)
end)

t.case("randomizer i18n keys exist in en and de", function()
  for _, k in ipairs({ "rand_on", "rand_chip", "rand_mode_each", "rand_mode_same", "rand_own_variant" }) do
    t.ok(EN[k] and DE[k], k)
  end
end)
