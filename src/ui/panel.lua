-- In-game panel (design 5b), built for about 300 px: run header, location card, encounter hint,
-- own team with link partners, graveyard (collapsed), footer. No tabs, no map, no stats, no filters:
-- everything else lives on the run screen (ui.screen, opened with uz.ui.open("screen")).
-- Pure builder: panel.build(ctx) -> block. ctx.can_open is false when the platform has no
-- uz.ui.open; the panel then says so instead of showing the buttons that open the screen.
local common = require("ui.common")
local corr_ui = require("ui.corrections")
local oras = require("data.oras")

local M = {}

M.MAX_PARTNERS = 2   -- partner icons per team row
M.MAX_GRAVE_ROWS = 10

function M.empty(tr)
  return { type = "column", gap = 12, children = {
    common.empty(tr, "empty_title", "empty_panel"),
  } }
end

local function header(ctx)
  local tr, run = ctx.tr, ctx.run
  local row = { { type = "text", id = "h-name", text = run.name or "", style = "heading" } }
  if ctx.can_open then
    row[#row + 1] = { type = "button", id = "h-open", label = tr("open_run_link"), action = "open_run", variant = "quiet" }
  end
  -- the host draws the "DRAWN BY SOULLINK" marker, so there is no eyebrow of our own
  local kids = {}
  if not common.writable(run) then
    kids[#kids + 1] = { type = "badge", id = "h-ro", text = tr("run_readonly_" .. tostring(run.status)), tone = "warning" }
  end
  if ctx.view and ctx.view.randomizer then
    row[#row + 1] = { type = "badge", id = "h-rand", text = ctx.tr("rand_chip"), tone = "info" }
  end
  if ctx.demo then
    row[#row + 1] = { type = "badge", id = "h-demo", text = ctx.tr("demo_chip"), tone = "warning" }
  end
  kids[#kids + 1] = { type = "row", id = "h-row", gap = 8, align = "center", children = row }
  return { type = "column", id = "header", gap = 4, children = kids }
end

local function others_on_place(ctx, me)
  local tr, view = ctx.tr, ctx.view
  local rows = {}
  local key = me.place.key
  if not key then return rows end
  local row = common.row_of(view, key)
  for i, p in ipairs(view.players) do
    if p.id ~= me.id and p.place.key == key then
      local cell = row and row.cells[p.id] or { state = "open" }
      rows[#rows + 1] = { type = "row", id = "o-" .. i, gap = 8, align = "center", children = {
        { type = "avatar", id = "o-av" .. i, initial = common.initial(p.name), color = common.color(p, i), size = "s" },
        { type = "text", id = "o-t" .. i, text = tr("other_on_place", { player = p.name, state = common.cell_text(cell, tr) }),
          style = "meta" },
      } }
    end
  end
  return rows
end

local function location(ctx, me)
  local tr = ctx.tr
  local status = me.place.status
  local sub_key = ({ open = "loc_open", encounter = "loc_encounter", caught = "loc_caught", missed = "loc_missed",
    no_route = "loc_no_route", unknown = "loc_unknown" })[status] or "loc_unknown"
  local row = me.place.key and common.row_of(ctx.view, me.place.key)
  local cell = row and row.cells[me.id]
  local sub
  if status == "caught" and cell then
    sub = common.cell_text(cell, tr)
  elseif status == "open" and ctx.view.rules.balls_required and not me.balls then
    sub = tr("loc_no_balls")
  else
    sub = tr(sub_key)
  end
  local kids = others_on_place(ctx, me)
  return { type = "location", id = "loc", title = common.place_label(me.place, tr, ctx.view), sub = sub,
    status = common.loc_status(status), status_label = tr("loc_tag_" .. common.loc_status(status)), children = kids }
end

--- The core reports a zone (but no location) that no player has mapped to a place yet.
local function needs_zone(ctx, me)
  local z = me.place.zone
  return z ~= nil and me.place.loc == nil and me.place.key == nil and not me.place.manual and ctx.view.zones[z] == nil
end

local function picker_blocks(ctx, me)
  local tr = ctx.tr
  local selected = common.place_value(me.place)
  return {
    { type = "select", id = "place-select", options = common.route_options(ctx, nil, selected), selected = selected,
      action = "place_select" },
    { type = "textfield", id = "place-text", action = "place_text", placeholder = tr("place_other"), text = "" },
  }
end

--- Manual place: only when the core cannot report the location, collapsed behind "Set place".
--- Unmapped zone without a location id: the card that asks which place this is (fallback).
local function place_picker(ctx, me)
  local tr = ctx.tr
  if ctx.readonly then return nil end
  if needs_zone(ctx, me) then
    local kids = picker_blocks(ctx, me)
    kids[#kids + 1] = { type = "button", id = "zone-none", label = tr("zone_not_route"), action = "zone_none", variant = "quiet" }
    return { type = "card", id = "zone-new", title = tr("zone_new_title"), children = {
      { type = "text", id = "zone-new-text", text = tr("zone_new_text"), style = "meta" },
      { type = "column", id = "place-picker", gap = 4, children = kids } } }
  end
  if ctx.location_ok then return nil end
  local open = ctx.ui.place_open == true
  local kids = { { type = "button", id = "place-toggle", label = tr(open and "place_hide" or "place_set"),
    action = "place_toggle", variant = "quiet" } }
  if open then
    kids[#kids + 1] = { type = "column", id = "place-picker", gap = 4, children = picker_blocks(ctx, me) }
  end
  return { type = "column", id = "place-set", gap = 4, children = kids }
end

local function encounter_hint(ctx, me)
  local tr = ctx.tr
  if me.place.status ~= "encounter" or ctx.readonly then return nil end
  local row = common.row_of(ctx.view, me.place.key)
  local cell = row and row.cells[me.id] or {}
  local text = { type = "column", id = "enc-col", gap = 0, children = {
    { type = "text", id = "enc-text", text = tr("enc_text", { mon = common.species_label(cell) }), style = "body" },
    { type = "text", id = "enc-meta", text = tr("enc_meta"), style = "meta" },
  } }
  local icon = cell.species and common.icon_block(ctx, "enc-i", { species = cell.species, species_name = cell.species_name }, nil, "s")
  local head = text
  if icon then head = { type = "row", id = "enc-row", gap = 8, align = "center", children = { icon, text } } end
  local act = { { type = "button", id = "enc-no", label = tr("doesnt_count"), action = "dc_open", variant = "quiet" } }
  local key = common.HOTKEYS["doesnt-count"]
  if key then act[#act + 1] = { type = "text", id = "enc-key", text = key, style = "meta" } end
  return { type = "card", id = "enc", eyebrow = tr("enc_eyebrow"), children = {
    head,
    { type = "row", id = "enc-acts", gap = 8, align = "center", children = act },
  } }
end

--- Rule balls_required while the person has no Poke Balls: hint and the manual "I have Poke Balls" action.
local function balls_hint(ctx, me)
  local tr = ctx.tr
  if ctx.readonly or not ctx.view.rules.balls_required or me.balls then return nil end
  return { type = "card", id = "balls", children = {
    { type = "text", id = "balls-text", text = tr("balls_hint"), style = "meta" },
    { type = "button", id = "balls-have", label = tr("balls_have"), action = "have_balls", variant = "quiet" },
  } }
end

--- A route that detection closed as missed: offer to reopen it.
local function reopen_hint(ctx, me)
  local tr = ctx.tr
  if ctx.readonly or me.place.status ~= "missed" or not me.place.key then return nil end
  local row = common.row_of(ctx.view, me.place.key)
  local cell = row and row.cells[me.id]
  if not (cell and cell.auto) then return nil end
  return { type = "button", id = "reopen", label = tr("reopen_route"), action = "reopen_open", value = me.place.key, variant = "quiet" }
end

local function partners(ctx, me, i, m, groups)
  local g = m.group and groups[m.group]
  if not g or g.count <= 1 then return nil end
  local kids, shown, more = {}, 0, 0
  for j, pm in ipairs(g.members) do
    if pm.owner ~= me.id then
      if shown < M.MAX_PARTNERS then
        shown = shown + 1
        local idx, pl = common.index_of(ctx.view, pm.owner)
        local color = common.color(pl or {}, idx)
        local icon = common.icon_block(ctx, "m-p" .. i .. "-" .. j, pm, color, "s")
        kids[#kids + 1] = icon or { type = "avatar", id = "m-p" .. i .. "-" .. j,
          initial = common.initial(pl and pl.name), color = color, size = "s" }
      else
        more = more + 1
      end
    end
  end
  if more > 0 then
    kids[#kids + 1] = { type = "text", id = "m-pm" .. i, text = "+" .. more, style = "meta" }
  end
  local row = { type = "row", id = "m-pr" .. i, gap = 4, align = "center", children = kids }
  return { type = "column", id = "m-pc" .. i, gap = 2, children = {
    { type = "text", id = "m-pl" .. i, text = ctx.tr("linked_with"), style = "eyebrow" }, row } }
end

local function team(ctx, me)
  local tr = ctx.tr
  local groups = common.groups(ctx.view)
  local owner = common.color(me, common.index_of(ctx.view, me.id))
  local kids = {}
  for i, m in ipairs(me.team) do
    local title = (m.dead and "✕ " or "") .. common.mon_name(m) .. (m.level and (" · " .. tr("level_short", { n = m.level })) or "")
    local texts = { { type = "text", id = "m-t" .. i, text = title, style = "body", tone = m.dead and "neutral" or nil } }
    local has_nick = type(m.nickname) == "string" and m.nickname ~= ""
    if has_nick then
      texts[#texts + 1] = { type = "text", id = "m-s" .. i, text = common.species_label(m), style = "meta" }
    end
    local head = { type = "column", id = "m-c" .. i, gap = 0, children = texts }
    local icon = common.icon_block(ctx, "m-i" .. i, m, owner, "s")
    if icon then head = { type = "row", id = "m-h" .. i, gap = 8, align = "center", children = { icon, head } } end
    local c = { head }
    local ratio = (not m.dead) and common.hp_ratio(m)
    if ratio then
      c[#c + 1] = { type = "bar", id = "m-hp" .. i, value = ratio, label = tr("hp_label", { hp = m.hp, max = m.mhp }) }
    end
    local pr = partners(ctx, me, i, m, groups)
    if pr then c[#c + 1] = pr end
    kids[#kids + 1] = { type = "column", id = "mon" .. i, gap = 4, children = c }
  end
  if #kids == 0 then kids[1] = { type = "text", id = "team-empty", text = tr("team_empty"), style = "meta" } end
  return { type = "section", id = "team", title = tr("team_title", { n = #me.team }), children = kids }
end

local function graveyard(ctx)
  local tr, view = ctx.tr, ctx.view
  local open = ctx.ui.grave_open
  local kids = { { type = "chip", id = "grave-chip", text = tr(open and "grave_hide" or "grave_show"),
    action = "grave_toggle", selected = open and true or false } }
  if open then
    local rows = {}
    for i, g in ipairs(view.graveyard) do
      if i > M.MAX_GRAVE_ROWS then break end
      rows[i] = { id = "g" .. i, title = "✕ " .. common.mon_name(g), image = common.icon(ctx, g.species, g.form),
        sub = tr("grave_sub", { route = g.route and common.route_label(ctx, g.route) or "?", player = common.name_of(view, g.owner) }),
        tone = "neutral" }
    end
    if #rows > 0 then kids[#kids + 1] = { type = "list", id = "grave-list", rows = rows } end
  end
  return { type = "column", id = "grave", gap = 4, children = kids }
end

local function footer(ctx, me)
  local tr = ctx.tr
  -- "Graveyard 3 · Badges 4 / 8 · next cap Lv 24": the badge total is the game's (8 for the supported games)
  local text = tr("panel_footer", { grave = #ctx.view.graveyard, n = me.badges, total = oras.BADGES })
  if me.level_cap then text = text .. " · " .. tr("next_cap_short", { n = me.level_cap }) end
  local kids = { { type = "text", id = "badges", text = text, style = "meta" } }
  if ctx.badges_manual and not ctx.readonly then
    local opts = {}
    for n = 0, 8 do opts[#opts + 1] = { value = n, label = tostring(n) } end
    kids[#kids + 1] = { type = "select", id = "badges-select", options = opts, selected = me.badges, action = "badges_select" }
  end
  if not ctx.can_open then
    kids[#kids + 1] = { type = "text", id = "f-update", text = tr("update_to_open"), style = "meta" }
  end
  return { type = "column", id = "footer", gap = 8, children = kids }
end

--- ctx.view / ctx.run required.
function M.build(ctx)
  local me = common.me(ctx)
  if not me then
    return { type = "column", gap = 12, children = { header(ctx), common.empty(ctx.tr, "no_player_title", "no_player_text") } }
  end
  local kids = { header(ctx), location(ctx, me) }
  local picker = place_picker(ctx, me)
  if picker then kids[#kids + 1] = picker end
  local hint = encounter_hint(ctx, me)
  if hint then kids[#kids + 1] = hint end
  local balls = balls_hint(ctx, me)
  if balls then kids[#kids + 1] = balls end
  local reopen = reopen_hint(ctx, me)
  if reopen then kids[#kids + 1] = reopen end
  -- the "Doesn't count" form (5f-1) is opened from here; every other correction lives on the run screen
  if ctx.ui.corr and (ctx.ui.corr.kind == "doesnt_count" or ctx.ui.corr.kind == "reopen") then
    local corr = corr_ui.section(ctx)
    if corr then kids[#kids + 1] = corr end
  end
  kids[#kids + 1] = team(ctx, me)
  kids[#kids + 1] = graveyard(ctx)
  kids[#kids + 1] = footer(ctx, me)
  return { type = "column", id = "panel", gap = 12, children = kids }
end

return M
