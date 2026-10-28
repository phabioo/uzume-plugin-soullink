-- Small validator for uz.ui trees against the documented block catalog (plugin-api.md "Blocks").
-- validate(tree) -> true | nil, "path: message"
local V = {}

local function num(v) return type(v) == "number" end
local function str(max) return function(v) return type(v) == "string" and #v <= (max or 200) end end
local function bool(v) return type(v) == "boolean" end
local function enum(...)
  local set = {}
  for _, x in ipairs({ ... }) do set[x] = true end
  return function(v) return set[v] == true end
end
local function int_in(a, b) return function(v) return math.type(v) == "integer" and v >= a and v <= b end end
local function plain(v)
  local tv = type(v)
  if tv == "function" or tv == "userdata" or tv == "thread" then return false end
  if tv == "table" then for _, x in pairs(v) do if not plain(x) then return false end end end
  return true
end
local tone = enum("neutral", "info", "ok", "warning", "danger")
local text200 = str(200)
local text2000 = str(2000)
local action = function(v) return type(v) == "string" and #v >= 1 and #v <= 64 end

local function list_of(check, lo, hi)
  return function(v)
    if type(v) ~= "table" or #v < lo or #v > hi then return false end
    for i = 1, #v do if not check(v[i]) then return false end end
    return true
  end
end

local function option(o) return type(o) == "table" and o.value ~= nil and type(o.label) == "string" and #o.label <= 200 end

local function row_ok(r)
  if type(r) ~= "table" or type(r.title) ~= "string" then return false end
  for k, v in pairs(r) do
    local ok = (k == "id" and type(v) == "string") or ((k == "title" or k == "sub" or k == "meta" or k == "image") and text200(v))
      or (k == "tone" and tone(v)) or (k == "action" and action(v)) or (k == "value" and plain(v))
    if not ok then return false end
  end
  return true
end

local function table_row_ok(r)
  if type(r) ~= "table" or type(r.cells) ~= "table" or #r.cells > 12 then return false end
  for _, c in ipairs(r.cells) do if type(c) ~= "string" and type(c) ~= "number" then return false end end
  for k in pairs(r) do if k ~= "cells" and k ~= "action" and k ~= "value" then return false end end
  return true
end

local gap = num
local SPEC = {
  column = { gap = gap, align = enum("start", "center", "end", "stretch") },
  row = { gap = gap, align = enum("start", "center", "end", "stretch") },
  grid = { gap = gap, columns = int_in(1, 6) },
  tabs = { tabs = list_of(text200, 1, 12), selected = int_in(1, 12), action = action, _req = { "tabs" } },
  scroll = { max_height = enum("s", "m", "l") },
  card = { title = text200, eyebrow = text200, link_label = text200, action = action, value = plain },
  section = { title = text200, link_label = text200, action = action, _req = { "title" } },
  text = { text = text2000, style = enum("title", "heading", "body", "meta", "eyebrow", "value"), tone = tone, wrap = bool, _req = { "text" } },
  chip = { text = text200, tone = tone, action = action, selected = bool, _req = { "text" } },
  badge = { text = text200, tone = tone, _req = { "text" } },
  avatar = { initial = function(v) return type(v) == "string" and utf8.len(v) and utf8.len(v) >= 1 and utf8.len(v) <= 4 end,
             color = int_in(1, 8), size = enum("s", "m", "l"), _req = { "initial" } },
  image = { src = text200, size = enum("l", "m", "s"), state = enum("alive", "dead", "missed", "empty"),
            owner = int_in(1, 8), label = text200, _req = { "src" } },
  bar = { value = function(v) return num(v) and v >= 0 and v <= 1 end, tone = tone, label = text200, _req = { "value" } },
  stat = { label = text200, value = function(v) return type(v) == "string" or num(v) end, action = action, _req = { "value" } },
  list = { rows = function(v)
      if type(v) ~= "table" or #v > 500 then return false end
      for _, r in ipairs(v) do if not row_ok(r) then return false end end
      return true
    end, selected = str(64), _req = { "rows" } },
  table = { columns = list_of(text200, 1, 12), rows = function(v)
      if type(v) ~= "table" or #v > 500 then return false end
      for _, r in ipairs(v) do if not table_row_ok(r) then return false end end
      return true
    end, _req = { "columns", "rows" } },
  button = { label = text200, action = action, variant = enum("primary", "secondary", "quiet", "danger"), value = plain,
             confirm = function(c)
               if type(c) ~= "table" or type(c.title) ~= "string" or type(c.text) ~= "string" then return false end
               for k in pairs(c) do
                 if k ~= "title" and k ~= "text" and k ~= "confirm_label" and k ~= "danger" then return false end
               end
               return true
             end, _req = { "label", "action" } },
  toggle = { action = action, label = text200, checked = bool, _req = { "action" } },
  select = { options = list_of(option, 1, 100), selected = function(v) return v ~= nil end, action = action, _req = { "options", "action" } },
  segmented = { options = list_of(option, 2, 3), selected = function(v) return v ~= nil end, action = action, _req = { "options", "action" } },
  textfield = { action = action, text = text2000, placeholder = text200, error = text200, _req = { "action" } },
  empty = { title = text200, text = text2000, action_label = text200, action = action, tone = tone, _req = { "title" } },
  location = { title = text200, sub = text200, status = enum("open", "encounter", "caught", "missed", "none"), _req = { "title" } },
  map = { image = text200, image_w = int_in(1, 16384), image_h = int_in(1, 16384), players = plain, routes = plain,
          filter = enum("all", "me", "open"), me = function(v) return v ~= nil end, selected = function(v) return v ~= nil end,
          legend = bool, popover = plain, action = action },
}
local CONTAINER = { column = true, row = true, grid = true, tabs = true, scroll = true, card = true, section = true, location = true }

local count = 0
local ids

local function check(b, path, depth)
  if type(b) ~= "table" then return nil, path .. ": block expected" end
  if depth > 24 then return nil, path .. ": too deep" end
  count = count + 1
  if count > 2000 then return nil, path .. ": more than 2000 blocks" end
  local spec = SPEC[b.type]
  if not spec then return nil, path .. ".type: unknown block " .. tostring(b.type) end
  if b.id ~= nil then
    if type(b.id) ~= "string" or not b.id:match("^[%w_.%-]+$") or #b.id > 64 then return nil, path .. ".id: bad id" end
    if ids[b.id] then return nil, path .. ".id: duplicate " .. b.id end
    ids[b.id] = true
  end
  for k, v in pairs(b) do
    if k ~= "type" and k ~= "id" and k ~= "children" then
      local f = spec[k]
      if k == "_req" or not f then return nil, path .. "." .. tostring(k) .. ": unknown prop for " .. b.type end
      if not f(v) then return nil, path .. "." .. k .. ": invalid value" end
    end
  end
  for _, r in ipairs(spec._req or {}) do
    if b[r] == nil then return nil, path .. "." .. r .. ": required" end
  end
  if b.children ~= nil then
    if not CONTAINER[b.type] then return nil, path .. ".children: " .. b.type .. " takes no children" end
    for i, c in ipairs(b.children) do
      local ok, err = check(c, path .. ".children[" .. i .. "]", depth + 1)
      if not ok then return nil, err end
    end
  end
  if b.type == "tabs" and b.children and #b.children > #b.tabs then return nil, path .. ": more pages than tabs" end
  if b.type == "table" then
    for i, r in ipairs(b.rows) do
      if #r.cells > #b.columns then return nil, path .. ".rows[" .. i .. "]: more cells than columns" end
    end
  end
  return true
end

function V.validate(tree)
  count, ids = 0, {}
  return check(tree, "tree", 1)
end

--- Find a block by id in a tree (for tests).
function V.find(tree, id)
  if type(tree) ~= "table" then return nil end
  if tree.id == id then return tree end
  for _, c in ipairs(tree.children or {}) do
    local f = V.find(c, id)
    if f then return f end
  end
  return nil
end

--- Find all blocks of a type.
function V.all(tree, typ, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if tree.type == typ then out[#out + 1] = tree end
  for _, c in ipairs(tree.children or {}) do V.all(c, typ, out) end
  return out
end

return V
