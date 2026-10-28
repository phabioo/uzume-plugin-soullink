-- Shared helpers for the UI builders. Builders are pure: they take a context
--   ctx = { view, run, me, ui, tr, readonly, now, events }
-- and return uz.ui block trees. Only tones, sizes and player numbers are used, never colors.
local oras = require("data.oras")
local util = require("model.util")

local C = {}

--- Species name read from the game (stored in the run state), else "#<species id>".
function C.species_label(m)
  if m and type(m.species_name) == "string" and m.species_name ~= "" then return m.species_name end
  return "#" .. tostring(m and m.species or "?")
end

--- Display name of a mon: its nickname, else the species name.
function C.mon_name(m)
  if m and type(m.nickname) == "string" and m.nickname ~= "" then return m.nickname end
  return C.species_label(m)
end

--- Label of a route / area key: live name from the game (ctx.area_name), else the stored name,
--- else "Area <id>" / "Route <n>" / the typed text.
function C.route_label(ctx, key)
  local id = oras.area_id(key)
  if id and ctx.area_name then
    local nm = ctx.area_name(id)
    if nm then return nm end
  end
  return oras.label(key, ctx.tr, ctx.view and ctx.view.names)
end

--- Text cut to `n` characters (HUD and tile strip have small size limits).
function C.short(text, n)
  return util.clean_text(text, n) or ""
end

C.MAX_OPTIONS = 100

--- Value of the place select that stands for a player's current place: the route key, else the
--- location (a town has no route key but is still an option), else nil.
function C.place_value(place)
  if type(place) ~= "table" then return nil end
  if place.key then return place.key end
  if place.loc ~= nil then return oras.area_key(place.loc) end
  return nil
end

--- The view entry of player `id`, or nil.
function C.player(view, id)
  for _, p in ipairs(view and view.players or {}) do if p.id == id then return p end end
  return nil
end

C.GROUP_SIZE = 90

--- Places a position can be set for, as groups of at most GROUP_SIZE route options (a select holds at most
--- 100): every place of the game (towns and caves too, view.places), the encounter areas, places used in the
--- run, the players' current places and `selected`; no starter. With up to 100 places there is one group.
--- Otherwise the first group holds the selected key, the places used in the run and the current places, filled
--- up in game order; the others follow in game order. Each group is sorted in game order and carries
--- `first`/`last`, the ordinals of its places in that sequence ("Places 1-90").
--- Returns { { opts = { {value, label} }, first, last }, ... } (one empty group when nothing is known).
function C.place_groups(ctx, selected)
  local view = ctx.view
  local prio, rest, seen = {}, {}, {}
  local function add(list, key)
    if key and oras.is_route(key) and not seen[key] then seen[key] = true; list[#list + 1] = key end
  end
  local known = {}
  for _, id in ipairs(view.places or {}) do known[oras.area_key(id) or false] = true end
  for _, id in ipairs(view.areas or {}) do known[oras.area_key(id) or false] = true end
  for _, r in ipairs(view.rows or {}) do add(prio, r.route) end
  for _, p in ipairs(view.players or {}) do add(prio, C.place_value(p.place)) end
  -- the selected key only joins the first group when the game does not list it (groups stay stable)
  if selected and not known[selected] then add(prio, selected) end
  for _, id in ipairs(view.places or view.areas or {}) do add(rest, oras.area_key(id)) end
  for _, id in ipairs(view.areas or {}) do add(rest, oras.area_key(id)) end
  local function cmp(x, y) return oras.compare(x, y, view.order) end
  local seq = {}
  if #prio + #rest <= C.MAX_OPTIONS then
    for _, k in ipairs(prio) do seq[#seq + 1] = k end
    for _, k in ipairs(rest) do seq[#seq + 1] = k end
    table.sort(seq, cmp)
  else
    table.sort(prio, cmp)
    for _, k in ipairs(prio) do seq[#seq + 1] = k end
    for _, k in ipairs(rest) do seq[#seq + 1] = k end
  end
  local size = #seq <= C.MAX_OPTIONS and math.max(#seq, 1) or math.max(C.GROUP_SIZE, #prio + 1)
  local groups = {}
  for i = 1, math.max(#seq, 1), size do
    local keys = {}
    for j = i, math.min(i + size - 1, #seq) do keys[#keys + 1] = seq[j] end
    table.sort(keys, cmp)
    local opts = {}
    for _, k in ipairs(keys) do opts[#opts + 1] = { value = k, label = C.route_label(ctx, k) } end
    groups[#groups + 1] = { opts = opts, first = i, last = math.min(i + size - 1, #seq) }
  end
  return groups
end

--- Index of the group that holds `key`, else `want` (when valid), else 1.
function C.group_of(groups, key, want)
  for i, g in ipairs(groups) do
    for _, o in ipairs(g.opts) do if o.value == key then return i end end
  end
  return (want and groups[want]) and want or 1
end

--- Options of the active group (see place_groups); the plain list when everything fits one select.
function C.place_options(ctx, selected, want)
  local groups = C.place_groups(ctx, selected)
  return groups[C.group_of(groups, selected, want)].opts
end

--- Lines "key=value key=value ..." of a flat diagnostics table (pokemon-core diagnostics()): every key is
--- shown, grouped by the text before the first "_" (a key without "_" is its own group), one line per
--- group, groups and keys sorted, strings cut to 40 characters. Empty list for nil or an empty table.
function C.diag_lines(d)
  if type(d) ~= "table" then return {} end
  local keys = {}
  for k in pairs(d) do if type(k) == "string" then keys[#keys + 1] = k end end
  table.sort(keys)
  local order, groups = {}, {}
  for _, k in ipairs(keys) do
    local g = k:match("^([^_]*)_") or k
    if not groups[g] then groups[g] = {}; order[#order + 1] = g end
    local v = d[k]
    if type(v) == "string" then v = util.clean_text(v, 40) or "" end
    local list = groups[g]
    list[#list + 1] = k .. "=" .. tostring(v)
  end
  table.sort(order)
  local lines = {}
  for _, g in ipairs(order) do lines[#lines + 1] = table.concat(groups[g], " ") end
  return lines
end

--- The "Game data" block is closed until the player opens it with the chip (state kept in ui.diag_open).
function C.diag_open(ui) return ui ~= nil and ui.diag_open == true end

--- "Game data" block (diagnostics of the core, one wrapped line per key group and a hint), or nil without
--- diagnostics. `id` makes the block ids unique when it appears twice.
function C.diag_block(ctx, id)
  local lines = C.diag_lines(ctx.diag)
  if #lines == 0 then return nil end
  local kids = { { type = "text", id = id .. "-title", text = ctx.tr("diag_title"), style = "eyebrow" } }
  for i, l in ipairs(lines) do kids[#kids + 1] = { type = "text", id = id .. "-" .. i, text = l, style = "meta", wrap = true } end
  local ic = ctx.icheck
  if type(ic) == "table" and type(ic.items) == "table" and #ic.items > 0 then
    kids[#kids + 1] = { type = "text", id = id .. "-ic-title", text = ctx.tr("icheck_title"), style = "eyebrow" }
    local cols = {}
    for i, it in ipairs(ic.items) do
      cols[i] = { type = "column", id = id .. "-ic-" .. it.label, gap = 2, children = {
        { type = "image", id = id .. "-ic-img-" .. it.label, src = it.src, size = "m", state = "alive", label = it.label },
        { type = "text", id = id .. "-ic-lbl-" .. it.label, text = it.label, style = "title" },
        { type = "text", id = id .. "-ic-desc-" .. it.label, text = it.desc, style = "meta", wrap = true } } }
    end
    kids[#kids + 1] = { type = "row", id = id .. "-ic-row", gap = 8, children = cols }
    kids[#kids + 1] = { type = "text", id = id .. "-ic-hint", text = ctx.tr("icheck_hint"), style = "meta" }
  end
  kids[#kids + 1] = { type = "text", id = id .. "-hint", text = ctx.tr("diag_hint"), style = "meta" }
  return { type = "column", id = id, gap = 4, children = kids }
end

--- Options for a route select (at most 100): optional "no group" entry, the starter, then the places of
--- the game (view.places: encounter areas, towns, caves ... from the game, in game order), keys with
--- activity that are not game places (free places, legacy routes) and the selected key, in game order.
--- When there are too many, the selected key and the keys with activity are kept first and the
--- rest of the game's places fill the remaining room in game order.
function C.route_options(ctx, none_label, selected)
  local view = ctx.view
  local head, seen = {}, {}
  if none_label then head[#head + 1] = { value = "none", label = none_label }; seen.none = true end
  seen[oras.STARTER] = true
  head[#head + 1] = { value = oras.STARTER, label = C.route_label(ctx, oras.STARTER) }
  local first, rest = {}, {}
  local function add(list, key)
    if key and not seen[key] then
      seen[key] = true
      list[#list + 1] = key
    end
  end
  add(first, selected)
  for _, r in ipairs(view.rows) do add(first, r.route) end
  for _, id in ipairs(view.places or view.areas or {}) do add(rest, oras.area_key(id)) end
  local room = math.max(C.MAX_OPTIONS - #head, 0)
  local keys = {}
  for i = 1, math.min(#first, room) do keys[#keys + 1] = first[i] end
  for i = 1, math.min(#rest, math.max(room - #keys, 0)) do keys[#keys + 1] = rest[i] end
  table.sort(keys, function(a, b) return oras.compare(a, b, view.order) end)
  local out = {}
  for _, o in ipairs(head) do out[#out + 1] = o end
  for _, k in ipairs(keys) do out[#out + 1] = { value = k, label = C.route_label(ctx, k) } end
  return out
end

--- `cache:` src of the creature icon (pokemon-core icon, fetched lazily by the controller), or nil.
function C.icon(ctx, species, form)
  if type(ctx.icon) ~= "function" then return nil end
  return ctx.icon(species, form)
end

--- `image` block for a mon (alive or dead state), or nil while there is no icon.
function C.icon_block(ctx, id, m, owner, size)
  local src = C.icon(ctx, m.species, m.form)
  if not src then return nil end
  return { type = "image", id = id, src = src, size = size or "s", state = m.dead and "dead" or "alive",
           owner = owner, label = C.mon_name(m) }
end

--- Player number 1..8 (identity color): participant color 0..7 + 1, else the list position.
function C.color(p, i)
  if math.type(p.color) == "integer" and p.color >= 0 and p.color <= 7 then return p.color + 1 end
  return math.min(math.max(i or 1, 1), 8)
end

function C.initial(name)
  name = tostring(name or "?")
  local n = utf8.offset(name, 2) or (#name + 1)
  local s = name:sub(1, n - 1):upper()
  return s ~= "" and s or "?"
end

function C.index_of(view, id)
  for i, p in ipairs(view.players) do if p.id == id then return i, p end end
  return nil
end

function C.player(view, id)
  local _, p = C.index_of(view, id)
  return p
end

function C.name_of(view, id)
  local p = C.player(view, id)
  return p and p.name or tostring(id)
end

function C.groups(view)
  local map = {}
  for _, g in ipairs(view.groups) do map[g.route] = g end
  return map
end

function C.row_of(view, route)
  for _, r in ipairs(view.rows) do if r.route == route then return r end end
  return nil
end

--- Place text: name read from the game if the core reported it, else the route label.
--- `view` (optional) supplies the stored area names.
function C.place_label(place, tr, view)
  if place.name and place.name ~= "" then return place.name end
  if place.key then return oras.label(place.key, tr, view and view.names) end
  return tr("place_none")
end

local LOC_STATUS = { open = "open", encounter = "encounter", caught = "caught", missed = "missed" }
--- Status for the `location` block.
function C.loc_status(status) return LOC_STATUS[status] or "none" end

local TONE = { open = "neutral", encounter = "info", caught = "ok", missed = "neutral" }
function C.status_tone(status) return TONE[status] or "neutral" end

--- Short text of a cell of the routes matrix.
function C.cell_text(cell, tr)
  if cell.state == "open" then return tr("cell_open") end
  if cell.state == "encounter" then return tr("cell_encounter", { mon = C.species_label(cell) }) end
  if cell.state == "missed" then return tr("cell_missed") end
  local name = C.mon_name(cell)
  if cell.state == "dead" then return "✕ " .. name end
  return name
end

function C.group_state_text(g, tr)
  if not g then return tr("group_none") end
  return tr("group_state_" .. g.state)
end

--- Progress of HP as 0..1, or nil when unknown.
function C.hp_ratio(m)
  if type(m.hp) ~= "number" or type(m.mhp) ~= "number" or m.mhp <= 0 then return nil end
  return math.max(0, math.min(1, m.hp / m.mhp))
end

--- The own player entry of the view (or nil).
function C.me(ctx) return C.player(ctx.view, ctx.me) end

--- Whether writes are accepted: run starting/active and not the read-only run view.
function C.writable(run)
  return run and not run.view and (run.status == "starting" or run.status == "active") or false
end

function C.empty(tr, title_key, text_key)
  return { type = "empty", id = "empty", title = tr(title_key), text = tr(text_key) }
end

--- Default keys of the hotkeys the manifest declares (ui.hotkeys); the UI shows a hint only for these ids.
--- The key is a suggestion the player can change in Controllers, so hints say "default" in the docs only.
C.HOTKEYS = { ["toggle-hud"] = "Ctrl+H", ["doesnt-count"] = "Ctrl+D", ["open-run"] = "Ctrl+R" }

--- "YYYY-MM-DDTHH:MM..." (event time, UTC) as translated "MM-DD HH:MM UTC" text, or nil when unknown.
function C.when(tr, t)
  if type(t) ~= "string" then return nil end
  local y, mo, d, h, mi = t:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d)")
  if not y then return nil end
  return tr("when_utc", { m = mo, d = d, time = h .. ":" .. mi })
end

--- Event of the context's event list by sequence number, or nil.
function C.event_by_seq(ctx, seq)
  if seq == nil then return nil end
  for _, ev in ipairs(ctx.events or {}) do if ev.seq == seq then return ev end end
  return nil
end

function C.mode_text(view, tr) return tr("mode_" .. view.mode) end

--- "Randomized · each person their own world · Nuzlocke friendly"; nil when the run has no randomizer.
function C.randomizer_text(view, tr)
  local r = view.randomizer
  if not r then return nil end
  local parts = { tr("rand_on"), tr("rand_mode_" .. r.mode) }
  if r.preset_label then parts[#parts + 1] = r.preset_label end
  return table.concat(parts, " · ")
end

--- Number of alive mons of all players that are not gone.
function C.alive_of(p) return p.alive end

--- Short list of the other players' names in the run.
function C.others_names(view, me)
  local names = {}
  for _, p in ipairs(view.players) do if p.id ~= me then names[#names + 1] = p.name end end
  return table.concat(names, ", ")
end

return C
