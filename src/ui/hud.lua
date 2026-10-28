-- HUD widget (design 5b-2 / 5c): compact "SL · <place>" + status badge; expanded with the other players.
-- The host draws the plugin icon and the HUD frame, so there is no badge or frame of our own.
local common = require("ui.common")

local M = {}

function M.empty(tr)
  return { type = "text", id = "hud-empty", text = tr("hud_empty"), style = "meta" }
end

--- ctx.ui.hud_expanded / ctx.hud_death (text, set for ~3 s after a linked death).
function M.build(ctx)
  local tr, view = ctx.tr, ctx.view
  local me = common.me(ctx)
  if not me then return M.empty(tr) end
  local status = me.place.status
  -- Place and status badge are stacked: in one row the long place text squeezed the badge ("GEFANGE...").
  local compact = { type = "column", id = "hud-row", gap = 4, align = "start", children = {
    { type = "text", id = "hud-place", style = "body",
      text = tr("hud_place", { place = common.short(common.place_label(me.place, tr, view), 24) }) },
    { type = "badge", id = "hud-status", text = tr("hud_status_" .. status), tone = common.status_tone(status) },
  } }
  local kids = { compact }
  if ctx.hud_death then
    kids[#kids + 1] = { type = "text", id = "hud-death", text = ctx.hud_death, style = "meta" }
  end
  if ctx.ui.hud_expanded or ctx.hud_death then
    local key = me.place.key
    local row = key and common.row_of(view, key)
    for i, p in ipairs(view.players) do
      if p.id ~= me.id then
        local cell = row and row.cells[p.id] or { state = "open" }
        kids[#kids + 1] = { type = "row", id = "hud-p" .. i, gap = 8, align = "center", children = {
          { type = "avatar", id = "hud-av" .. i, initial = common.initial(p.name), color = common.color(p, i), size = "s" },
          { type = "text", id = "hud-pt" .. i, text = tr("hud_other", { player = p.name, state = common.cell_text(cell, tr) }),
            style = "meta" },
        } }
      end
    end
  end
  return { type = "card", id = "hud", action = "hud_toggle", children = kids }
end

return M
