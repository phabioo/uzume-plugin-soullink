-- Inline section for the manual corrections 5f-1 .. 5f-5 (+ mark dead, gift, revert).
-- The state of the open form is ctx.ui.corr = { kind, user, route?, mon?, group?, reason?, species?,
-- nickname?, level?, state?, gift?, target?, note?, error? }; fields change through the actions
-- "cf:<field>", "corr_submit" posts the event, "corr_cancel" closes the form.
local common = require("ui.common")
local corrections = require("model.corrections")

local M = {}

--- Build the corrections payload spec from the form; returns spec or nil, error key.
function M.to_spec(corr)
  local k = corr.kind
  local spec
  if k == "doesnt_count" then
    spec = corrections.doesnt_count({ user = corr.user, route = corr.route, mon = corr.mon, reason = corr.reason or "wrong" })
  elseif k == "undo_death" then
    spec = corrections.undo_death({ group = corr.group, reason = corr.note, undone = corr.undone })
  elseif k == "set_group" then
    spec = corrections.set_group({ user = corr.user, mon = corr.mon, group = corr.group })
  elseif k == "add" then
    spec = corrections.add({ user = corr.user, route = corr.route, species = corr.species, nickname = corr.nickname,
      level = corr.level, state = corr.state or "box" })
  elseif k == "mark_missed" then
    spec = corrections.mark_missed({ user = corr.user, route = corr.route })
  elseif k == "reopen" then
    spec = corrections.reopen({ user = corr.user, route = corr.route })
  elseif k == "mark_dead" then
    spec = corrections.mark_dead({ user = corr.user, mon = corr.mon, reason = corr.note })
  elseif k == "set_gift" then
    spec = corrections.set_gift({ user = corr.user, mon = corr.mon, gift = corr.gift ~= false })
  elseif k == "revert" then
    spec = corrections.revert({ target = corr.target, reason = corr.note })
  else
    return nil, "c_err_invalid"
  end
  if not corrections.validate_spec(spec) then return nil, "c_err_invalid" end
  return spec
end

local function buttons(ctx, corr)
  local tr = ctx.tr
  local danger = corr.kind == "undo_death" or corr.kind == "mark_dead"
  local submit = {
    type = "button", id = "corr-submit", label = tr("c_submit_" .. corr.kind), action = "corr_submit",
    variant = danger and "danger" or "primary",
  }
  if danger or corr.kind == "mark_missed" or corr.kind == "revert" then
    submit.confirm = { title = tr("c_confirm_title_" .. corr.kind), text = tr("c_confirm_text_" .. corr.kind),
      confirm_label = tr("c_submit_" .. corr.kind), danger = danger }
  end
  -- board order (5f-1): the action first, then Cancel
  return { type = "row", id = "corr-buttons", gap = 8, children = {
    submit,
    { type = "button", id = "corr-cancel", label = tr("cancel"), action = "corr_cancel", variant = "secondary" },
  } }
end

--- A mon of the own player (the forms act on the own team and box), or nil.
local function own_mon(ctx, corr)
  local p = common.player(ctx.view, corr.user or ctx.me)
  return p and corr.mon and p.mons[corr.mon] or nil
end

--- "Logged as manual with your name; <others> see it and can undo it" (the rule of 5f: nobody's change is silent).
local function who_sees(ctx, others)
  local key = (others ~= "") and "c_who" or "c_who_alone"
  return { type = "text", id = "c-who", text = ctx.tr(key, { others = others }), style = "meta" }
end

--- Returns the section block, or nil when no form is open.
function M.section(ctx)
  local corr = ctx.ui.corr
  if not corr then return nil end
  local tr, view = ctx.tr, ctx.view
  local kids = {}
  local function add(b) kids[#kids + 1] = b end
  local k = corr.kind
  local route_label = corr.route and common.route_label(ctx, corr.route) or ""
  local others = common.others_names(view, ctx.me)

  local title = tr("c_title_" .. k)
  if k == "doesnt_count" then
    -- the creature line (icon, "Wild <species> · <route>") when the encounter is known
    local row = corr.route and common.row_of(view, corr.route)
    local cell = row and row.cells[corr.user or ctx.me]
    if cell and cell.species then
      local line = { type = "text", id = "c-mon", style = "meta",
        text = tr("c_dc_mon", { mon = common.species_label(cell), route = route_label }) }
      local icon = common.icon_block(ctx, "c-mon-i", { species = cell.species, species_name = cell.species_name }, nil, "s")
      add(icon and { type = "row", id = "c-mon-row", gap = 8, align = "center", children = { icon, line } } or line)
    end
    add({ type = "text", id = "c-text", text = tr("c_dc_text", { route = route_label, others = others }), style = "meta" })
    add({ type = "segmented", id = "c-reason", action = "cf:reason", selected = corr.reason or "wrong", options = {
      { value = "dupe", label = tr("reason_dupe") }, { value = "shiny", label = tr("reason_shiny") },
      { value = "wrong", label = tr("reason_wrong") } } })
  elseif k == "undo_death" then
    if corr.number then title = tr("c_title_undo_death_n", { n = corr.number }) end
    local icons = {}
    for i, m in ipairs(corr.members or {}) do
      local ic = common.icon_block(ctx, "c-mi" .. i, { species = m.species, species_name = m.species_name, form = m.form,
        nickname = m.nickname, dead = true }, nil, "s")
      if ic then icons[#icons + 1] = ic end
    end
    if #icons > 0 then add({ type = "row", id = "c-icons", gap = 4, children = icons }) end
    for i, m in ipairs(corr.members or {}) do
      add({ type = "text", id = "c-m" .. i, text = tr("c_undo_member", { player = common.name_of(view, m.owner),
        mon = common.mon_name(m) }), style = "body" })
    end
    add({ type = "text", id = "c-text", text = tr("c_undo_text", { n = corr.number or "?" }), style = "meta" })
    add({ type = "textfield", id = "c-note", action = "cf:note", text = corr.note or "", placeholder = tr("c_reason_placeholder") })
  elseif k == "set_group" then
    local m = own_mon(ctx, corr)
    local mon = m and common.mon_name(m) or "?"
    if m then
      local species = common.species_label(m)
      add({ type = "text", id = "c-mon", style = "heading",
        text = (mon ~= species) and tr("c_group_mon", { mon = mon, species = species }) or mon })
    end
    add({ type = "text", id = "c-text", text = tr("c_group_text", { mon = mon }), style = "meta" })
    local opts = common.route_options(ctx, tr("c_group_none"), corr.group)
    add({ type = "select", id = "c-group", action = "cf:group", options = opts, selected = corr.group or "none" })
    add(who_sees(ctx, others))
  elseif k == "add" then
    local row = corr.route and common.row_of(view, corr.route)
    local cell = row and row.cells[corr.user or ctx.me]
    add({ type = "text", id = "c-text", style = "meta",
      text = tr((cell and cell.state == "missed") and "c_add_text_missed" or "c_add_text", { route = route_label }) })
    local opts = common.route_options(ctx, nil, corr.route)
    add({ type = "select", id = "c-route", action = "cf:route", options = opts,
      selected = corr.route or (opts[1] and opts[1].value) })
    add({ type = "textfield", id = "c-species", action = "cf:species", text = corr.species and tostring(corr.species) or "",
      placeholder = tr("c_species_placeholder") })
    add({ type = "textfield", id = "c-nick", action = "cf:nickname", text = corr.nickname or "", placeholder = tr("c_nick_placeholder") })
    add({ type = "textfield", id = "c-level", action = "cf:level", text = corr.level and tostring(corr.level) or "",
      placeholder = tr("c_level_placeholder") })
    add({ type = "segmented", id = "c-state", action = "cf:state", selected = corr.state or "box", options = {
      { value = "box", label = tr("state_box") }, { value = "team", label = tr("state_team") },
      { value = "dead", label = tr("state_dead") } } })
    add(who_sees(ctx, others))
  elseif k == "mark_missed" then
    title = tr("c_title_mark_missed_route", { route = route_label })
    add({ type = "text", id = "c-text", text = tr("c_missed_text", { route = route_label, others = others }), style = "meta" })
    add(who_sees(ctx, others))
  elseif k == "reopen" then
    title = tr("c_title_reopen_route", { route = route_label })
    add({ type = "text", id = "c-text", text = tr("c_reopen_text", { route = route_label }), style = "meta" })
    add(who_sees(ctx, others))
  elseif k == "mark_dead" then
    add({ type = "text", id = "c-text", text = tr("c_dead_text"), style = "meta" })
    add({ type = "textfield", id = "c-note", action = "cf:note", text = corr.note or "", placeholder = tr("c_reason_placeholder") })
    add(who_sees(ctx, others))
  elseif k == "set_gift" then
    add({ type = "toggle", id = "c-gift", action = "cf:gift", label = tr("c_gift_label"), checked = corr.gift ~= false })
    add(who_sees(ctx, others))
  elseif k == "revert" then
    add({ type = "text", id = "c-text", text = tr("c_revert_text", { seq = corr.target or "?" }), style = "meta" })
    add({ type = "textfield", id = "c-note", action = "cf:note", text = corr.note or "", placeholder = tr("c_reason_placeholder") })
  end
  if corr.error then
    add({ type = "text", id = "c-error", text = tr(corr.error), tone = "warning" })
  end
  add({ type = "text", id = "c-hint", text = tr("c_enter_hint"), style = "meta" })
  add(buttons(ctx, corr))
  return { type = "section", id = "corr", title = title, children = kids }
end

return M
