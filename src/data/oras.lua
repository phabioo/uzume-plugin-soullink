-- Route keys and small data tables for Omega Ruby / Alpha Sapphire.
-- Keyed by internal route keys only; names (routes, species, places) are never shipped here.
local util = require("model.util")

local M = {}

M.STARTER = "starter"
-- Legacy keys "route-101" .. "route-134" of runs started before 0.4.0: still read (label "Route N"),
-- never offered again. Places come from the game now: "loc:<location name id>" (see areas()).
M.FIRST_ROUTE = 101
M.LAST_ROUTE = 134

--- zone id (pokemon-core `location().zone`) -> route key (string) or false (known zone that is not a
--- route, e.g. a town). EMPTY on purpose: the table is unknown until recorded with the real game.
--- Meanwhile zones are learned at runtime: the answer of a player is kept in the own run state
--- (`zones`) and merged across all players (model.view.merge_zones).
M.ZONES = {}
M.ZONE_TO_ROUTE = M.ZONES -- old name
--- Route positions on the region map image, keyed by the game id (`uz.game.code`):
--- COORDS[game id][route key] = { x, y, area? } in image
--- pixels. Our own recorded facts, EMPTY for now: positions are recorded in the Map tab
--- ("Place routes") and exported with "Export positions".
M.COORDS = {}

--- Level cap hint by number of badges owned: LEVEL_CAPS[badges] = cap of the next gym.
--- VERIFY LOCALLY against the real game before relying on it; hints only, never blocking.
M.LEVEL_CAPS = { [0] = 15, 19, 24, 29, 31, 33, 42, 43 }

--- Number of gym badges of the game (the level cap table has one entry per badge).
M.BADGES = 8

--- Level cap hint for `badges` badges, or nil when unknown (for example all eight badges).
function M.level_cap(badges)
  if math.type(badges) ~= "integer" then return nil end
  return M.LEVEL_CAPS[badges]
end

--- Legacy route number of a key "route-NNN", or nil.
function M.route_number(key)
  local n = type(key) == "string" and key:match("^route%-(%d+)$")
  n = n and tonumber(n)
  if n and n >= M.FIRST_ROUTE and n <= M.LAST_ROUTE then return n end
  return nil
end

--- Key of an encounter area ("loc:<location name id>"), or nil for a non-integer id.
function M.area_key(id)
  if math.type(id) == "float" then id = math.tointeger(id) end
  if math.type(id) ~= "integer" or id < 0 or id > 999999 then return nil end
  return "loc:" .. id
end

--- Location name id of an area key, or nil.
function M.area_id(key)
  local n = type(key) == "string" and key:match("^loc:(%d+)$")
  n = n and #n <= 6 and tonumber(n)
  return n and math.tointeger(n) or nil
end

--- Area key or legacy route key (a place that can carry a map position).
function M.is_route(key) return M.area_id(key) ~= nil or M.route_number(key) ~= nil end

--- True for "starter", an area key, a legacy route key or a free "place:<text>" key.
function M.is_key(key)
  if type(key) ~= "string" then return false end
  if key == M.STARTER or M.is_route(key) then return true end
  local text = key:match("^place:(.+)$")
  return text ~= nil and util.clean_text(text, 48) == text
end

--- Free place key for text typed by the user ("place:<text>", text kept as typed apart from
--- whitespace cleanup, at most 48 characters). nil for empty text.
function M.custom_key(text)
  local t = util.clean_text(text, 48)
  return t and ("place:" .. t) or nil
end

--- Sort index. `order` (optional) maps an area key to its position in the game's order
--- (view.order). Starter first, legacy routes in numeric order, areas in game order (unknown
--- areas by id after the known ones), free places last.
function M.order_index(key, order)
  if key == M.STARTER then return 0 end
  local n = M.route_number(key)
  if n then return n - M.FIRST_ROUTE + 1 end
  local id = M.area_id(key)
  if id then return 100 + ((order and order[key]) or (50000 + id)) end
  return 1000000
end

--- Comparison function for route keys (optional game order map, see order_index).
function M.compare(a, b, order)
  local ia, ib = M.order_index(a, order), M.order_index(b, order)
  if ia ~= ib then return ia < ib end
  return tostring(a) < tostring(b)
end

--- Display text. `tr` is uz.i18n.t (key, vars); `names` (optional) is { loc = { ["<id>"] = name } }
--- from the game (view.names). Free places keep the text as typed; an area without a known
--- name shows "Area <id>".
function M.label(key, tr, names)
  if key == M.STARTER then return tr("route_starter") end
  local n = M.route_number(key)
  if n then return tr("route", { n = n }) end
  local id = M.area_id(key)
  if id then
    local nm = names and names.loc and names.loc[tostring(id)]
    if type(nm) == "string" and nm ~= "" then return nm end
    return tr("area", { n = id })
  end
  local text = type(key) == "string" and key:match("^place:(.+)$")
  return text or tostring(key)
end

return M
