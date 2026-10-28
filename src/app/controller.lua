-- App controller: wires the model to uz (core polling, run state and events, UI slots, actions).
-- Everything the UI shows comes from view.view(); everything the user changes goes through
-- detect.set_place / model.corrections and the run (state and events), never into the view directly.
local util = require("model.util")
local rules = require("model.rules")
local state = require("model.state")
local detect = require("model.detect")
local snapshot = require("model.snapshot")
local events = require("model.events")
local corrections = require("model.corrections")
local view_mod = require("model.view")
local gym = require("model.gym")
local oras = require("data.oras")
local common = require("ui.common")
local corr_ui = require("ui.corrections")
local panel = require("ui.panel")
local hud = require("ui.hud")
local screen = require("ui.screen")
local tile = require("ui.tile")
local board = require("ui.board")
local sync = require("app.sync")
local icons_mod = require("app.icons")
local maps_mod = require("app.maps")

local A = {}
A.__index = A

A.POLL_MS = 500      -- team, place, battle, badges
A.BOX_MS = 5000      -- boxes
A.RENDER_MS = 250    -- at most 4 UI refreshes per second
A.BOARD_MS = 5000    -- run board
A.HUD_MS = 3000      -- HUD stays expanded after a linked death
A.NOTICE_TRIES = 40  -- renders to wait for the state that shows a death
A.MAX_ZONES = 120    -- learned zone mappings kept in the own state
A.CAL_STEPS = { [2] = true, [10] = true, [40] = true }
A.NAME_BUDGET = 16   -- core name() lookups per poll
A.CORE = "pokemon.core"

function A.new(uz, host)
  local self = setmetatable({}, A)
  self.uz = uz
  self.host = host or "uz"  -- host event source
  self.tr = function(key, vars) return uz.i18n.t(key, vars) end
  self.ui = {}
  self.events, self.seen = {}, {}
  self.queue = {}          -- death events waiting for the view
  self.tiles, self.tile_slots = {}, {}
  self.sync = sync.new(uz)
  self.last_poll, self.last_box, self.last_render, self.last_board = -1e9, -1e9, -1e9, -1e9
  self.dirty = true
  self.errors = {}
  self.unsupported = {} -- parts of pokemon.core that answered "unsupported"
  self.gnames = { species = {}, location = {} } -- names read from the game (core name())
  self.types = {}          -- "species:form" -> primary type id
  self.name_budget = A.NAME_BUDGET
  return self
end

local function warn_once(self, key, ...)
  if not self.errors[key] then
    self.errors[key] = true
    self.uz.log.warn(...)
  end
end

-- ---------------------------------------------------------------- names and areas from the core

local function int(v)
  if math.type(v) == "float" then v = math.tointeger(v) end
  if math.type(v) == "integer" then return v end
  return nil
end

--- Display name read from the game (`name(kind, id)`), cached; a few lookups per poll.
--- kind = "species" | "location". nil while the game text is not ready or unsupported.
function A:game_name(kind, id)
  id = int(id)
  if id == nil then return nil end
  local cached = self.gnames[kind][id]
  if cached then return cached end
  if kind == "location" and self.areas_info and self.areas_info.names[id] then return self.areas_info.names[id] end
  if self.name_unsupported or self.name_budget <= 0 or self.viewing then return nil end
  self.name_budget = self.name_budget - 1
  local ok, v, why = pcall(self.uz.call, A.CORE, "name", kind, id)
  if not ok or why == "unsupported" then self.name_unsupported = true; return nil end
  if type(v) == "string" and v ~= "" then
    self.gnames[kind][id] = v
    -- remembered in the run state: other players and the server show the name without a running game
    if self.st then state.note_name(self.st, kind == "species" and "sp" or "loc", id, v) end
    return v
  end
  return nil
end

--- Areas info from the encounter areas (`areas()` list) and the places (`locations()` list), either may be nil:
--- { set = encounter areas, order = encounter areas in game order, names = { [id] = name },
---   places = every place in game order }. Deduplicated by location id; a place without encounter slots
--- (town ...) is a place option but no route key.
local function build_info(areas, locs)
  local info = { set = {}, order = {}, names = {}, places = {} }
  local area_ids = {}
  for _, a in ipairs(areas or {}) do
    local id = type(a) == "table" and int(a.id) or nil
    if id and not info.set[id] then
      info.set[id] = true
      area_ids[#area_ids + 1] = id
      if type(a.name) == "string" and a.name ~= "" then info.names[id] = a.name end
    end
  end
  local seen = {}
  for _, l in ipairs(locs or {}) do
    local id = type(l) == "table" and int(l.id) or nil
    if id and not seen[id] then
      seen[id] = true
      info.places[#info.places + 1] = id
      if info.names[id] == nil and type(l.name) == "string" and l.name ~= "" then info.names[id] = l.name end
      if l.has_encounters == true and not info.set[id] then
        info.set[id] = true
        area_ids[#area_ids + 1] = id
      end
    end
  end
  for _, id in ipairs(area_ids) do
    if not seen[id] then seen[id] = true; info.places[#info.places + 1] = id end
  end
  if locs then
    for _, id in ipairs(info.places) do if info.set[id] then info.order[#info.order + 1] = id end end
  else
    info.order = area_ids
  end
  return info
end

A.REASK_MS = 5000      -- areas()/locations() asked again while not ready, failed, empty or unnamed
A.REFRESH_MS = 30000   -- a complete list is refreshed this often

--- A list is final when it has entries and all of them have a name.
local function final_list(list)
  if type(list) ~= "table" or #list == 0 then return false end
  for _, e in ipairs(list) do
    if type(e) ~= "table" or type(e.name) ~= "string" or e.name == "" then return false end
  end
  return true
end

--- Ask one list function of the core. Returns the list when it changed, nil otherwise; sets the next ask time.
--- "unsupported" is permanent; nil + "not_ready"/"failed", an empty list or entries without names are asked
--- again every REASK_MS, a complete list every REFRESH_MS.
function A:ask_list(fn, field, now)
  local ok, list, why = pcall(self.uz.call, A.CORE, fn)
  if not ok or why == "unsupported" then self[fn .. "_unsupported"] = true; return nil end
  if type(list) ~= "table" then self[fn .. "_next"] = now + (self[field] and A.REASK_MS or 2000); return nil end
  self[fn .. "_next"] = now + (final_list(list) and A.REFRESH_MS or A.REASK_MS)
  if util.encode(list) == util.encode(self[field] or false) then return nil end
  self[field] = list
  return list
end

--- Encounter areas (`areas()`) and places (`locations()`, optional, pokemon-core >= 0.3.1):
--- self.areas_info = { set, order, names, places }. nil while nothing is known. Both lists are asked again
--- until they are complete (see ask_list) and refreshed from time to time. A core without locations() works
--- with the areas alone.
function A:refresh_areas()
  if self.viewing then return end
  local now = self.uz.clock()
  local changed = false
  if not self.areas_unsupported and not (self.areas_next and now < self.areas_next) then
    if self:ask_list("areas", "area_list", now) then changed = true end
  end
  if not self.locations_unsupported and not (self.locations_next and now < self.locations_next) then
    if self:ask_list("locations", "loc_list", now) then changed = true end
  end
  if (self.area_list or self.areas_unsupported) and (changed or (not self.areas_info and self.loc_list)) then
    self.areas_info = build_info(self.area_list, self.loc_list)
    self.dirty = true
  end
end

--- Game data diagnostics of pokemon-core >= 0.3.2 (`diagnostics()`, a flat table of numbers and strings), only
--- asked once to learn whether the core has them, then every 5 s while the place list is empty or the "Game data" block is open (it is closed until the player opens it). A core
--- without it (unsupported) leaves self.diag nil and the block is omitted.
function A:refresh_diag()
  if self.viewing or self.diag_unsupported then return end
  local empty = not (self.areas_info and #self.areas_info.places > 0)
  if not (empty or common.diag_open(self.ui) or self.diag == nil) then return end
  local now = self.uz.clock()
  if self.diag_next and now < self.diag_next then return end
  self.diag_next = now + 5000
  local ok, v, why = pcall(self.uz.call, A.CORE, "diagnostics")
  if not ok or why == "unsupported" then self.diag_unsupported, self.diag = true, nil; return end
  if type(v) ~= "table" then return end
  local d = {}
  for k, x in pairs(v) do
    if type(k) == "string" and (type(x) == "number" or type(x) == "string" or type(x) == "boolean") then d[k] = x end
  end
  if util.encode(d) ~= util.encode(self.diag or {}) then self.diag, self.dirty = d, true end
end

--- Icon check (pokemon-core >= 0.3.4 `icon_variants(species, form?)`): while the "Game data" block is open, asked
--- once per opening for the first team creature: up to 4 `{ label, desc, png }` variants, written to the cache as
--- `diag/icon-<label>.png` and shown side by side in the block. `nil, "not_ready"` is retried every 5 s;
--- `unsupported` (older core) switches it off for good and the section stays hidden.
function A:refresh_icon_check()
  if self.viewing or self.variants_unsupported then return end
  if not common.diag_open(self.ui) then
    if self.icheck ~= nil or self.icheck_done then self.icheck, self.icheck_done, self.icheck_next = nil, false, nil; self.dirty = true end
    return
  end
  if self.icheck_done then return end
  local now = self.uz.clock()
  if self.icheck_next and now < self.icheck_next then return end
  local first = self.first_team -- first creature of the team as the core reports it
  local species = first and int(first.species)
  if not species then return end
  local form = int(first.form) or 0
  local ok, list, why = pcall(self.uz.call, A.CORE, "icon_variants", species, form)
  if not ok or why == "unsupported" then self.variants_unsupported, self.icheck = true, nil; return end
  if list == nil and why == "not_ready" then self.icheck_next = now + 5000; return end
  self.icheck_done = true -- asked once per opening
  if type(list) ~= "table" then return end
  local items = {}
  for _, v in ipairs(list) do
    if #items >= 4 then break end
    if type(v) == "table" and type(v.label) == "string" and v.label:match("^%u$") and type(v.png) == "string" and #v.png > 0 then
      local name = "diag/icon-" .. v.label .. ".png"
      if pcall(self.uz.cache.write, name, v.png) then
        items[#items + 1] = { label = v.label, desc = util.clean_text(v.desc, 60) or "", src = "cache:" .. name }
      end
    end
  end
  if #items > 0 then self.icheck, self.dirty = { species = species, form = form, items = items }, true end
end

--- Primary type of a species (`species_info`), cached; nil when unknown.
function A:primary_type(species, form)
  species = int(species)
  if species == nil or self.types_unsupported then return nil end
  local key = species .. ":" .. tostring(int(form) or 0)
  if self.types[key] ~= nil then return self.types[key] or nil end
  local ok, v, why = pcall(self.uz.call, A.CORE, "species_info", species, int(form) or 0)
  if not ok or why == "unsupported" then self.types_unsupported = true; return nil end
  local t = type(v) == "table" and type(v.types) == "table" and int(v.types[1]) or nil
  if t ~= nil then self.types[key] = t end
  return t
end

--- Primary types of the partners' counted creatures on a route.
function A:partner_types(route)
  local out = {}
  for uid, st in pairs(self:states()) do
    local e = uid ~= self.me and type(st) == "table" and type(st.routes) == "table" and st.routes[route]
    local m = e and e.status == "caught" and e.mon and type(st.mons) == "table" and st.mons[e.mon]
    if m and m.ty ~= nil then out[m.ty] = true end
  end
  return out
end

--- Species name for texts: the record's own text, the game, or the names stored in the run.
function A:species_text(id, hint)
  if type(hint) == "string" and hint ~= "" then return hint end
  local live = self:game_name("species", id)
  if live then return live end
  local nm = self.view and self.view.names and self.view.names.sp[tostring(id)]
  if nm then return nm end
  local own = self.st and self.st.names and self.st.names.sp[tostring(id)]
  return own
end

function A:area_name(id)
  id = int(id)
  return id and ((self.areas_info and self.areas_info.names[id]) or self.gnames.location[id]) or nil
end

-- ---------------------------------------------------------------- start

function A:start()
  local uz, tr = self.uz, self.tr
  uz.ui.on_action(function(action, value, slot) self:on_action(action, value, slot) end)
  if not uz.run then
    self.sync:push("panel", panel.empty(tr))
    self.sync:push("hud", hud.empty(tr))
    self.sync:push("screen", screen.empty(tr))
    return
  end
  self.run = uz.run.current()
  self.me = self.run.me
  self.viewing = self.run.view == true -- run view of the Runs screen: shell context, read only
  -- run view: no game, so no core calls, no tracking, no notices; only the `run` slot shows the run
  if self.viewing then self.sync:push("screen", screen.empty(tr)) end
  self.icons = icons_mod.new(uz)
  self.maps = maps_mod.new(uz, not self.viewing)
  self.st = state.ensure(util.copy(uz.run.state()))
  self.last_enc = (not self.viewing and uz.run.state()) and util.encode(self.st) or nil
  self:load_events()
  self.live = not self.viewing
  uz.run.on("event", function(ev) self:on_event(ev) end)
  uz.run.on("state", function() self.dirty = true end)
  uz.run.on("participants", function() self.dirty = true end)
  uz.run.on("status", function() self.dirty = true end)
  if not self.viewing then
    uz.events.on(self.host, "tiles", function(list) self.tiles = type(list) == "table" and list or {}; self.dirty = true end)
    if self.maps.api then
      uz.events.on(self.host, "video.captured", function(e) if self.maps:on_captured(e) then self.dirty = true end end)
    end
  end
  uz.on_tick(function() self:tick() end)
  self:poll(true)
  self:render()
end

function A:load_events()
  local after = 0
  while true do
    local page = self.uz.run.events(after, 500)
    for _, ev in ipairs(page) do
      if not self.seen[ev.seq] then
        self.seen[ev.seq] = true
        self.events[#self.events + 1] = ev
      end
      after = math.max(after, ev.seq)
    end
    if #page < 500 then break end
  end
end

function A:writable() return common.writable(self.run) end

-- ---------------------------------------------------------------- ticking

function A:tick()
  local now = self.uz.clock()
  if self.writable_cached ~= self:writable() then
    self.writable_cached = self:writable()
    self.dirty = true
  end
  if now - self.last_poll >= A.POLL_MS then
    local full = now - self.last_box >= A.BOX_MS
    self.last_poll = now
    if full then self.last_box = now end
    local ok, err = pcall(self.poll, self, full)
    if not ok then warn_once(self, "poll", "poll failed: " .. tostring(err)) end
  end
  if not self.viewing and self.icons and self.icons:pump(now) then self.dirty = true end
  if not self.viewing and self.maps and self.maps:files_step(now) then self.dirty = true end
  if self.hud_until and now >= self.hud_until then
    self.hud_until, self.hud_text = nil, nil
    self.dirty = true
  end
  if self.board_due and now - self.last_board >= A.BOARD_MS then self.dirty = true end
  if self.dirty and now - self.last_render >= A.RENDER_MS then
    local ok, err = pcall(self.render, self)
    if not ok then warn_once(self, "render", "render failed: " .. tostring(err)) end
  end
end

-- ---------------------------------------------------------------- polling and state

function A:poll(full)
  if not self:writable() then return end
  local cfg = rules.parse(self.run)
  local snap = snapshot.from_core(self.uz, { skip_boxes = (not full) and self.boxes ~= nil, boxes = self.boxes,
    unsupported = self.unsupported })
  if snap.boxes then self.boxes = snap.boxes end
  local t1 = type(snap.team) == "table" and snap.team[1] or nil
  if type(t1) == "table" and int(t1.species) then self.first_team = { species = t1.species, form = t1.form } end
  local game = self.uz.game or {}
  local loc = type(snap.location) == "table" and snap.location or {}
  self.cur_zone, self.cur_loc = int(loc.zone), int(loc.location)
  if self.cur_zone ~= nil or self.cur_loc ~= nil then self.location_ok = true end
  if snap.badges ~= nil then self.badges_seen = true end
  self.name_budget = A.NAME_BUDGET
  self:refresh_areas()
  self:refresh_diag()
  self:refresh_icon_check()
  -- corrections about this player's routes (doesn't count, missed, added by hand) shape detection too
  local overrides, excluded = corrections.route_overrides(corrections.effective(self.events), self.me, self.st)
  local st, facts = detect.diff(self.st, snap, cfg, { now = self.uz.clock(), overrides = overrides, excluded = excluded, game = { id = game.code, language = game.language },
    zones = view_mod.merge_zones(self.run, self:states()),
    areas = self.areas_info, areas_unsupported = self.areas_unsupported,
    names = { species = function(id) return self:game_name("species", id) end },
    types = function(species, form) return self:primary_type(species, form) end,
    partner_types = function(route) return self:partner_types(route) end })
  self:commit(st, facts)
  self:gym_snapshot(snap)
end

--- Save snapshot "before Gym N" once when a gym leader battle starts (model.gym decides). Needs the app's
--- uz.save (Uzume 0.20+); on an older app uz.save is nil and nothing happens. The app limits snapshots to one
--- per minute, so a refusal is retried on the next polls of the same battle (gym.MAX_ATTEMPTS).
function A:gym_snapshot(snap)
  if self.viewing or self.save_missing then return end
  local save = self.uz.save
  if type(save) ~= "table" or type(save.snapshot) ~= "function" then
    self.save_missing = true
    return
  end
  local n = gym.gym_number(snap.battle, self.st and self.st.badges, oras.level_cap)
  if not n then
    self.gym_tries = nil
    return
  end
  self.gym_done = self.gym_done or {}
  if self.gym_done[n] then return end
  self.gym_tries = self.gym_tries or {}
  if (self.gym_tries[n] or 0) >= gym.MAX_ATTEMPTS then return end
  self.gym_tries[n] = (self.gym_tries[n] or 0) + 1
  local ok, res, why = pcall(save.snapshot, self.tr("snapshot_gym", { n = n }))
  if ok and res == true then
    self.gym_done[n] = true
    self.uz.log.info("save snapshot before gym " .. n)
  else
    warn_once(self, "snapshot", "save snapshot refused: " .. tostring(ok and why or res))
  end
end

--- Adopt a new own state, publish it when it changed and post the facts as automatic events.
function A:commit(st, facts)
  state.guard(st)
  self.st = st
  local enc = util.encode(st)
  if enc ~= self.last_enc then
    if self:writable() then
      local ok, why = self.uz.run.setState(st)
      if ok then self.last_enc = enc else warn_once(self, "setState", "setState refused: " .. tostring(why)) end
    end
    self.dirty = true
  end
  for _, f in ipairs(facts or {}) do self:post_fact(f) end
  if facts and #facts > 0 then self.dirty = true end
end

function A:player_name(id)
  for _, p in ipairs(self.run.participants or {}) do
    if p.user_id == id then return p.name or p.user_name or id end
  end
  return tostring(id)
end

--- Context for labels outside a render (names from the view or the own state, live area names).
function A:label_ctx()
  local view = self.view or { names = (self.st and self.st.names) or { sp = {}, loc = {} } }
  return { tr = self.tr, view = view, area_name = function(id) return self:area_name(id) end }
end

function A:place_text(route)
  return route and common.route_label(self:label_ctx(), route) or self.tr("place_none")
end

function A:fact_text(f, user)
  local tr = self.tr
  local player = self:player_name(user or self.me)
  local sname = f.species and self:species_text(f.species, f.species_name) or nil
  local mon = common.mon_name({ nickname = f.nickname, species = f.species, species_name = sname })
  local text
  if f.kind == "catch" then
    text = f.route and tr("ev_catch", { player = player, mon = mon, place = self:place_text(f.route) })
      or tr("ev_catch_noplace", { player = player, mon = mon })
  elseif f.kind == "death" then
    text = tr("ev_death", { player = player, mon = mon })
  elseif f.kind == "encounter" then
    local m = common.species_label({ species = f.species, species_name = sname })
    text = f.route and tr("ev_encounter", { player = player, mon = m, place = self:place_text(f.route) })
      or tr("ev_encounter_noplace", { player = player, mon = m })
  elseif f.kind == "missed" then
    text = f.route and tr("ev_missed", { player = player, place = self:place_text(f.route) })
      or tr("ev_missed_noplace", { player = player })
  elseif f.kind == "badge" then
    text = tr("ev_badge", { player = player, n = f.index })
  elseif f.kind == "place" then
    text = tr("ev_place", { player = player, place = f.key and self:place_text(f.key) or (f.name or tr("place_none")) })
  end
  if text and f.why then text = text .. " " .. tr("ev_why_" .. f.why) end
  return text and util.clean_text(text, 280) or nil
end

--- Text of an automatic event worded again from its payload (ids), with the names known now.
function A:event_text(ev)
  if ev.source ~= "automatic" or type(ev.payload) ~= "table" then return nil end
  local p, ty = ev.payload, ev.type
  local f
  if ty == events.TYPES.catch then
    f = { kind = "catch", route = p.route, species = p.species, species_name = p.species_name,
          nickname = p.nickname, why = p.why }
  elseif ty == events.TYPES.death then
    f = { kind = "death", species = p.species, species_name = p.species_name, nickname = p.nickname }
  elseif ty == events.TYPES.encounter then
    f = { kind = p.outcome == "missed" and "missed" or "encounter", route = p.route, species = p.species,
          species_name = p.species_name, why = p.outcome ~= "missed" and p.why or nil }
  elseif ty == events.TYPES.place then
    f = { kind = "place", key = p.route, name = p.name }
  elseif ty == events.TYPES.badge then
    f = { kind = "badge", index = p.index }
  end
  return f and self:fact_text(f, ev.user_id) or nil
end

--- True when the own participant already has a badge event for this badge number (restart, lost state).
function A:badge_posted(index)
  for _, ev in ipairs(self.events) do
    if ev.type == events.TYPES.badge and ev.user_id == self.me and type(ev.payload) == "table"
        and ev.payload.index == index then
      return true
    end
  end
  return false
end

--- True when the newest place event of the own participant already records this place (same route key,
--- else same name), so a restart with lost or fresh state does not log the unchanged location again.
function A:place_posted(f)
  for i = #self.events, 1, -1 do
    local ev = self.events[i]
    if ev.type == events.TYPES.place and ev.user_id == self.me and type(ev.payload) == "table" then
      local p = ev.payload
      if f.key ~= nil then return p.route == f.key end
      return p.route == nil and p.name ~= nil and p.name == f.name
    end
  end
  return false
end

function A:post_fact(f)
  local spec = events.from_fact(f, self.me)
  if not spec or not self:writable() then return end
  if f.kind == "badge" and self:badge_posted(f.index) then return end
  if f.kind == "place" and not f.manual and self:place_posted(f) then return end
  spec.text = self:fact_text(f)
  local ok, err = pcall(self.uz.run.event, spec)
  if not ok then warn_once(self, "event", "event refused: " .. tostring(err)) end
  if f.kind == "place" and f.key and not f.manual then self:note_place(f.key) end
end

-- ---------------------------------------------------------------- events and notices

function A:on_event(ev)
  if type(ev) ~= "table" or self.seen[ev.seq] then return end
  self.seen[ev.seq] = true
  local n = #self.events
  self.events[n + 1] = ev
  if n > 0 and self.events[n].seq > ev.seq then
    table.sort(self.events, function(a, b) return a.seq < b.seq end)
  end
  self.dirty = true
  if not self.live then return end
  local p = type(ev.payload) == "table" and ev.payload or {}
  if ev.type == events.TYPES.death then
    self.queue[#self.queue + 1] = { ev = ev, tries = 0 }
  elseif ev.type == events.TYPES.catch and ev.user_id ~= self.me and p.counts then
    local who = { player = self:player_name(ev.user_id), mon = common.mon_name({ nickname = p.nickname, species = p.species,
      species_name = self:species_text(p.species, p.species_name) }) }
    if p.route then who.place = self:place_text(p.route) end
    self:notify({ tone = "info", text = self.tr(p.route and "note_catch" or "note_catch_noplace", who) })
  end
end

function A:notify(n)
  n.title = n.title or self.tr("note_title")
  local ok, id = pcall(self.uz.ui.notify, n)
  if not ok then warn_once(self, "notify", "notify failed: " .. tostring(id)) end
  return ok and id or nil
end

function A:note_place(route)
  local row = self.view and common.row_of(self.view, route)
  local cell = row and row.cells[self.me]
  if cell and cell.state ~= "open" then return end
  self:notify({ tone = "info", text = self.tr("note_new_place", { place = self:place_text(route) }) })
end

-- Deaths in the own link groups: toast (important) and HUD expansion.
function A:process_queue(view)
  local keep = {}
  local groups = common.groups(view)
  for _, q in ipairs(self.queue) do
    local ev, p = q.ev, q.ev.payload or {}
    local owner = common.player(view, ev.user_id)
    local mon = owner and owner.mons[p.mon]
    local g = mon and mon.group and groups[mon.group]
    local handled = false
    if g and g.state == "dead" then
      local mine
      for _, m in ipairs(g.members) do if m.owner == self.me then mine = m end end
      if mine then
        local partners = math.max(g.count - 1, 0)
        local text
        if ev.user_id == self.me then
          text = self.tr("note_death_own", { mon = common.mon_name(mon), n = partners })
        else
          text = self.tr("note_death_linked", { player = owner.name, mon = common.mon_name(mon), mine = common.mon_name(mine) })
        end
        self:notify({ tone = "important", text = text, actions = {
          { label = self.tr("open_run"), action = "open_run" },
          { label = self.tr("undo_death"), action = "undo_open", value = g.route },
        } })
        self.hud_until = self.uz.clock() + A.HUD_MS
        self.hud_text = self.tr("hud_death", { n = g.number or 0, mon = common.mon_name(mon), count = partners })
      end
      handled = true
    elseif q.tries >= A.NOTICE_TRIES or (mon and not mon.group) then
      handled = true
    end
    if not handled then
      q.tries = q.tries + 1
      keep[#keep + 1] = q
      self.dirty = true
    end
  end
  self.queue = keep
end

-- ---------------------------------------------------------------- rendering

function A:states()
  local states = self.uz.run.states()
  if not self.viewing and self.me and states[self.me] == nil and self.st then states[self.me] = self.st end
  return states
end

--- True when pokemon.core serves demo data (info().demo); asked until the core answers, then remembered.
function A:core_demo()
  if self.demo_known then return self.demo_flag end
  local ok, info = pcall(self.uz.call, "pokemon.core", "info")
  if ok and type(info) == "table" then
    self.demo_known, self.demo_flag = true, info.demo == true
    return self.demo_flag
  end
  return false
end

function A:ctx(view)
  return { demo = self:core_demo(), view = view, run = self.run, me = self.me, ui = self.ui, tr = self.tr, readonly = not self:writable(),
           events = self.events, hud_death = self.hud_until and self.hud_text or nil,
           map = self.maps and self.maps:view() or nil, diag = self.diag, icheck = self.icheck,
           can_open = type(self.uz.ui.open) == "function", location_ok = self.location_ok == true,
           badges_manual = not self.badges_seen,
           area_name = function(id) return self:area_name(id) end,
           event_text = function(ev) return self:event_text(ev) end,
           icon = self.icons and function(species, form) return self.icons:src(species, form) end or nil }
end

function A:render()
  local uz = self.uz
  self.dirty = false
  local now = uz.clock()
  self.last_render = now
  self.run = uz.run.current()
  local cfg = rules.parse(self.run)
  local view = view_mod.view(self.run, self:states(), self.events, cfg)
  self.view = view
  self:process_queue(view)
  local ctx = self:ctx(view)
  if self.viewing then
    -- read-only run section of the Runs screen: the run screen without correction forms or actions
    self.sync:push("run", screen.build(ctx))
    return
  end
  self.sync:push("panel", panel.build(ctx))
  self.sync:push("hud", hud.build(ctx))
  self.sync:push("screen", screen.build(ctx))

  local matched = tile.match(self.tiles, view)
  local live = {}
  for id, p in pairs(matched) do
    local slot = "tile:" .. id
    live[slot] = true
    self.sync:push(slot, tile.build(self.tr, p, view))
  end
  for slot in pairs(self.tile_slots) do
    if not live[slot] then self.sync:clear(slot) end
  end
  self.tile_slots = live

  if self:writable() then
    local tree = board.build(ctx)
    local enc = util.encode(tree)
    if enc == self.last_board_enc then
      self.board_due = false
    elseif now - self.last_board >= A.BOARD_MS then
      self.board_due = false
      self.last_board = now
      if uz.run.setBoard(tree) then self.last_board_enc = enc end
    else
      self.board_due = true
    end
  end
end

-- ---------------------------------------------------------------- corrections

function A:correction_text(spec)
  local p, tr = spec.payload, self.tr
  local mon
  local owner = self.view and p.user and common.player(self.view, p.user)
  if owner and p.mon and owner.mons[p.mon] then mon = common.mon_name(owner.mons[p.mon]) end
  if p.kind == "add" then mon = common.mon_name({ nickname = p.nickname, species = p.species }) end
  return util.clean_text(tr("ev_c_" .. p.kind, {
    player = self:player_name(self.me), target = p.user and self:player_name(p.user) or "",
    route = p.route and self:place_text(p.route) or (p.group and p.group ~= "none" and self:place_text(p.group)) or "",
    mon = mon or "?", seq = p.target or "", reason = p.reason or "",
  }), 280)
end

--- Post a manual correction event. Returns true when it was accepted.
function A:post_correction(spec)
  if not self:writable() then return false end
  local ok_valid = corrections.validate_spec(spec)
  if not ok_valid then return false end
  spec.text = self:correction_text(spec)
  local ok, id = pcall(self.uz.run.event, spec)
  if not ok or id == nil then return false end
  self.dirty = true
  return true
end

local function my_player(self) return self.view and common.player(self.view, self.me) end

function A:open_corr(corr)
  corr.user = corr.user or self.me
  self.ui.corr = corr
  self.dirty = true
end

local function field_value(field, value)
  if field == "species" or field == "level" then
    local n = tonumber(value)
    return n and math.tointeger(n) or nil
  elseif field == "gift" then
    return value == true
  end
  if type(value) == "string" then return util.clean_text(value, 280) or "" end
  return value
end

--- May the own state record a mapping for `zone`? Not when the static table has it or another
--- player's mapping is in use; the own mapping can be changed; the number is limited.
function A:can_learn(zone)
  if oras.ZONES[zone] ~= nil then return false end
  local own = self.st.zones and self.st.zones[tostring(zone)]
  if own ~= nil then return true end
  if view_mod.merge_zones(self.run, self:states())[zone] ~= nil then return false end
  local n = 0
  for _ in pairs(self.st.zones or {}) do n = n + 1 end
  return n < A.MAX_ZONES
end

function A:learn_zone(st, zone, value)
  if zone and self:can_learn(zone) then
    st.zones = st.zones or {}
    st.zones[tostring(zone)] = value
  end
end

function A:set_place(input)
  if not self:writable() then return end
  local st, fact = detect.set_place(self.st, input, nil, self.cur_zone, self.cur_loc)
  local key = st.place.key
  local id = key and oras.area_id(key)
  if id then state.note_name(st, "loc", id, self:game_name("location", id)) end
  -- fallback without a location id: the answer for a reported zone is remembered and shared
  if key and key ~= oras.STARTER and not (self.cur_loc and self.areas_info) then
    self:learn_zone(st, self.cur_zone, key)
  end
  self:commit(st, { fact })
end

-- ---------------------------------------------------------------- map setup and calibration

function A:calib_route(route)
  local c = self.ui.calib
  if not c or not oras.is_route(route) then return end
  local m = self.maps
  c.route, c.msg = route, nil
  local at = m:merged()[route]
  c.x, c.y = at and at.x or (m.w or 0) // 2, at and at.y or (m.h or 0) // 2
end

function A:map_action(action, value)
  local m, c = self.maps, self.ui.calib
  if not m then return end
  if action == "map_capture" then
    m:capture()
  elseif action == "map_remove" then
    m:remove()
    self.ui.calib = nil
  elseif action == "crop_toggle" then
    self.ui.crop_open = not self.ui.crop_open
    if self.ui.crop_open and not m.pending then m:preset(m.crop and "applied" or "none") end
  elseif action == "map_src:screen" or action == "map_src:files" then
    self.ui.map_src = action:sub(9) -- chips carry the value in the action name
  elseif action == "map_prev" or action == "map_next" then
    m:files_nav(action == "map_next" and 1 or -1, self.uz.clock())
  elseif action == "map_use" then
    if m:files_use() then
      self.ui.calib = nil
      self.ui.map_src = nil
    end
  elseif action == "crop_adj" then
    local side, d = tostring(value):match("^([tblr]):(-?%d+)$")
    if side then m:adjust(side, math.tointeger(tonumber(d))) end
  elseif action == "crop_preset" then
    m:preset(value)
  elseif action == "calib_toggle" then
    self.ui.calib = (not c and m.state == "ready") and { step = 10 } or nil
    m.order = self.view and self.view.order or nil
    if self.ui.calib then
      -- preselect the current place of this player (when it can carry a position)
      local me = self.view and self.me and common.player(self.view, self.me)
      local key = me and common.place_value(me.place)
      if key and oras.is_route(key) then self:calib_route(key) end
    end
  elseif c and action == "calib_route" then
    self:calib_route(value)
  elseif c and action == "calib_group" then
    local groups = common.place_groups(self:ctx(self.view), c.route)
    local g = math.type(value) == "integer" and groups[value]
    if g then
      c.group = value
      if g.opts[1] then self:calib_route(g.opts[1].value) end
    end
  elseif c and action == "calib_step" then
    if A.CAL_STEPS[value] then c.step = value end
  elseif c and action == "calib_move" and c.x then
    local d, n = ({ l = { -1, 0 }, r = { 1, 0 }, u = { 0, -1 }, d = { 0, 1 } })[value], c.step or 10
    if d then
      c.x = math.max(0, math.min(m.w, c.x + d[1] * n))
      c.y = math.max(0, math.min(m.h, c.y + d[2] * n))
      c.msg = nil
    end
  elseif c and action == "calib_set" and c.route and c.x then
    c.msg = m:set_coord(c.route, c.x, c.y) and "saved" or "failed"
  elseif c and action == "calib_export" then
    m.order = self.view and self.view.order or nil
    c.msg = m:export_line() and "exported" or "none"
  end
  self.dirty = true
end

-- ---------------------------------------------------------------- actions

--- Open the run screen (screen slot) over the game: uz.ui.open("screen"), only when the platform has it.
--- Without it the panel says so (ctx.can_open).
function A:open_screen()
  if self.viewing or type(self.uz.ui.open) ~= "function" then return false end
  local ok, err = pcall(self.uz.ui.open, "screen")
  if not ok then warn_once(self, "open", "ui.open failed: " .. tostring(err)) end
  return ok
end

function A:on_action(action, value, slot)
  if slot == "hotkey" then
    if action == "toggle-hud" then return end -- the host shows or hides the widget
    if action == "open-run" then action = "open_run"
    elseif action == "doesnt-count" then action, value = "dc_open", nil
    else return end
  end
  if not self.run then return end
  local me = my_player(self)
  local writable = self:writable()

  if action == "open_run" then
    self.ui.screen_tab_id = nil -- the screen opens on its first tab
    self.dirty = true
    self:open_screen()
  elseif action == "place_toggle" then self.ui.place_open = not self.ui.place_open; self.dirty = true
  elseif action == "diag_toggle" then self.ui.diag_open = not common.diag_open(self.ui); self.diag_next = nil; self.dirty = true
  elseif action == "rules_toggle" then self.ui.rules_open = not self.ui.rules_open; self.dirty = true
  elseif action == "grave_toggle" then self.ui.grave_open = not self.ui.grave_open; self.dirty = true
  elseif action == "hud_toggle" then self.ui.hud_expanded = not self.ui.hud_expanded; self.dirty = true
  elseif action == "tab" then
    if math.type(value) == "integer" and self.view then
      local ids = screen.tab_ids(self:ctx(self.view))
      self.ui.screen_tab_id = ids[value]
      self.dirty = true
    end
  elseif action:sub(1, 3) == "rf:" then self.ui.routes_filter = action:sub(4); self.dirty = true
  elseif action:sub(1, 3) == "lf:" then self.ui.log_filter = action:sub(4); self.dirty = true
  elseif action == "log_person" then
    self.ui.log_person = (type(value) == "string" and value ~= "all") and value or nil
    self.dirty = true
  elseif action == "route_select" then self.ui.selected_route = value; self.dirty = true
  elseif action == "map_select" then
    if type(value) == "table" then
      if value.kind == "route" then
        self.ui.selected_route = value.id
        if self.ui.calib and oras.is_route(value.id) then self:calib_route(value.id) end
      elseif value.kind == "filter" then self.ui.map_filter = value.value end
      self.dirty = true
    end
  elseif action:sub(1, 6) == "calib_" or action:sub(1, 4) == "map_" or action:sub(1, 5) == "crop_" then
    self:map_action(action, value)
  elseif not writable then
    return
  elseif action == "zone_none" then
    if self.cur_zone then
      local st = util.copy(self.st)
      self:learn_zone(st, self.cur_zone, false)
      self:commit(st, {})
    end
  elseif action == "place_select" then
    if type(value) == "string" then self:set_place(value) end
  elseif action == "place_text" then
    self:set_place(type(value) == "string" and value or "")
  elseif action == "badges_select" then
    if math.type(value) == "integer" and value >= 0 and value <= 8 then
      local st = util.copy(self.st)
      st.badges = value
      self:commit(st, {})
    end
  elseif action == "mark_dead" then
    if type(value) == "string" then
      self:post_correction(corrections.mark_dead({ user = self.me, mon = value }))
    end
  elseif action == "dc_open" then
    local route = value or (me and me.place.key)
    if route then
      local corr = { kind = "doesnt_count", route = route, reason = "wrong" }
      local row = common.row_of(self.view, route)
      local cell = row and row.cells[self.me]
      if cell and cell.mon then corr.mon = cell.mon end
      self:open_corr(corr)
    end
  elseif action == "missed_open" then
    if type(value) == "string" then self:open_corr({ kind = "mark_missed", route = value }) end
  elseif action == "undo_open" then
    local g = type(value) == "string" and common.groups(self.view)[value]
    if g then
      self:open_corr({ kind = "undo_death", group = g.route, number = g.number, members = g.members,
        undone = corrections.undo_entries(g) })
    end
  elseif action == "group_open" then
    local m = me and me.mons[value]
    if m then self:open_corr({ kind = "set_group", mon = m.id, group = m.group or "none" }) end
  elseif action == "gift_open" then
    if me and me.mons[value] then self:open_corr({ kind = "set_gift", mon = value, gift = true }) end
  elseif action == "dead_open" then
    if me and me.mons[value] then self:open_corr({ kind = "mark_dead", mon = value }) end
  elseif action == "add_open" then
    self:open_corr({ kind = "add", route = me and me.place.key and oras.is_key(me.place.key) and me.place.key or oras.STARTER,
      state = "box" })
  elseif action == "revert_open" then
    if math.type(value) == "integer" then self:open_corr({ kind = "revert", target = value }) end
  elseif action:sub(1, 3) == "cf:" then
    local corr = self.ui.corr
    if corr then
      local field = action:sub(4)
      corr[field] = field_value(field, value)
      corr.error = nil
      self.dirty = true
    end
  elseif action == "corr_cancel" then
    self.ui.corr = nil; self.dirty = true
  elseif action == "corr_submit" then
    local corr = self.ui.corr
    if corr then
      local spec, err = corr_ui.to_spec(corr)
      if not spec then
        corr.error = err
      elseif self:post_correction(spec) then
        self.ui.corr = nil
      else
        corr.error = "c_err_post"
      end
      self.dirty = true
    end
  end
end

return A
