-- Run board (design 5gh): compact read-only tree for uz.run.setBoard.
local common = require("ui.common")

local M = {}

M.MAX_ROUTE_ROWS = 60
M.MAX_GRAVE_ROWS = 40

function M.build(ctx)
  local tr, view, run = ctx.tr, ctx.view, ctx.run
  local players = {}
  for i, p in ipairs(view.players) do
    players[#players + 1] = { id = "bp" .. i, title = p.name,
      sub = tr("board_player_sub", { place = common.place_label(p.place, tr, view), alive = p.alive, dead = p.dead, badges = p.badges })
        .. (p.own_variant and (" · " .. tr("rand_own_variant")) or ""),
      tone = nil }
  end
  local columns = { tr("col_route") }
  for _, p in ipairs(view.players) do columns[#columns + 1] = p.name end
  columns[#columns + 1] = tr("col_group")
  local rows = {}
  for _, r in ipairs(view.rows) do
    if #rows < M.MAX_ROUTE_ROWS then
      local cells = { common.route_label(ctx, r.route) }
      for _, p in ipairs(view.players) do cells[#cells + 1] = common.cell_text(r.cells[p.id], tr) end
      cells[#cells + 1] = (r.group and r.group.number) and tr("group_n", { n = r.group.number }) or common.group_state_text(r.group, tr)
      rows[#rows + 1] = { cells = cells }
    end
  end
  local grave = {}
  for i, g in ipairs(view.graveyard) do
    if i <= M.MAX_GRAVE_ROWS then
      grave[#grave + 1] = { id = "bg" .. i, title = "✕ " .. common.mon_name(g),
        sub = tr("grave_sub", { route = g.route and common.route_label(ctx, g.route) or "?", player = common.name_of(view, g.owner) }), tone = "neutral" }
    end
  end
  local kids = {
    { type = "row", id = "b-head", gap = 8, align = "center", children = {
      { type = "text", id = "b-name", text = run.name or "", style = "title" },
      { type = "badge", id = "b-mode", text = common.mode_text(view, tr), tone = "info" },
      { type = "stat", id = "b-deaths", label = tr("stat_deaths"), value = tostring(view.stats.deaths) },
      { type = "stat", id = "b-routes", label = tr("stat_routes"), value = view.stats.routes_done .. " / " .. view.stats.routes_total },
    } },
    { type = "section", id = "b-players", title = tr("board_players"), children = { { type = "list", id = "b-plist", rows = players } } },
  }
  local rand = common.randomizer_text(view, tr)
  if rand then table.insert(kids, 2, { type = "text", id = "b-randomizer", style = "meta", text = rand }) end
  if #rows > 0 then
    kids[#kids + 1] = { type = "section", id = "b-routes-s", title = tr("board_routes", { n = #view.rows }),
      children = { { type = "table", id = "b-routes-table", columns = columns, rows = rows } } }
  end
  if #grave > 0 then
    kids[#kids + 1] = { type = "section", id = "b-grave-s", title = tr("grave_title", { n = #view.graveyard }),
      children = { { type = "list", id = "b-grave", rows = grave } } }
  end
  return { type = "column", id = "board", gap = 12, children = kids }
end

return M
