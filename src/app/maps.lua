-- Region map, two sources. (1) From the game picture: the player opens the map in the game on the 3DS
-- bottom screen and "Take map from screen" captures it with uz.video.capture (permission video.capture,
-- Uzume 0.11+ with the game picture API). (2) From the game files: pokemon-core `map_candidates()` lists
-- large images found in the player's own RomFS (nil, "not_ready" while it still scans), `map_image(id)` returns
-- one as PNG, `map_selected()` is the core's own pick; the player browses them and confirms one. The PNG stays
-- in the own cache of this player (never in the run state):
--   map/<game id>.png   the map in use (empty file = removed)
--   map/current.txt     game id of the last map (the run view in the shell has no game id)
--   map/cand-<n>.png    preview of file candidate n of the list (overwritten when the list changes)
--   map/coords.json     { map = game id, crop = { t, b, l, r }, routes = { [route key] = { x, y } },
--                         source = "files", file = candidate id (only for a map from the game files) };
--                       crop = percent of the captured screen cut off at top/bottom/left/right when the stored PNG was
--                       taken (the capture rect lies inside the bottom screen, so the PNG is already cropped);
--                       0 for a map from the game files
-- Route positions are image pixels of the stored map. Taking the map again with another crop, or switching the
-- source, RESCALES the recorded positions (screen fraction kept) instead of clearing them; without a known old
-- image nothing changes. The default crop is the full screen.
-- Route positions on the image are our own recorded facts (data.oras.COORDS[game id]) merged under the
-- recorded ones. Retaking or removing the map keeps the positions. Without uz.video (older app) the
-- Map tab says so; nothing else depends on it.
local util = require("model.util")
local oras = require("data.oras")

local M = {}
M.__index = M

M.COORDS_FILE, M.CURRENT = "map/coords.json", "map/current.txt"
M.NO_GAME = "game"
M.SIDES = { "t", "b", "l", "r" }
M.CORE = "pokemon.core"
M.SCAN_MS, M.RETRY_MS, M.MAX_CANDIDATES = 3000, 2000, 40
M.MAX_CROP = 45 -- percent per side; opposite sides together stay below 90

--- Clamp a crop table { t, b, l, r } (percent) to whole numbers 0..MAX_CROP with opposite sides <= 90 together.
function M.clean_crop(c)
  local out = {}
  for _, k in ipairs(M.SIDES) do
    local v = type(c) == "table" and tonumber(c[k]) or 0
    out[k] = math.max(0, math.min(M.MAX_CROP, math.floor((v or 0) + 0.5)))
  end
  return out
end

--- Width and height from a PNG header, or nil.
function M.png_size(s)
  if type(s) ~= "string" or #s < 24 or s:sub(1, 8) ~= "\137PNG\r\n\26\n" or s:sub(13, 16) ~= "IHDR" then return nil end
  local w, h = string.unpack(">I4I4", s, 17)
  if w < 1 or h < 1 or w > 16384 or h > 16384 then return nil end
  return w, h
end

local function safe(id) return (tostring(id):gsub("[^%w_%-]", "_"):sub(1, 60)) end

--- `live` = false in the shell run view (no game: nothing to capture). Game id = uz.game.code.
function M.new(uz, live)
  local code = type(uz.game) == "table" and uz.game.code or nil
  local self = setmetatable({ uz = uz, state = "none", coords = {}, live = live ~= false,
                              api = type(uz.video) == "table" and type(uz.video.capture) == "function" }, M)
  self.game = (type(code) == "string" and code ~= "") and code or nil
  self:restore()
  self.edit = self.crop and M.clean_crop(self.crop) or M.clean_crop({})
  -- map from the game files: only in a live run and when uz.call exists; the core decides on the first call
  self.files = { state = (self.live and type(uz.call) == "function") and "idle" or "unsupported", list = {}, idx = 1,
                 previews = {}, failed = {}, retry = {}, next_at = 0 }
  return self
end

function M:read(name)
  local ok, v = pcall(self.uz.cache.read, name)
  return ok and v or nil
end

function M:write(name, data)
  return (pcall(self.uz.cache.write, name, data))
end

function M:file() return "map/" .. safe(self.id or M.NO_GAME) .. ".png" end

--- Restore the image and the recorded positions from the cache.
function M:restore()
  self.id = self.game
  if not self.id then
    local cur = self:read(M.CURRENT)
    self.id = (type(cur) == "string" and cur:match("^%s*(.-)%s*$") ~= "") and cur:match("^%s*(.-)%s*$") or nil
  end
  local png = self.id and self:read(self:file()) or nil
  local w, h = M.png_size(png)
  if w then self.w, self.h, self.state = w, h, "ready" end
  self:load_coords()
end

function M:load_coords()
  self.coords, self.crop, self.source, self.file_id = {}, nil, nil, nil
  local s = self:read(M.COORDS_FILE)
  if type(s) ~= "string" or not self.id then return end
  local id = s:match('"map"%s*:%s*"(.-)"')
  if id ~= self.id then return end
  if s:match('"source"%s*:%s*"files"') then
    self.source, self.file_id = "files", s:match('"file"%s*:%s*"(.-)"')
    if self.file_id == "" then self.file_id = nil end
  end
  local cs = s:match('"crop"%s*:%s*(%b{})')
  if cs then
    local c = {}
    for _, k in ipairs(M.SIDES) do c[k] = tonumber(cs:match('"' .. k .. '"%s*:%s*(%d+)')) end
    self.crop = M.clean_crop(c)
  end
  local routes = s:match('"routes"%s*:%s*(%b{})') or ""
  for key, x, y in routes:gmatch('"([^"]+)"%s*:%s*{%s*"x"%s*:%s*(-?%d+)%s*,%s*"y"%s*:%s*(-?%d+)%s*}') do
    if oras.is_route(key) then self.coords[key] = { x = tonumber(x), y = tonumber(y) } end
  end
end

function M:save_coords()
  local routes = {}
  for key, c in pairs(self.coords) do routes[key] = { x = c.x, y = c.y } end
  local files = self.source == "files" and self.file_id
  self:write(M.COORDS_FILE, util.encode({ map = self.id, crop = self.crop, routes = routes,
    source = files and "files" or nil, file = files or nil }))
end

--- Route positions: data.oras.COORDS[map id] with the recorded ones on top.
function M:merged()
  local out = {}
  for key, c in pairs(self.id and oras.COORDS[self.id] or {}) do out[key] = c end
  for key, c in pairs(self.coords) do
    local base = out[key]
    out[key] = { x = c.x, y = c.y, area = base and base.area or nil }
  end
  return out
end

--- Record the position of a route (image pixels, clamped to the image).
function M:set_coord(route, x, y)
  if self.state ~= "ready" or not oras.is_route(route) then return false end
  x = math.max(0, math.min(self.w, math.floor(x + 0.5)))
  y = math.max(0, math.min(self.h, math.floor(y + 0.5)))
  self.coords[route] = { x = x, y = y }
  self:save_coords()
  return true
end

--- One Lua table line with all positions (data.oras.COORDS entry), written to the log. nil without positions.
function M:export_line()
  local all = self:merged()
  local keys = {}
  for key in pairs(all) do keys[#keys + 1] = key end
  if #keys == 0 or not self.id then return nil end
  table.sort(keys, function(a, b) return oras.compare(a, b, self.order) end)
  local parts = {}
  for _, key in ipairs(keys) do
    local c = all[key]
    parts[#parts + 1] = string.format("[%q] = { x = %d, y = %d%s }", key, c.x, c.y,
      c.area and string.format(", area = %q", c.area) or "")
  end
  local line = string.format("COORDS[%q] = { %s }", self.id, table.concat(parts, ", "))
  self.uz.log.info("soullink positions: " .. line)
  return line
end

--- Screen to capture: the entry "bottom", else "main" of uz.video.screens() ({ name, x, y, w, h }), else nil.
function M:target()
  local ok, list = pcall(self.uz.video.screens)
  if not ok or type(list) ~= "table" then return nil end
  local by = {}
  for _, sc in ipairs(list) do
    if type(sc) == "table" and math.type(sc.x) == "integer" and math.type(sc.y) == "integer"
        and math.type(sc.w) == "integer" and math.type(sc.h) == "integer" and sc.w > 0 and sc.h > 0 then
      by[sc.name] = sc
    end
  end
  return by.bottom or by.main or nil
end

--- Capture rectangle inside screen `sc` for `crop` (percent): { x, y, w, h } in the screen coordinates.
function M.crop_rect(sc, crop)
  local c = M.clean_crop(crop)
  local l, r = sc.w * c.l // 100, sc.w * c.r // 100
  local tp, bt = sc.h * c.t // 100, sc.h * c.b // 100
  return { x = sc.x + l, y = sc.y + tp, w = math.max(1, sc.w - l - r), h = math.max(1, sc.h - tp - bt) }
end

--- Change one side of the crop being edited by `delta` percent ("t", "b", "l", "r"), within the limits.
function M:adjust(side, delta)
  if not (self.edit and self.edit[side] ~= nil) or math.type(delta) ~= "integer" then return false end
  local opp = ({ t = "b", b = "t", l = "r", r = "l" })[side]
  local v = math.max(0, math.min(M.MAX_CROP, self.edit[side] + delta))
  v = math.min(v, 90 - self.edit[opp])
  self.edit[side] = math.max(0, v)
  return true
end

--- Set the crop being edited: "none" (full screen) or "applied" (of the stored map).
function M:preset(name)
  if name == "none" then self.edit = M.clean_crop({})
  elseif name == "applied" then self.edit = self.crop and M.clean_crop(self.crop) or M.clean_crop({})
  else return false end
  return true
end

--- Start a capture of the game picture. Returns true when a request is pending.
function M:capture()
  self.error = nil
  if not self.api then return false end
  if not self.live or not self.game then self.error = "unsupported"; return false end
  if self.pending then self.error = "busy"; return false end
  local target = self:target()
  if not target then self.error = "no_frame"; return false end
  local rect = M.crop_rect(target, self.edit)
  local ok, id = pcall(self.uz.video.capture, rect)
  if not ok then
    self.uz.log.warn("soullink map capture: " .. tostring(id))
    self.error = "failed"
    return false
  end
  self.pending, self.pending_crop = id, M.clean_crop(self.edit)
  return true
end

--- Host event video.captured { id, ok, png, w, h, error }. Returns true when the view changed.
function M:on_captured(e)
  if type(e) ~= "table" or not self.pending or e.id ~= self.pending then return false end
  self.pending = nil
  if e.ok ~= true then
    self.error = type(e.error) == "string" and e.error or "failed"
    return true
  end
  local w, h = M.png_size(e.png)
  if not w then self.error = "failed"; return true end
  self.id = self.game
  local old_w, old_h, old_crop = self.w, self.h, self.crop or M.clean_crop({})
  if not (self:write(self:file(), e.png) and self:write(M.CURRENT, self.id)) then
    self.error = "failed"
    return true
  end
  self.w, self.h, self.state, self.error = w, h, "ready", nil
  self:load_coords()
  self:rescale(old_w, old_h, old_crop, self.pending_crop, w, h)
  self.crop = self.pending_crop
  self.source, self.file_id = "screen", nil
  self:save_coords()
  self.edit = M.clean_crop(self.crop)
  return true
end

-- ---------------------------------------------------------------- map from the game files

local function png_ok(png) return type(png) == "string" and M.png_size(png) ~= nil end

--- Ask the core for the candidates (until it is done scanning) and fetch the preview of the shown one.
--- Called from every tick; returns true when the view changed. A core without the functions (or without
--- uz.call) turns the option off for good.
function M:files_step(now)
  local f = self.files
  if f.state == "unsupported" then return false end
  local changed = false
  if f.state ~= "done" then
    if now < f.next_at then return false end
    f.next_at = now + M.SCAN_MS
    local ok, list, why = pcall(self.uz.call, M.CORE, "map_candidates")
    if not ok or why == "unsupported" then f.state = "unsupported"; return true end
    if type(list) ~= "table" then
      if f.state ~= "scanning" then f.state, changed = "scanning", true end
      return changed
    end
    f.list = {}
    for _, c in ipairs(list) do
      if #f.list >= M.MAX_CANDIDATES then break end
      if type(c) == "table" and type(c.id) == "string" and c.id ~= "" then
        f.list[#f.list + 1] = { id = c.id, w = math.tointeger(c.w), h = math.tointeger(c.h) }
      end
    end
    f.state, f.idx, f.previews, f.failed, f.retry = "done", 1, {}, {}, {}
    local oks, sel = pcall(self.uz.call, M.CORE, "map_selected")
    f.selected = (oks and type(sel) == "string" and sel ~= "") and sel or nil
    changed = true
  end
  local c = f.list[f.idx]
  if c and not f.previews[c.id] and not f.failed[c.id] and now >= (f.retry[c.id] or 0) then
    local ok, png, why = pcall(self.uz.call, M.CORE, "map_image", c.id)
    local name = "map/cand-" .. f.idx .. ".png"
    if ok and png_ok(png) and self:write(name, png) then
      f.previews[c.id], changed = name, true
    elseif ok and why == "not_ready" then
      f.retry[c.id] = now + M.RETRY_MS
    else
      f.failed[c.id], changed = true, true
    end
  end
  return changed
end

--- Show the previous (-1) or next (1) candidate, wrapping around.
function M:files_nav(delta, now)
  local f = self.files
  local n = #f.list
  if n == 0 or (delta ~= 1 and delta ~= -1) then return false end
  f.idx = (f.idx - 1 + delta) % n + 1
  f.error = nil
  self:files_step(now or 0)
  return true
end

--- Use the shown candidate as the map: the positions move to the new image like a crop change. Returns true on success.
function M:files_use()
  local f = self.files
  local c = f.list[f.idx]
  f.error = nil
  if not c then return false end
  if not self.live or not self.game then f.error = "unsupported"; return false end
  local png = f.previews[c.id] and self:read(f.previews[c.id]) or nil
  if not png_ok(png) then
    local ok, p = pcall(self.uz.call, M.CORE, "map_image", c.id)
    png = ok and p or nil
  end
  local w, h = M.png_size(png)
  if not w then f.error = "failed"; return false end
  self.id = self.game
  local old_w, old_h, old_crop = self.w, self.h, self.crop or M.clean_crop({})
  if not (self:write(self:file(), png) and self:write(M.CURRENT, self.id)) then f.error = "failed"; return false end
  self.w, self.h, self.state, self.error = w, h, "ready", nil
  self:load_coords()
  self:rescale(old_w, old_h, old_crop, M.clean_crop({}), w, h)
  self.crop, self.source, self.file_id = M.clean_crop({}), "files", c.id
  self:save_coords()
  self.edit = M.clean_crop(self.crop)
  return true
end

--- Positions recorded on an image of old_w x old_h cropped by `old` (percent) move to the new image
--- (new_w x new_h, crop `new`): the point on the screen stays the same. Needs an old image; otherwise nothing changes.
function M:rescale(old_w, old_h, old, new, new_w, new_h)
  if not old_w or not old_h or next(self.coords) == nil then return end
  local function frac(c) return c.l / 100, c.t / 100, 1 - (c.l + c.r) / 100, 1 - (c.t + c.b) / 100 end
  local ol, ot, ow, oh = frac(old)
  local nl, nt, nw, nh = frac(new)
  for _, c in pairs(self.coords) do
    local fx, fy = ol + c.x / old_w * ow, ot + c.y / old_h * oh
    c.x = math.max(0, math.min(new_w, math.floor((fx - nl) / nw * new_w + 0.5)))
    c.y = math.max(0, math.min(new_h, math.floor((fy - nt) / nh * new_h + 0.5)))
  end
end

--- Remove the map image; the recorded positions stay.
function M:remove()
  if self.state == "ready" then self:write(self:file(), "") end
  self.w, self.h, self.state, self.error = nil, nil, "none", nil
  if self.source == "files" then
    self.source, self.file_id = nil, nil
    self:save_coords()
  end
end

--- The candidates for the UI: { avail, state = idle|scanning|done, n, idx, cand = { id, w, h, src?, failed?,
--- suggested?, current? }, error? }.
function M:files_view()
  local f = self.files
  local out = { avail = f.state ~= "unsupported", state = f.state, n = #f.list, idx = f.idx, error = f.error }
  local c = f.list[f.idx]
  if c then
    local pv = f.previews[c.id]
    out.cand = { id = c.id, w = c.w, h = c.h, src = pv and ("cache:" .. pv) or nil, failed = f.failed[c.id] or nil,
      suggested = (f.selected ~= nil and f.selected == c.id) or nil,
      current = (self.state == "ready" and self.source == "files" and self.file_id == c.id) or nil }
  end
  return out
end

--- What the UI needs: { state = none|ready, api, live, pending, error?, src?, w?, h?, id?, source?, files, coords }.
function M:view()
  return { state = self.state, id = self.id, w = self.w, h = self.h, api = self.api, live = self.live,
           pending = self.pending ~= nil, error = self.error, crop = self.crop, edit = self.edit,
           source = self.source, files = self:files_view(),
           src = self.state == "ready" and ("cache:" .. self:file()) or nil, coords = self:merged() }
end

return M
