-- v0.9.7: panel team section, one link card per own team mon (issue 51). Synthetic data only.
local t = require("t")
local B = require("build")
local V = require("model.view")
local json = require("json")
local panel = require("ui.panel")
local ui_validator = require("ui_validator")

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local EN = json.decode(read("plugin/i18n/en.json"))
local DE = json.decode(read("plugin/i18n/de.json"))
local function tr(key, vars)
  local s = EN[key] or key
  return (s:gsub("{(%w+)}", function(k) return vars and vars[k] ~= nil and tostring(vars[k]) or "{" .. k .. "}" end))
end

local NAMES = { "Lena", "Jonas", "Mia", "Tom" }
--- Everybody catches one mon on route-101 (Lena's goes to the team); `opts.skip` leaves players out,
--- `opts.die` = name whose mon dies (hp 0 after the catch).
local function setup(n, opts)
  opts = opts or {}
  local names = { table.unpack(NAMES, 1, n) }
  local run = B.run(names)
  local cfg = B.cfg("soullink")
  local log = B.log()
  local st, trs = {}, {}
  for i, name in ipairs(names) do
    local tk = B.tracker("u-" .. name:lower(), cfg, log)
    tk:start(); tk:place("route-101")
    if not (opts.skip and opts.skip[name]) then
      tk:catch(0x100 + i, 10 + i, { nick = name .. "Mon", lv = 10 + i, team = true })
    end
    if opts.die == name then tk:hp(0x100 + i, 0) end
    trs[name] = tk
    st[tk.uid] = tk.st
  end
  local view = V.view(run, st, log.events, cfg)
  return { view = view, run = run, me = "u-lena", ui = {}, tr = tr, readonly = false, events = log.events, can_open = true }
end

local function find(tree, id) return ui_validator.find(tree, id) end
local function texts(tree)
  local out = {}
  for _, b in ipairs(ui_validator.all(tree, "text")) do out[#out + 1] = b.text end
  return out
end
local function count_text(tree, needle)
  local n = 0
  for _, s in ipairs(texts(tree)) do if s == needle then n = n + 1 end end
  return n
end
local function card_for(tree, nick)
  for _, c in ipairs(ui_validator.all(tree, "card")) do
    if c.id and c.id:match("^mon%d+$") and count_text(c, nick) > 0 then return c end
  end
end

t.case("two players: one card per own mon, cells in player order, own name once, no hp bar", function()
  local ctx = setup(2)
  local tree = panel.build(ctx)
  local card = card_for(tree, "LenaMon")
  t.ok(card, "card for Lena's mon")
  local ci = card.id:match("%d+")
  t.ok(card.eyebrow and card.eyebrow ~= "", "route as eyebrow")
  t.eq(count_text(card, "LenaMon"), 1, "own name once")
  t.eq(count_text(card, "JonasMon"), 1)
  t.eq(count_text(card, "Lv 11"), 1)
  t.eq(count_text(card, "Lv 12"), 1)
  t.eq(count_text(card, "Lena"), 1)
  t.eq(count_text(card, "Jonas"), 1)
  local row = card.children[1]
  t.eq(row.type, "row")
  t.eq(#row.children, 2)
  t.eq(find(row, "mn" .. ci .. "-1").text, "LenaMon")
  t.eq(find(row, "mn" .. ci .. "-2").text, "JonasMon", "me first")
  t.eq(#ui_validator.all(tree, "bar"), 0, "no hp bar in the panel")
  t.eq(find(tree, "m-hp1"), nil)
  t.eq(find(tree, "m-pl1"), nil, "no LINKED WITH block")
end)

t.case("four players: grid of four cells in view order", function()
  local ctx = setup(4)
  local tree = panel.build(ctx)
  local card = card_for(tree, "LenaMon")
  t.ok(card)
  local ci = card.id:match("%d+")
  local grid = card.children[1]
  t.eq(grid.type, "grid"); t.eq(grid.columns, 2); t.eq(#grid.children, 4)
  for i, name in ipairs(NAMES) do
    t.eq(find(grid, "mn" .. ci .. "-" .. i).text, name .. "Mon")
    t.eq(find(grid, "mp" .. ci .. "-" .. i).text, name)
  end
end)

t.case("three players still use a row", function()
  local card = card_for(panel.build(setup(3)), "LenaMon")
  t.eq(card.children[1].type, "row")
  t.eq(#card.children[1].children, 3)
end)

t.case("dead partner: cross prefix, neutral tone", function()
  local ctx = setup(2, { die = "Jonas" })
  local card = card_for(panel.build(ctx), "✕ LenaMon")
  t.ok(card, "card")
  local ci = card.id:match("%d+")
  local name = find(card, "mn" .. ci .. "-2")
  t.eq(name.text, "✕ JonasMon")
  t.eq(name.tone, "neutral")
  t.eq(find(card, "mn" .. ci .. "-1").text, "✕ LenaMon", "linked death: own mon dead too")
  t.eq(find(card, "mn" .. ci .. "-1").tone, "neutral")
  t.eq(#ui_validator.all(card, "bar"), 0, "no hp on dead mons")
end)

t.case("mon without nickname shows its species", function()
  local run = B.run({ "Lena" })
  local cfg = B.cfg("soullink")
  local log = B.log()
  local tk = B.tracker("u-lena", cfg, log)
  tk:start(); tk:place("route-101")
  tk:catch(0x120, 20, { nick = "", team = true })
  local view = V.view(run, { [tk.uid] = tk.st }, log.events, cfg)
  local tree = panel.build({ view = view, run = run, me = "u-lena", ui = {}, tr = tr, readonly = false, events = log.events, can_open = true })
  t.eq(count_text(tree, "#20"), 1)
end)

t.case("unlinked mon: card with its own cell only", function()
  local ctx = setup(2, { skip = { Jonas = true } })
  local tree = panel.build(ctx)
  local card = card_for(tree, "LenaMon")
  t.ok(card, "card")
  t.eq(#card.children[1].children, 1)
  t.eq(count_text(card, "JonasMon"), 0)
end)

t.case("every id in the panel is unique", function()
  local tree = panel.build(setup(4))
  local seen = {}
  local function walk(b)
    if b.id then t.ok(not seen[b.id], "duplicate id " .. b.id); seen[b.id] = true end
    for _, c in ipairs(b.children or {}) do walk(c) end
  end
  walk(tree)
end)

t.case("linked_with string is gone from both languages", function()
  t.eq(EN.linked_with, nil); t.eq(DE.linked_with, nil)
end)
