-- Run screen (design 5e), shown in the `screen` slot (and, read only, in the `run` slot of the Runs page):
-- frame with tabs Map | Routes | Team & box | Graveyard | Event log. All manual corrections (5f) live here.
-- The Map tab shows the stored map (app.maps: taken from the game picture or chosen among the images of the
-- game files); until then the Routes tab comes first and the Map tab offers both sources.
local common = require("ui.common")
local corr_ui = require("ui.corrections")
local oras = require("data.oras")

local M = {}

M.LOG_LIMIT = 100

function M.empty(tr)
  return { type = "column", gap = 12, children = { common.empty(tr, "empty_title", "empty_screen") } }
end

--- The Map tab exists with an image, and in a live run (to take the map); not in the shell run view without one.
function M.has_map(ctx) return ctx ~= nil and ctx.map ~= nil and (ctx.map.state == "ready" or ctx.map.live == true) end

local RULE_ORDER = { "first_encounter_only", "dupes_clause", "shiny_clause", "hordes_count",
  "pairs_differ_primary_type", "only_linked_in_team", "nickname_required", "level_caps",
  "balls_required" }

local function rules_on(view)
  local n = 0
  for _, k in ipairs(RULE_ORDER) do if view.rules[k] then n = n + 1 end end
  return n
end

local function rules_list(ctx)
  local tr, view = ctx.tr, ctx.view
  local rows = { { id = "ru-mode", title = tr("rs_mode"), sub = common.mode_text(view, tr) } }
  for _, k in ipairs(RULE_ORDER) do
    rows[#rows + 1] = { id = "ru-" .. k, title = tr("rs_" .. k), sub = tr(view.rules[k] and "rule_on" or "rule_off") }
  end
  return { type = "list", id = "rules-list", rows = rows }
end

--- One eyebrow line "Deaths 7 · Routes 9 / 31 · Badges 4" (5e); the host run page already names the run, and
--- the host draws the "Drawn by SoulLink" marker. A read-only run says so with a badge.
local function header(ctx)
  local tr, view, run = ctx.tr, ctx.view, ctx.run
  local s = view.stats
  local kids = { { type = "text", id = "head-summary", style = "eyebrow",
    text = tr("run_summary", { deaths = s.deaths, done = s.routes_done, total = s.routes_total, badges = s.badges_max }) } }
  local rand = common.randomizer_text(view, tr)
  if rand then kids[#kids + 1] = { type = "text", id = "head-randomizer", style = "meta", text = rand } end
  if not common.writable(run) then
    kids[#kids + 1] = { type = "badge", id = "head-status", text = tr("run_status_" .. tostring(run.status)) .. " · " .. common.mode_text(view, tr),
      tone = "warning" }
  end
  return { type = "column", id = "head", gap = 8, children = kids }
end

--- Rules summary and "Game data" (diagnostics), below the tabs: out of the main flow, still one chip away.
--- Game data stays closed until the player opens it with its chip.
local function settings_foot(ctx)
  local tr, view = ctx.tr, ctx.view
  local rules_open = ctx.ui.rules_open == true
  local kids = {
    { type = "row", id = "head-rules", gap = 8, align = "center", children = {
      { type = "text", id = "rules-summary", style = "meta",
        text = tr("rules_summary", { n = rules_on(view), total = #RULE_ORDER }) },
      { type = "chip", id = "rules-chip", text = tr(rules_open and "rules_hide" or "rules_show"),
        action = "rules_toggle", selected = rules_open },
    } },
  }
  if rules_open then kids[#kids + 1] = { type = "scroll", id = "rules-scroll", max_height = "s", children = { rules_list(ctx) } } end
  if ctx.diag ~= nil then
    local open = common.diag_open(ctx.ui)
    kids[#kids + 1] = { type = "row", id = "head-diag", gap = 8, align = "center", children = {
      { type = "chip", id = "diag-chip", text = tr(open and "diag_hide" or "diag_show"), action = "diag_toggle", selected = open } } }
    local blk = open and common.diag_block(ctx, "diag")
    if blk then kids[#kids + 1] = blk end
  end
  return { type = "column", id = "foot", gap = 8, children = kids }
end

local function find_mine(ctx, route)
  local me = common.me(ctx)
  if not me then return nil end
  for _, id in ipairs(me.ids) do
    local m = me.mons[id]
    if m.route == route and m.counted then return m end
  end
  return nil
end

local function route_detail(ctx)
  local tr, view = ctx.tr, ctx.view
  local route = ctx.ui.selected_route
  local row = route and common.row_of(view, route)
  if not row then return nil end
  local g = row.group
  local kids = { { type = "text", id = "rd-status", text = common.group_state_text(g, tr) .. (g and g.number and (" · " .. tr("group_n", { n = g.number })) or ""),
    style = "meta" } }
  local icons = {}
  for i, p in ipairs(view.players) do
    local cell = row.cells[p.id]
    local ic = cell and cell.species and common.icon_block(ctx, "rd-i" .. i, { species = cell.species, nickname = cell.nickname,
      dead = cell.state == "dead" }, common.color(p, i), "m")
    if ic then icons[#icons + 1] = ic end
  end
  if #icons > 0 then kids[#kids + 1] = { type = "row", id = "rd-icons", gap = 8, children = icons } end
  if not ctx.readonly then
    local acts = {
      { type = "button", id = "rd-missed", label = tr("mark_missed"), action = "missed_open", value = route, variant = "quiet" },
      { type = "button", id = "rd-dc", label = tr("doesnt_count"), action = "dc_open", value = route, variant = "quiet" },
    }
    if g and g.state == "dead" then
      acts[#acts + 1] = { type = "button", id = "rd-undo", label = tr("undo_death"), action = "undo_open", value = route, variant = "quiet" }
    end
    local mycell = row.cells[ctx.me]
    if mycell and mycell.state == "missed" and mycell.auto then
      acts[#acts + 1] = { type = "button", id = "rd-reopen", label = tr("reopen_route"), action = "reopen_open", value = route, variant = "quiet" }
    end
    local mine = find_mine(ctx, route)
    if mine then
      acts[#acts + 1] = { type = "button", id = "rd-group", label = tr("change_group"), action = "group_open", value = mine.id, variant = "quiet" }
    end
    kids[#kids + 1] = { type = "row", id = "rd-acts", gap = 8, children = acts }
  end
  return { type = "section", id = "route-detail", title = common.route_label(ctx, route), children = kids }
end

local function routes_page(ctx)
  local tr, view = ctx.tr, ctx.view
  local filter = ctx.ui.routes_filter or "all"
  local n_open, n_done = 0, 0
  for _, r in ipairs(view.rows) do if r.done then n_done = n_done + 1 else n_open = n_open + 1 end end
  local columns = { tr("col_route") }
  for _, p in ipairs(view.players) do columns[#columns + 1] = p.name end
  columns[#columns + 1] = tr("col_group")
  columns[#columns + 1] = tr("col_status")
  local rows = {}
  for _, r in ipairs(view.rows) do
    if filter == "all" or (filter == "open" and not r.done) or (filter == "done" and r.done) then
      local cells = { common.route_label(ctx, r.route) }
      for _, p in ipairs(view.players) do cells[#cells + 1] = common.cell_text(r.cells[p.id], tr) end
      cells[#cells + 1] = (r.group and r.group.number) and tr("group_n", { n = r.group.number }) or "—"
      cells[#cells + 1] = common.group_state_text(r.group, tr)
      rows[#rows + 1] = { cells = cells, action = "route_select", value = r.route }
    end
  end
  local kids = {
    { type = "row", id = "rf", gap = 8, align = "center", children = {
      { type = "chip", id = "rf-all", text = tr("filter_all", { n = #view.rows }), action = "rf:all", selected = filter == "all" },
      { type = "chip", id = "rf-open", text = tr("filter_open", { n = n_open }), action = "rf:open", selected = filter == "open" },
      { type = "chip", id = "rf-done", text = tr("filter_done", { n = n_done }), action = "rf:done", selected = filter == "done" },
    } },
  }
  if not ctx.readonly then
    kids[#kids + 1] = { type = "button", id = "add-open", label = tr("add_by_hand"), action = "add_open", variant = "secondary" }
  end
  if #rows > 0 then
    kids[#kids + 1] = { type = "table", id = "routes-table", columns = columns, rows = rows }
  else
    kids[#kids + 1] = { type = "text", id = "routes-empty", text = tr("routes_empty"), style = "meta" }
  end
  if #(view.places or {}) == 0 and not common.diag_open(ctx.ui) then
    local blk = common.diag_block(ctx, "routes-diag")
    if blk then kids[#kids + 1] = blk end
  end
  local d = route_detail(ctx)
  if d then kids[#kids + 1] = d end
  return { type = "column", id = "page-routes", gap = 12, children = kids }
end

--- One team slot: creature image (when its icon is known), "nickname · Lv n", HP bar and, for the own team,
--- the correction buttons.
local function team_cell(ctx, p, i, j, m)
  local tr = ctx.tr
  local c = {}
  local icon = common.icon_block(ctx, "tm-i" .. i .. "-" .. j, m, common.color(p, i), "m")
  if icon then c[#c + 1] = icon end
  local title = (m.dead and "✕ " or "") .. common.mon_name(m) .. (m.level and (" · " .. tr("level_short", { n = m.level })) or "")
  c[#c + 1] = { type = "text", id = "tm" .. i .. "-" .. j, text = title, style = "body" }
  local ratio = (not m.dead) and common.hp_ratio(m)
  if ratio then c[#c + 1] = { type = "bar", id = "tm-hp" .. i .. "-" .. j, value = ratio, label = tr("hp_label", { hp = m.hp, max = m.mhp }) } end
  if p.id == ctx.me and not ctx.readonly then
    c[#c + 1] = { type = "column", id = "tm-a" .. j, gap = 4, align = "start", children = {
      { type = "button", id = "tm-g" .. j, label = tr("change_group"), action = "group_open", value = m.id, variant = "quiet" },
      { type = "button", id = "tm-gift" .. j, label = tr("mark_gift"), action = "gift_open", value = m.id, variant = "quiet" },
      (not m.dead) and { type = "button", id = "tm-d" .. j, label = tr("mark_dead"), action = "dead_open", value = m.id, variant = "quiet" } or nil,
    } }
  end
  return { type = "column", id = "tmc" .. i .. "-" .. j, gap = 4, children = c }
end

--- Box: a row of small images with the count in the eyebrow; a list with names while an icon is missing.
local function box_block(ctx, p, i)
  local tr = ctx.tr
  local mons = {}
  for _, id in ipairs(p.ids) do
    local m = p.mons[id]
    if m.where == "box" then mons[#mons + 1] = m end
  end
  local kids = { { type = "text", id = "box-count" .. i, text = tr("box_count", { n = p.box_count }), style = "eyebrow" } }
  local icons, all = {}, true
  for k, m in ipairs(mons) do
    local ic = common.icon_block(ctx, "box-i" .. i .. "-" .. k, m, common.color(p, i), "s")
    if ic then icons[#icons + 1] = ic else all = false end
  end
  if #mons > 0 and all then
    kids[#kids + 1] = { type = "grid", id = "box-grid" .. i, columns = 6, gap = 8, children = icons }
  elseif #mons > 0 then
    local rows = {}
    for _, m in ipairs(mons) do
      rows[#rows + 1] = { id = "b" .. m.id, title = (m.dead and "✕ " or "") .. common.mon_name(m), image = common.icon(ctx, m.species, m.form),
        sub = m.route and common.route_label(ctx, m.route) or nil, tone = m.dead and "neutral" or nil }
    end
    kids[#kids + 1] = { type = "list", id = "box-list" .. i, rows = rows }
  end
  return kids
end

--- Per person: avatar, name and current route, then TEAM (grid of slots) and BOX (5e-3).
local function team_page(ctx)
  local tr, view = ctx.tr, ctx.view
  local secs = {}
  for i, p in ipairs(view.players) do
    local who = {
      { type = "text", id = "pl-name" .. i, text = p.name, style = "heading" },
      { type = "text", id = "pl-place" .. i, text = common.place_label(p.place, tr, view), style = "eyebrow" } }
    if p.own_variant then who[#who + 1] = { type = "text", id = "pl-variant" .. i, text = tr("rand_own_variant"), style = "meta" } end
    local kids = {
      { type = "row", id = "pl-head" .. i, gap = 8, align = "center", children = {
        { type = "avatar", id = "pl-av" .. i, initial = common.initial(p.name), color = common.color(p, i), size = "m" },
        { type = "column", id = "pl-who" .. i, gap = 0, children = who },
      } },
      { type = "text", id = "team-label" .. i, text = tr("team_label"), style = "eyebrow" },
    }
    local cells = {}
    for j, m in ipairs(p.team) do cells[#cells + 1] = team_cell(ctx, p, i, j, m) end
    if #cells == 0 then
      kids[#kids + 1] = { type = "text", id = "tm-empty" .. i, text = tr("team_empty"), style = "meta" }
    else
      local own = p.id == ctx.me and not ctx.readonly
      kids[#kids + 1] = { type = "grid", id = "team-grid" .. i, columns = own and 3 or 6, gap = 12, children = cells }
    end
    for _, b in ipairs(box_block(ctx, p, i)) do kids[#kids + 1] = b end
    secs[#secs + 1] = { type = "column", id = "pl" .. i, gap = 8, children = kids }
  end
  return { type = "column", id = "page-team", gap = 20, children = secs }
end

--- Deaths of one link group sit together (they share the time), other deaths stand alone. Every cluster is a
--- list of rows: image, "nickname", "species · Lv · owner · route · cause", time; "Undo…" for a link group.
local function grave_clusters(view)
  local clusters, by_group = {}, {}
  for _, g in ipairs(view.graveyard) do
    local c = g.group and by_group[g.group]
    if not c then
      c = { group = g.group, number = g.group_number, items = {} }
      clusters[#clusters + 1] = c
      if g.group then by_group[g.group] = c end
    end
    c.items[#c.items + 1] = g
  end
  return clusters
end

local function graveyard_page(ctx)
  local tr, view = ctx.tr, ctx.view
  if #view.graveyard == 0 then
    return { type = "column", id = "page-grave", gap = 12, children = { { type = "text", id = "grave-empty", text = tr("grave_empty"), style = "meta" } } }
  end
  local kids = {}
  local n = 0
  for ci, c in ipairs(grave_clusters(view)) do
    local rows, when = {}, nil
    for _, g in ipairs(c.items) do
      n = n + 1
      local ev = common.event_by_seq(ctx, g.seq)
      local at = ev and common.when(tr, ev.time)
      when = when or at
      local cause = g.doa and tr("cause_doa") or tr("cause_" .. tostring(g.cause))
      local mon = { common.species_label(g) .. (g.level and (" · " .. tr("level_short", { n = g.level })) or ""),
        common.name_of(view, g.owner), g.route and common.route_label(ctx, g.route) or "—", cause }
      rows[#rows + 1] = { id = "g" .. n, title = "✕ " .. common.mon_name(g), sub = table.concat(mon, " · "), meta = at,
        image = common.icon(ctx, g.species, g.form), tone = "neutral",
        action = g.group and "undo_open" or nil, value = g.group }
    end
    local head = {}
    if c.group and (c.number or #c.items > 1) then
      head[#head + 1] = { type = "text", id = "grave-h" .. ci, style = "eyebrow",
        text = c.number and tr("grave_group", { n = c.number, count = #c.items }) or tr("grave_group_nonum", { count = #c.items }) }
    end
    if c.group and not ctx.readonly then
      head[#head + 1] = { type = "button", id = "grave-undo" .. ci, label = tr("undo_ellipsis"), action = "undo_open",
        value = c.group, variant = "quiet" }
    end
    local col = {}
    if #head > 0 then col[#col + 1] = { type = "row", id = "grave-hr" .. ci, gap = 8, align = "center", children = head } end
    col[#col + 1] = { type = "list", id = "grave-list" .. (ci == 1 and "" or ci), rows = rows }
    kids[#kids + 1] = { type = "column", id = "grave-c" .. ci, gap = 4, children = col }
  end
  kids[#kids + 1] = { type = "text", id = "grave-hint", text = tr("grave_hint"), style = "meta" }
  return { type = "column", id = "page-grave", gap = 12, children = kids }
end

local function event_text(ctx, ev)
  -- automatic events are worded again from their ids, so names that were not known when the event
  -- was posted ("#265") show once the game text is available
  local live = ctx.event_text and ctx.event_text(ev)
  if live then return live end
  if type(ev.text) == "string" and ev.text ~= "" then return ev.text end
  return ctx.tr("log_type_" .. tostring(ev.type):gsub("[^%w]", "_"))
end

local function log_page(ctx)
  local tr, view = ctx.tr, ctx.view
  local filter = ctx.ui.log_filter or "all"
  local person = ctx.ui.log_person
  if person ~= nil and not common.player(view, person) then person = nil end
  local rows, manual = {}, 0
  local evs = ctx.events or {}
  for i = #evs, 1, -1 do
    local ev = evs[i]
    if ev.source ~= "hub" then
      if ev.source == "manual" then manual = manual + 1 end
      if (filter == "all" or ev.source == filter) and (person == nil or ev.user_id == person) and #rows < M.LOG_LIMIT then
        rows[#rows + 1] = {
          id = "e" .. ev.seq, title = event_text(ctx, ev),
          sub = tr("log_sub", { player = common.name_of(view, ev.user_id), source = tr("source_" .. tostring(ev.source)) }),
          meta = common.when(tr, ev.time) or ("#" .. ev.seq), tone = ev.source == "manual" and "warning" or nil,
          action = (ev.type == "soullink.correction" and not ctx.readonly) and "revert_open" or nil,
          value = ev.seq,
        }
      end
    end
  end
  local bar = {
    { type = "chip", id = "lf-all", text = tr("log_all"), action = "lf:all", selected = filter == "all" },
    { type = "chip", id = "lf-auto", text = tr("log_automatic"), action = "lf:automatic", selected = filter == "automatic" },
    { type = "chip", id = "lf-manual", text = tr("log_manual", { n = manual }), action = "lf:manual", selected = filter == "manual" },
  }
  if #view.players > 1 then
    local opts = { { value = "all", label = tr("log_everyone") } }
    for _, p in ipairs(view.players) do opts[#opts + 1] = { value = p.id, label = p.name } end
    bar[#bar + 1] = { type = "select", id = "lf-person", options = opts, selected = person or "all", action = "log_person" }
  end
  local kids = { { type = "row", id = "lf", gap = 8, align = "center", children = bar } }
  if #rows > 0 then kids[#kids + 1] = { type = "list", id = "log-list", rows = rows }
  else kids[#kids + 1] = { type = "text", id = "log-empty", text = tr("log_empty"), style = "meta" } end
  return { type = "column", id = "page-log", gap = 12, children = kids }
end

local STEPS = { 2, 10, 40 }

local function calibration(ctx, m)
  local tr, c = ctx.tr, ctx.ui.calib
  local groups = common.place_groups(ctx, c.route)
  local gi = common.group_of(groups, c.route, c.group)
  local opts = groups[gi].opts
  local steps = {}
  for _, n in ipairs(STEPS) do steps[#steps + 1] = { value = n, label = tr("calib_px", { n = n }) } end
  local kids = {
    { type = "text", id = "calib-hint", text = tr("calib_hint"), style = "meta" },
    { type = "select", id = "calib-route", options = #opts > 0 and opts or { { value = "", label = tr("calib_no_places") } },
      selected = c.route or "", action = "calib_route" },
    { type = "segmented", id = "calib-step", options = steps, selected = c.step or 10, action = "calib_step" },
  }
  if #groups > 1 then
    local gopts = {}
    for i, g in ipairs(groups) do gopts[i] = { value = i, label = tr("calib_group", { a = g.first, b = g.last }) } end
    table.insert(kids, 2, { type = (#groups <= 3) and "segmented" or "select", id = "calib-group", options = gopts,
      selected = gi, action = "calib_group" })
  end
  if c.x then
    kids[#kids + 1] = { type = "text", id = "calib-pos", text = tr("calib_pos", { x = c.x, y = c.y }), style = "meta" }
    kids[#kids + 1] = { type = "row", id = "calib-arrows", gap = 8, children = {
      { type = "button", id = "calib-l", label = "←", action = "calib_move", value = "l", variant = "secondary" },
      { type = "button", id = "calib-u", label = "↑", action = "calib_move", value = "u", variant = "secondary" },
      { type = "button", id = "calib-r", label = "→", action = "calib_move", value = "r", variant = "secondary" },
      { type = "button", id = "calib-d", label = "↓", action = "calib_move", value = "d", variant = "secondary" },
    } }
    kids[#kids + 1] = { type = "button", id = "calib-set", label = tr("calib_set"), action = "calib_set", variant = "primary" }
  end
  if c.msg then kids[#kids + 1] = { type = "text", id = "calib-msg", text = tr("calib_msg_" .. c.msg), style = "meta" } end
  kids[#kids + 1] = { type = "row", id = "calib-acts", gap = 8, children = {
    { type = "button", id = "calib-export", label = tr("calib_export"), action = "calib_export", variant = "secondary" },
    { type = "button", id = "calib-done", label = tr("calib_done"), action = "calib_toggle", variant = "quiet" },
  } }
  return { type = "section", id = "calib", title = tr("calib_title"), children = kids }
end

local SIDE_KEYS = { t = "crop_top", b = "crop_bottom", l = "crop_left", r = "crop_right" }

--- Crop of the map: per side the percent of the captured screen that is cut off (-5 -1 +1 +5), presets, and
--- the button that takes the map again with this crop (the stored picture is cropped at the capture).
local function crop_section(ctx, m)
  local tr = ctx.tr
  local e = m.edit or { t = 0, b = 0, l = 0, r = 0 }
  local kids = { { type = "text", id = "crop-hint", text = tr("crop_hint"), style = "meta" } }
  for _, side in ipairs({ "t", "b", "l", "r" }) do
    local btns = { { type = "text", id = "crop-v" .. side, text = tr(SIDE_KEYS[side], { n = e[side] }), style = "body" } }
    for _, d in ipairs({ -5, -1, 1, 5 }) do
      btns[#btns + 1] = { type = "button", id = "crop-" .. side .. (d < 0 and "m" or "p") .. math.abs(d),
        label = (d > 0 and "+" or "−") .. math.abs(d), action = "crop_adj", value = side .. ":" .. d, variant = "secondary" }
    end
    kids[#kids + 1] = { type = "row", id = "crop-row-" .. side, gap = 6, align = "center", children = btns }
  end
  kids[#kids + 1] = { type = "row", id = "crop-presets", gap = 8, children = {
    { type = "button", id = "crop-none", label = tr("crop_none"), action = "crop_preset", value = "none", variant = "quiet" } } }
  if m.live and m.api then
    kids[#kids + 1] = { type = "button", id = "crop-apply", label = tr(m.state == "ready" and "crop_apply" or "map_take"),
      action = "map_capture", variant = "primary" }
  end
  if m.state == "ready" then kids[#kids + 1] = { type = "text", id = "crop-rescale", text = tr("crop_rescale"), style = "meta" } end
  return { type = "section", id = "crop", title = tr("crop_title"), children = kids }
end

local MAP_ERRORS = { busy = true, rate_limited = true, no_frame = true, unknown_screen = true, invalid_rect = true,
  too_large = true, unsupported = true, denied = true, failed = true }

--- Instruction, capture state and the error of the last try, then the capture button.
local function capture_block(ctx, m, retake)
  local tr = ctx.tr
  local kids = {}
  if not retake then
    kids[#kids + 1] = { type = "text", id = "map-hint", text = tr("map_hint"), style = "meta" }
  end
  if m.pending then
    kids[#kids + 1] = { type = "text", id = "map-wait", text = tr("map_waiting"), style = "meta" }
  elseif m.error then
    kids[#kids + 1] = { type = "text", id = "map-error", style = "meta",
      text = tr("map_err_" .. (MAP_ERRORS[m.error] and m.error or "failed")) }
  end
  return kids
end

--- Which source the Map tab shows: "screen" (take from the game picture) or "files" (candidates of the game
--- files). The player's choice, else the source of the stored map; only sources this app/core offers.
local function map_source(ctx, m)
  local screen_ok = m.api and m.live
  local files_ok = m.live and m.files and m.files.avail
  local want = ctx.ui.map_src or m.source
  if want == "files" and files_ok then return "files", screen_ok, files_ok end
  if screen_ok then return "screen", screen_ok, files_ok end
  return files_ok and "files" or "screen", screen_ok, files_ok
end

--- Source switch: only when both sources exist.
local function source_row(ctx, src, screen_ok, files_ok)
  if not (screen_ok and files_ok) then return nil end
  local tr = ctx.tr
  return { type = "row", id = "map-src", gap = 8, align = "center", children = {
    { type = "chip", id = "msrc-screen", text = tr("map_src_screen"), action = "map_src:screen", selected = src == "screen" },
    { type = "chip", id = "msrc-files", text = tr("map_src_files"), action = "map_src:files", selected = src == "files" } } }
end

--- Browse the images the core found in the game files: "n of N", preview, previous / next, "Use this map".
local function files_section(ctx, m)
  local tr, f = ctx.tr, m.files
  local kids = { { type = "text", id = "mf-hint", text = tr("map_files_hint"), style = "meta" } }
  if f.state ~= "done" then
    kids[#kids + 1] = { type = "text", id = "mf-wait", text = tr("map_files_searching"), style = "meta" }
  elseif f.n == 0 or not f.cand then
    kids[#kids + 1] = { type = "text", id = "mf-none", text = tr("map_files_none"), style = "meta" }
  else
    local c = f.cand
    local size = (c.w and c.h) and tr("map_files_size", { w = c.w, h = c.h }) or ""
    kids[#kids + 1] = { type = "text", id = "mf-pos", style = "body",
      text = tr("map_files_pos", { n = f.idx, total = f.n }) .. (size ~= "" and (" · " .. size) or "") }
    if c.src then
      kids[#kids + 1] = { type = "image", id = "mf-img", src = c.src, size = "l", label = tr("map_files_pos", { n = f.idx, total = f.n }) }
    else
      kids[#kids + 1] = { type = "text", id = "mf-load", style = "meta", text = tr(c.failed and "map_files_failed" or "map_files_loading") }
    end
    if c.suggested then kids[#kids + 1] = { type = "text", id = "mf-sug", text = tr("map_files_suggested"), style = "meta" } end
    if c.current then kids[#kids + 1] = { type = "text", id = "mf-cur", text = tr("map_files_current"), style = "meta" } end
    local row = {}
    if f.n > 1 then
      row[#row + 1] = { type = "button", id = "mf-prev", label = tr("map_files_prev"), action = "map_prev", variant = "secondary" }
      row[#row + 1] = { type = "button", id = "mf-next", label = tr("map_files_next"), action = "map_next", variant = "secondary" }
    end
    if c.src and not c.current then
      row[#row + 1] = { type = "button", id = "mf-use", label = tr("map_files_use"), action = "map_use", variant = "primary" }
    end
    if #row > 0 then kids[#kids + 1] = { type = "row", id = "mf-row", gap = 8, children = row } end
  end
  if f.error then
    kids[#kids + 1] = { type = "text", id = "mf-error", style = "meta",
      text = tr("map_err_" .. (MAP_ERRORS[f.error] and f.error or "failed")) }
  end
  return { type = "section", id = "mapfiles", title = tr("map_src_files"), children = kids }
end

--- Rows of the route card above the selected map point: one per person with the state on that route (5e-1).
local function route_popover(ctx, key)
  local view = ctx.view
  local row = common.row_of(view, key)
  if not row then return nil end
  local rows = {}
  for i, p in ipairs(view.players) do
    if #rows >= 16 then break end
    local cell = row.cells[p.id] or { state = "open" }
    local line = { owner = common.color(p, i), name = p.name, status = common.cell_text(cell, ctx.tr) }
    local src = cell.species and common.icon(ctx, cell.species, cell.form)
    if src then line.src = src end
    rows[#rows + 1] = line
  end
  return #rows > 0 and rows or nil
end

local function map_page(ctx)
  local view, m, tr = ctx.view, ctx.map, ctx.tr
  local src, screen_ok, files_ok = map_source(ctx, m)
  local switch = source_row(ctx, src, screen_ok, files_ok)
  if m.state ~= "ready" then
    -- no image yet: empty state (5e), then the chosen source; older app and no files: update hint
    if not screen_ok and not files_ok then
      return { type = "column", id = "page-map", gap = 12, children = {
        { type = "empty", id = "map-empty", title = tr("map_title"), text = tr(m.api and "map_empty_text" or "map_no_api") } } }
    end
    local kids = { { type = "empty", id = "map-empty", title = tr("map_title"), text = tr("map_empty_text") } }
    kids[#kids + 1] = switch
    if src == "files" then
      kids[#kids + 1] = files_section(ctx, m)
    else
      for _, b in ipairs(capture_block(ctx, m, false)) do kids[#kids + 1] = b end
      kids[#kids + 1] = { type = "row", id = "map-take-row", gap = 8, children = {
        { type = "button", id = "map-take", label = tr("map_take"), action = "map_capture", variant = "primary" },
        { type = "button", id = "map-crop", label = tr("crop_open"), action = "crop_toggle",
          variant = ctx.ui.crop_open and "primary" or "quiet" } } }
      if ctx.ui.crop_open then kids[#kids + 1] = crop_section(ctx, m) end
    end
    return { type = "column", id = "page-map", gap = 12, children = kids }
  end
  local players, routes, shown = {}, {}, {}
  for i, p in ipairs(view.players) do
    local c = p.place.key and m.coords[p.place.key]
    if c then
      players[#players + 1] = { id = p.id, initial = common.initial(p.name), color = common.color(p, i), x = c.x, y = c.y }
    end
  end
  local function route_marker(key)
    local c = m.coords[key]
    local r = common.row_of(view, key)
    local icons = {}
    if r then
      for i, p in ipairs(view.players) do
        local cell = r.cells[p.id]
        local src = cell and cell.species and common.icon(ctx, cell.species, nil)
        if src and #icons < 8 then icons[#icons + 1] = { src = src, owner = common.color(p, i) } end
      end
    end
    routes[#routes + 1] = { id = key, x = c.x, y = c.y, area = c.area, number = r and r.group and r.group.number or nil,
      done = r and r.done or false, icons = #icons > 0 and icons or nil }
  end
  for _, r in ipairs(view.rows) do
    if m.coords[r.route] then route_marker(r.route); shown[r.route] = true end
  end
  local extra = {}
  for key in pairs(m.coords) do if not shown[key] then extra[#extra + 1] = key end end
  table.sort(extra, function(a, b) return oras.compare(a, b, view.order) end)
  for _, key in ipairs(extra) do route_marker(key) end
  local calib = ctx.ui.calib
  if calib and calib.x then
    players[#players + 1] = { id = "cursor", initial = "+", color = 1, x = calib.x, y = calib.y }
  end
  local map = { type = "map", id = "map", players = players, routes = routes, filter = ctx.ui.map_filter or "all",
    me = ctx.me, legend = true, action = "map_select", image = m.src, image_w = m.w, image_h = m.h }
  if ctx.ui.selected_route then
    map.selected = ctx.ui.selected_route
    local pop = route_popover(ctx, ctx.ui.selected_route)
    if pop then map.popover = pop end
  end
  local acts = { { type = "button", id = "map-calib", label = tr("calib_open"), action = "calib_toggle",
    variant = calib and "primary" or "quiet" } }
  if screen_ok then
    acts[#acts + 1] = { type = "button", id = "map-retake", label = tr("map_retake"), action = "map_capture", variant = "quiet" }
    acts[#acts + 1] = { type = "button", id = "map-crop", label = tr("crop_open"), action = "crop_toggle",
      variant = ctx.ui.crop_open and "primary" or "quiet" }
  end
  acts[#acts + 1] = { type = "button", id = "map-remove", label = tr("map_remove"), action = "map_remove", variant = "quiet",
    confirm = { title = tr("map_remove_title"), text = tr("map_remove_text"), confirm_label = tr("map_remove") } }
  local kids = { { type = "text", id = "map-source", text = tr(src == "files" and "map_from_files" or "map_from_screen"), style = "eyebrow" },
    map, { type = "row", id = "map-acts", gap = 8, children = acts } }
  kids[#kids + 1] = switch
  if src == "files" then
    kids[#kids + 1] = files_section(ctx, m)
  else
    for _, b in ipairs(capture_block(ctx, m, true)) do kids[#kids + 1] = b end
  end
  if ctx.ui.crop_open and screen_ok then kids[#kids + 1] = crop_section(ctx, m) end
  if calib then kids[#kids + 1] = calibration(ctx, m) end
  return { type = "column", id = "page-map", gap = 12, children = kids }
end

--- Tab order for the current data: Map | Routes | Team & box | Graveyard | Event log. The Map tab
--- leads only with a confirmed image; while it is being set up it follows Routes; hidden when the
--- game has no map to offer.
function M.tab_ids(ctx)
  local ids = {}
  local ready = ctx ~= nil and ctx.map ~= nil and ctx.map.state == "ready"
  if ready then ids[#ids + 1] = "map" end
  ids[#ids + 1] = "routes"
  if M.has_map(ctx) and not ready then ids[#ids + 1] = "map" end
  for _, id in ipairs({ "team", "grave", "log" }) do ids[#ids + 1] = id end
  return ids
end

function M.build(ctx)
  local tr, view = ctx.tr, ctx.view
  local ids = M.tab_ids(ctx)
  local labels, pages = {}, {}
  for i, id in ipairs(ids) do
    labels[i] = tr("tab_" .. id)
    local builders = { map = map_page, routes = routes_page, team = team_page, grave = graveyard_page, log = log_page }
    pages[i] = builders[id](ctx)
  end
  -- the selection is kept by tab id: the list changes (the Map tab comes and goes), an index would then
  -- point at another tab; the first tab is selected until the player picks one
  local sel = 1
  for i, id in ipairs(ids) do if id == ctx.ui.screen_tab_id then sel = i end end
  local kids = {}
  kids[#kids + 1] = header(ctx)
  local corr = corr_ui.section(ctx)
  if corr then kids[#kids + 1] = corr end
  kids[#kids + 1] = { type = "tabs", id = "tabs", tabs = labels, selected = sel, action = "tab", children = pages }
  kids[#kids + 1] = settings_foot(ctx)
  return { type = "column", id = "screen", gap = 16, children = kids }
end

return M
