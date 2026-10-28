-- Own state: one object per participant, written with uz.run.setState (limit 64 KiB).
local util = require("model.util")

local S = {}

S.VERSION = 1
--- Soft limit well below the 64 KiB platform limit; guard() compacts above it.
S.MAX_BYTES = 48 * 1024
S.MAX_NAMES = { sp = 400, loc = 200 }  -- entries per name table
S.NAME_LEN = { sp = 24, loc = 32 }     -- characters per name
S.MAX_AREAS = 400
S.MAX_PLACES = 600

--- Fresh state. `game` = { id = ..., language = ... } (both optional).
---
--- Schema (v = 1), all keys strings, JSON-able:
---   v, started (bool: baseline taken), inb (bool: wild battle was active at the last diff)
---   game   = { id, language }
---   place  = { key?, name?, zone?, manual }   key = route key or nil (no place / not a route)
---   baseline = { ["<hex8 personality>"] = true }   mons present before tracking, ignored forever
---   mons   = { ["<hex8>"] = { species, form?, nickname?, nicknamed? (false only), level, shiny? (true only),
---              route?, where = "team"|"box"|"gone", deaths? (absent = 0), hp?, gift? (true only),
---              why? = "extra"|"dupe"|"shiny"|"additional"|"gift", miss? } }
---   routes = { [route key] = { status = "encounter"|"caught"|"missed", mon?, species?, kind? } }
---   order  = { "<hex8>", ... }   tracked mons in team order
---   badges = number
---   names  = { sp = { ["<species id>"] = name }, loc = { ["<location id>"] = name } }   display names read from
---            the game when a catch / encounter / place was recorded (short, one entry per id), so other
---            players and the server show names without a running game
---   areas  = { <location id>, ... }   encounter areas in game order (pokemon-core areas()), for ordering
---   places = { <location id>, ... }   every place of the game in game order (pokemon-core locations(), else
---            the areas), for the place select; areas is the subset with encounter slots
---   pend   = { since?, zone?, loc? }   a wild battle ended and its encounter is still undecided: it becomes
---            caught when the mon shows up, missed when the player moves on, the next wild battle starts or
---            60 s pass (model.detect)
---   enc_seq = n   last handled pokemon-core encounters() seq
---   mons[..].ty = n   primary type id (only with the rule pairs_differ_primary_type)
function S.new(game)
  local g = {}
  if type(game) == "table" then
    g.id = game.id
    g.language = game.language
  end
  return S.ensure({
    v = S.VERSION, started = false, inb = false,
    game = g, place = { manual = false },
    baseline = {}, mons = {}, routes = {}, order = {}, badges = 0,
  })
end

--- Complete a state received from the server (nil or older shape) so the model can use it.
function S.ensure(st)
  if type(st) ~= "table" then return S.new() end
  st.v = st.v or S.VERSION
  st.game = st.game or {}
  st.place = st.place or { manual = false }
  st.baseline = st.baseline or {}
  st.mons = st.mons or {}
  st.routes = st.routes or {}
  st.order = st.order or {}
  st.badges = st.badges or 0
  st.names = type(st.names) == "table" and st.names or {}
  st.names.sp = type(st.names.sp) == "table" and st.names.sp or {}
  st.names.loc = type(st.names.loc) == "table" and st.names.loc or {}
  return st
end

--- Remember a display name read from the game: kind "sp" (species id) or "loc" (location id).
--- Short, deduplicated per id, limited in count. Returns true when the table changed.
function S.note_name(st, kind, id, name)
  if math.type(id) == "float" then id = math.tointeger(id) end
  if math.type(id) ~= "integer" or type(name) ~= "string" then return false end
  name = util.clean_text(name, S.NAME_LEN[kind])
  if not name then return false end
  S.ensure(st)
  local t, k = st.names[kind], tostring(id)
  if t[k] == name then return false end
  if t[k] == nil then
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n >= S.MAX_NAMES[kind] then return false end
  end
  t[k] = name
  return true
end

--- Death count of a tracked mon (absent = 0).
function S.deaths(mon) return mon and mon.deaths or 0 end

--- Size in bytes of the JSON encoding of `st`.
function S.size(st) return util.json_size(st) end

--- Drop what can be dropped safely when the state is large: mons that are gone and own no route
--- entry, then shorten nicknames. Returns the (same) state. Baseline entries are never dropped.
function S.compact(st)
  local referenced = {}
  for _, r in pairs(st.routes) do if r.mon then referenced[r.mon] = true end end
  for pid, m in pairs(st.mons) do
    if m.where == "gone" and not referenced[pid] and (m.deaths or 0) == 0 then st.mons[pid] = nil end
  end
  if S.size(st) > S.MAX_BYTES then
    -- names nothing refers to
    local sp, loc = {}, {}
    for _, m in pairs(st.mons) do sp[tostring(m.species)] = true end
    for key, r in pairs(st.routes) do
      sp[tostring(r.species or "")] = true
      local id = key:match("^loc:(%d+)$")
      if id then loc[id] = true end
    end
    local pid = st.place and st.place.loc
    if pid then loc[tostring(pid)] = true end
    for k in pairs(st.names.sp) do if not sp[k] then st.names.sp[k] = nil end end
    for k in pairs(st.names.loc) do if not loc[k] then st.names.loc[k] = nil end end
  end
  if S.size(st) > S.MAX_BYTES then
    for _, m in pairs(st.mons) do
      if m.nickname then m.nickname = util.clean_text(m.nickname, 12) end
    end
  end
  return st
end

--- Size guard: returns ok, bytes. Compacts when above MAX_BYTES; ok is false when it still is.
function S.guard(st)
  local n = S.size(st)
  if n <= S.MAX_BYTES then return true, n end
  S.compact(st)
  n = S.size(st)
  return n <= S.MAX_BYTES, n
end

return S
