-- Detection: diff(previous own state, core snapshot, cfg) -> new own state + facts.
-- Pure; never touches uz. Everything the core cannot report (place, battle, hp, encounters)
-- degrades to "unknown": nothing is invented, the UI/user supplies it through manual input.
local util = require("model.util")
local rules = require("model.rules")
local state = require("model.state")
local oras = require("data.oras")

local D = {}

-- Snapshot (what the caller passes; model/snapshot.lua builds it from pokemon.core):
--   team     list of generic records, or nil = unknown
--   boxes    list of boxes (each a list of records) or a flat list of records, or nil = unknown
--   location { zone = number?, location = number? (location name id), name = string? }   or nil
--   battle   { active = bool, wild = bool, horde = bool?, foes = {records}, own = {records}? }  or nil
--   encounters pokemon.core v0.3: list (oldest first) of { seq, species, form?, shiny?, horde?, location? };
--              entries with seq > state.enc_seq are new. Without seq (older shape): all entries are new.
--   badges   number | { count = n } | list of booleans
-- Facts (kind): place, catch, evolve, death, moved, encounter, missed. See docs/architecture.md.

local function default_family(species) return species end

local function collect(snap)
  local list, map = {}, {}
  local team_known = type(snap.team) == "table"
  local boxes_known = type(snap.boxes) == "table"
  local function add(rec, where)
    if type(rec) ~= "table" or type(rec.species) ~= "number" then return end
    local pid = util.hex8(rec.personality)
    if not pid or map[pid] then return end
    local c = { pid = pid, rec = rec, where = where }
    map[pid] = c
    list[#list + 1] = c
  end
  if team_known then for _, rec in ipairs(snap.team) do add(rec, "team") end end
  if boxes_known then
    for _, box in ipairs(snap.boxes) do
      if type(box) == "table" and box.personality ~= nil then
        add(box, "box")
      elseif type(box) == "table" then
        for _, rec in ipairs(box) do add(rec, "box") end
      end
    end
  end
  return list, map, team_known, boxes_known
end

local function badge_count(b)
  if math.type(b) == "integer" then return b end
  if type(b) ~= "table" then return nil end
  if math.type(b.count) == "integer" then return b.count end
  local n = 0
  for _, v in ipairs(b) do if v == true then n = n + 1 end end
  return n
end

local function battle_info(snap)
  local b = snap.battle
  if type(b) ~= "table" or type(b.active) ~= "boolean" then return { known = false } end
  -- b.own (hp of the own battlers) is deliberately not used: it can be stale while a battle ends
  -- and caused premature deaths; a death needs the party record itself (see the death rule in diff).
  return { known = true, active = b.active, wild = b.wild == true, horde = b.horde == true,
           foes = type(b.foes) == "table" and b.foes or (type(b.foe) == "table" and { b.foe } or {}) }
end

-- Is a line (family) already owned by a tracked mon that counts for the dupes clause?
local function owns_line(st, species, family, opts)
  if species == nil then return false end
  local fam = family(species)
  local excluded = opts and opts.excluded or {}
  for pid, m in pairs(st.mons) do
    if not excluded[pid] and m.why ~= "dupe" and m.why ~= "extra" and m.where ~= "gone" and family(m.species) == fam then
      return true
    end
  end
  return false
end

local function zone_id(z)
  if math.type(z) == "float" and z == math.floor(z) then z = math.tointeger(z) end
  if math.type(z) == "integer" then return z end
  return nil
end

-- Display name of a species: the record's own text, else the name already stored in the state, else
-- the resolver; remembered in the state.
local function note_species(st, opts, species, hint)
  if math.type(species) ~= "integer" then return hint end
  local name = (type(hint) == "string" and hint ~= "") and hint or nil
  if not name then
    local known = st.names and st.names.sp and st.names.sp[tostring(species)]
    if known then return known end
    if opts.names and opts.names.species then name = opts.names.species(species) end
  end
  if name then state.note_name(st, "sp", species, name) end
  return name
end

-- Identity of a place for change detection: the route key, else the location id, else the name.
local function place_identity(p)
  if p.key then return p.key end
  if p.loc ~= nil then return "loc:" .. p.loc end
  return p.name
end

--- Place from the reported location. With a location name id (pokemon-core v0.3) and the encounter
--- areas, the place is the area `loc:<id>`; a location without encounter slots (town) has no key
--- ("no encounters here"). Without a location id the zone table decides (fallback; the UI asks for
--- unmapped zones). A manual place wins for as long as its anchor (location, else zone) stays the
--- same; when it changes, detection decides again.
local function update_place(st, loc, facts, opts)
  if type(loc) ~= "table" then return end
  local zone, lid = zone_id(loc.zone), zone_id(loc.location)
  local areas = opts.areas
  local by_area = lid ~= nil and areas ~= nil
  if lid ~= nil and areas == nil and not opts.areas_unsupported then return end -- areas still loading
  if not by_area then lid = nil end
  if not by_area and not zone then return end
  local old = st.place or { manual = false }
  if old.manual then
    local same
    if old.loc ~= nil then same = lid ~= nil and old.loc == lid
    else same = old.zone == nil or old.zone == zone end
    if same then
      old.zone = zone or old.zone
      if lid ~= nil then old.loc = lid end
      st.place = old
      return
    end
  end
  local new
  if by_area then
    local key = areas.set[lid] and oras.area_key(lid) or nil
    local name = (areas.names and areas.names[lid]) or loc.name or st.names.loc[tostring(lid)]
    new = { key = key, name = name, zone = zone, loc = lid, manual = false }
    if name then state.note_name(st, "loc", lid, name) end
  else
    local mapped = (opts.zones or oras.ZONES)[zone]
    if mapped ~= nil then
      new = { key = mapped or nil, name = loc.name, zone = zone, manual = false }
    else
      new = { name = loc.name, zone = zone, manual = false }
    end
    -- a zone nobody mapped and nobody named is stored (the UI asks which place this is) but never logged
  end
  -- a location without key and name (name text still loading) is transient too
  if by_area and new.key == nil and new.name == nil then return end
  local same = place_identity(new) == place_identity(old)
  if same and new.name == nil then new.name = old.name end
  if new.key ~= old.key or new.name ~= old.name or new.zone ~= old.zone or new.loc ~= old.loc or old.manual then
    st.place = new
    if not same and (new.key or new.name) then
      facts[#facts + 1] = { kind = "place", key = new.key, name = new.name, zone = new.zone, loc = new.loc,
                            manual = false, previous = old.key }
    end
  end
end

--- Set the place by hand. `input` is a route key ("route-104", "starter", "place:<text>") or free
--- text typed by the user (becomes "place:<text>"); nil/"" clears the place. `name` is optional
--- display text, `zone` / `loc` the zone and location id the player is in right now (nil when the
--- core reports none): the manual place wins until that anchor changes. Returns the new state and
--- a place fact (nil when nothing changed).
function D.set_place(prev, input, name, zone, loc)
  local st = state.ensure(util.copy(prev))
  local old = st.place or { manual = false }
  local key
  if input ~= nil and input ~= "" then
    key = oras.is_key(input) and input or oras.custom_key(input)
  end
  zone = zone_id(zone) or (old.manual and old.zone) or nil
  loc = zone_id(loc) or (old.manual and old.loc) or nil
  st.place = { key = key, name = name, zone = zone, loc = loc, manual = true }
  if key == old.key and name == old.name and old.manual then return st, nil end
  return st, { kind = "place", key = key, name = name, manual = true, previous = old.key }
end

-- Pairs-differ-primary-type clause: the creature's primary type is already taken by a partner's
-- creature on that route. Needs opts.types(species, form) and opts.partner_types(route).
local function type_clash(cfg, opts, route, species, form)
  if not cfg.rules.pairs_differ_primary_type or not route or not opts.types or not opts.partner_types then
    return false, nil
  end
  local ty = opts.types(species, form)
  if ty == nil then return false, nil end
  local taken = opts.partner_types(route)
  return type(taken) == "table" and taken[ty] == true, ty
end

-- The route a wild encounter belongs to: a manual place, else the area of the encounter's location
-- (core v0.3), else the current place.
local function encounter_route(st, e, opts)
  if st.place.manual and st.place.key then return st.place.key end
  local lid = zone_id(e.location)
  if lid ~= nil and opts.areas and opts.areas.set[lid] then return oras.area_key(lid) end
  return st.place.key
end

-- The route entry as detection sees it: the stored one, unless a correction newer than the entry
-- shadows it (opts.overrides, see corrections.route_overrides). Returns entry|nil and the override
-- seq (stamped as `rs` on entries created now, so the view and later polls treat them as valid).
local function live_entry(st, opts, key)
  local e = key and st.routes[key] or nil
  local ov = key and opts.overrides and opts.overrides[key] or nil
  if not ov then return e, nil end
  if e and (e.rs or 0) >= ov.seq then return e, ov.seq end -- created after the correction
  if ov.kind == "reopen" then return nil, ov.seq end
  if ov.kind == "missed" then
    local sp = e and e.status ~= "caught" and e.species or nil
    return { status = "missed", species = sp }, ov.seq
  end
  return { status = "caught", mon = ov.mon, kind = "gift" }, ov.seq -- taken: a hand-added mon
end

local function new_entry(e, rs)
  e.rs = rs
  return e
end

local function handle_encounter(st, cfg, pk, foe, horde, facts, family, opts)
  local fact = { kind = "encounter", route = pk, species = foe.species, form = foe.form,
                 shiny = foe.shiny == true, horde = horde, counts = false }
  fact.species_name = note_species(st, opts, foe.species, foe.species_name)
  local r = cfg.rules
  local existing, rs = live_entry(st, opts, pk)
  local clash = type_clash(cfg, opts, pk, foe.species, foe.form)
  if r.balls_required and not st.balls then
    fact.why = "no_balls" -- before the first Poke Ball: does not count, does not use up the route
  elseif horde and not r.hordes_count then
    fact.why = "horde"
  elseif pk == nil then
    fact.why = "no_place"
  elseif fact.shiny and r.shiny_clause then
    fact.why = "shiny"
  elseif r.dupes_clause and owns_line(st, foe.species, family, opts) then
    fact.why = "dupe"
  elseif clash then
    fact.why = "type"
  elseif existing and r.first_encounter_only then
    fact.why = "used"
  else
    fact.counts = true
    if not existing then
      st.routes[pk] = new_entry({ status = "encounter", species = foe.species, kind = horde and "horde" or "wild" }, rs)
    end
  end
  facts[#facts + 1] = fact
end

local function handle_catch(st, cfg, c, pk, starter, facts, family, opts)
  local rec, r = c.rec, cfg.rules
  if not starter and not rec.egg then st.balls = true end -- a catch implies a ball
  local dupe = r.dupes_clause and owns_line(st, rec.species, family, opts) -- before the mon is added
  local clash, ty = type_clash(cfg, opts, pk, rec.species, rec.form)
  local mon = {
    species = rec.species, form = rec.form, nickname = util.clean_text(rec.nickname, 24),
    level = rec.level, shiny = rec.shiny == true or nil, route = pk, where = c.where,
    hp = type(rec.hp) == "number" and rec.hp or nil,
    mhp = type(rec.max_hp) == "number" and rec.max_hp or nil, ty = ty,
  }
  if r.pairs_differ_primary_type and ty == nil and opts.types then mon.ty = opts.types(rec.species, rec.form) end
  if rec.nicknamed == false then mon.nicknamed = false end
  st.mons[c.pid] = mon
  local fact = { kind = "catch", mon = c.pid, species = rec.species, form = rec.form,
                 nickname = mon.nickname, level = rec.level, shiny = rec.shiny == true,
                 route = pk, where = c.where, counts = false, starter = starter or nil }
  fact.species_name = note_species(st, opts, rec.species, rec.species_name)
  local existing, rs = live_entry(st, opts, pk)
  if rec.egg then
    mon.gift, mon.why = true, "gift"
    fact.gift, fact.why = true, "gift"
  elseif pk == nil then
    fact.why = "no_place"
  elseif mon.shiny and r.shiny_clause then
    mon.why, fact.why = "shiny", "shiny"
  elseif dupe then
    mon.why, fact.why = "dupe", "dupe"
  elseif clash and not starter then
    mon.why, fact.why = "type", "type"
  else
    local entry = { status = "caught", mon = c.pid, species = rec.species,
                    kind = starter and "starter" or "wild" }
    if not existing or existing.status == "encounter" then
      st.routes[pk], fact.counts = new_entry(entry, rs), true
    elseif existing.status == "missed" and existing.species == rec.species then
      st.routes[pk], fact.counts = new_entry(entry, rs), true -- the catch arrived after the battle was closed
    elseif not r.first_encounter_only then
      mon.why, fact.why = "additional", "additional"
    else
      mon.why, fact.why = "extra", "extra"
    end
  end
  facts[#facts + 1] = fact
end

-- The route with the one pending encounter (a battle that has not ended in a catch or a miss), or nil.
local function pending_route(st, opts)
  local found
  for _, key in ipairs(util.keys(st.routes)) do
    local e = live_entry(st, opts, key)
    if e and e.status == "encounter" then
      if found then return nil end
      found = key
    end
  end
  return found
end

local function newest_seq(list)
  local max = 0
  for _, e in ipairs(list) do if e.seq > max then max = e.seq end end
  return max
end

D.PENDING_MS = 60000 -- how long an ended wild battle may stay undecided (caught or missed)

local function has_encounter(st, opts)
  for _, key in ipairs(util.keys(st.routes)) do
    local e = live_entry(st, opts, key)
    if e and e.status == "encounter" then return true end
  end
  return false
end

-- Close the pending encounter(s): routes still at "encounter" are missed.
local function expire_pending(st, facts, opts)
  st.pend = nil
  for _, key in ipairs(util.keys(st.routes)) do
    local e = live_entry(st, opts, key)
    if e and e.status == "encounter" then
      e = st.routes[key]
      e.status = "missed"
      facts[#facts + 1] = { kind = "missed", route = key, species = e.species }
    end
  end
end

-- Copy a list of ids into st[field] (limited); only when it changed.
local function sync_ids(st, field, src, max)
  if type(src) ~= "table" then return end
  local n = math.min(#src, max)
  local same = type(st[field]) == "table" and #st[field] == n
  if same then for i, id in ipairs(st[field]) do if src[i] ~= id then same = false; break end end end
  if not same then
    st[field] = {}
    for i = 1, n do st[field][i] = src[i] end
  end
end

--- diff(prev, snap, cfg, opts) -> new_state, facts
---   prev  own state (nil = fresh); never modified
---   snap  see the snapshot description above
---   cfg   result of rules.parse (or flat rule flags)
---   opts  { family = function(species) -> family id (default: species itself),
---           zones = zone -> route key table (fallback without a location id, default data.oras.ZONES),
---           areas = { set = { [location id] = true }, order = { location id, ... }, names = { [id] = name } }
---                   (pokemon-core areas(); nil while not ready),
---           areas_unsupported = bool (the core has no areas(): the zone table is the fallback),
---           names = { species = function(id) -> name|nil },   display names read from the game
---           types = function(species, form) -> primary type id|nil,
---           partner_types = function(route key) -> { [type id] = true } of the partners' creatures there,
---           first = "auto"|"baseline"|"starter" (what the first complete snapshot means),
---           balls = bool (pokemon-core balls() reported count > 0 right now; sets st.balls for good),
---           game = { id, language } }
--- Tracking starts with the first snapshot where team and boxes are both known: then either
--- everything present is baseline, or (first = "starter", or "auto" with exactly one mon in the
--- team and no box mon) that mon is the starter caught on route "starter".
function D.diff(prev, snap, cfg, opts)
  opts = opts or {}
  cfg = rules.normalize(cfg)
  local st = state.ensure(util.copy(prev))
  snap = type(snap) == "table" and snap or {}
  local facts = {}
  local family = opts.family or default_family
  if type(opts.game) == "table" then
    st.game.id = st.game.id or opts.game.id
    st.game.language = st.game.language or opts.game.language
  end
  if opts.areas then
    sync_ids(st, "areas", opts.areas.order, state.MAX_AREAS)
    sync_ids(st, "places", opts.areas.places, state.MAX_PLACES)
  end

  -- Poke Balls (rule balls_required): reported by the core (opts.balls), or implied by an earlier catch
  if opts.balls == true then st.balls = true end
  if not st.balls then
    for _, e in pairs(st.routes) do
      if e.status == "caught" and e.kind == "wild" then st.balls = true; break end
    end
  end

  local loc_now = type(snap.location) == "table" and snap.location or {}
  update_place(st, snap.location, facts, opts)
  local b = badge_count(snap.badges)
  if b then
    -- one badge fact per new badge once tracking runs (a first snapshot with badges owned is baseline)
    if st.started and b > st.badges then
      for i = st.badges + 1, math.min(b, 8) do facts[#facts + 1] = { kind = "badge", index = i, count = i } end
    end
    st.badges = b
  end

  local list, map, team_known, boxes_known = collect(snap)
  local bat = battle_info(snap)
  local catch_place
  local settled = not (bat.known and bat.active) and not st.inb -- no battle now, none ended just now
  local now = type(opts.now) == "number" and opts.now or nil

  -- encounters() with seq: only entries newer than the last handled one count
  local enc = {}
  local seq_mode = false
  if type(snap.encounters) == "table" then
    local first = snap.encounters[1]
    seq_mode = first == nil or (type(first) == "table" and math.type(first.seq) == "integer")
    if seq_mode then
      for _, e in ipairs(snap.encounters) do
        if type(e) == "table" and math.type(e.seq) == "integer" then enc[#enc + 1] = e end
      end
      table.sort(enc, function(x, y) return x.seq < y.seq end)
    end
  end

  if not st.started then
    if not (team_known and boxes_known) then return st, facts end
    local first = opts.first or "auto"
    local starter = first == "starter"
      or (first == "auto" and #list == 1 and list[1].where == "team" and not list[1].rec.egg)
    st.started = true
    if seq_mode then st.enc_seq = newest_seq(enc) end -- encounters before the tracking started are old
    if not starter then
      for _, c in ipairs(list) do st.baseline[c.pid] = true end
      st.inb = bat.known and bat.active or false
      return st, facts
    end
    catch_place = oras.STARTER
  end

  -- known mons: updates, moves, evolution, deaths, disappearance
  for _, pid in ipairs(util.keys(st.mons)) do
    local m, c = st.mons[pid], map[pid]
    if c then
      local rec = c.rec
      m.miss = nil
      if m.species ~= rec.species then
        facts[#facts + 1] = { kind = "evolve", mon = pid, from = m.species, to = rec.species,
                              nickname = m.nickname, route = m.route,
                              species_name = note_species(st, opts, rec.species, rec.species_name) }
        m.species = rec.species
        if m.ty ~= nil and opts.types then m.ty = opts.types(rec.species, rec.form) or m.ty end
      end
      m.form = rec.form
      note_species(st, opts, rec.species, rec.species_name) -- team rows show names, never "#id"
      m.level = rec.level or m.level
      m.nickname = util.clean_text(rec.nickname, 24) or m.nickname
      if rec.nicknamed == false then m.nicknamed = false elseif rec.nicknamed == true then m.nicknamed = nil end
      if rec.shiny == true then m.shiny = true end
      if m.where ~= c.where then
        facts[#facts + 1] = { kind = "moved", mon = pid, from = m.where, to = c.where }
        m.where = c.where
      end
      -- fainted: the party record itself shows hp 0 (with a plausible max hp) while no battle is running
      -- and none ended since the previous snapshot. The battle's own-battler data is never used (stale
      -- while a battle ends). While unsettled the last known hp stays, so the death is still counted.
      local team_hp = type(rec.hp) == "number" and rec.hp or nil
      if team_hp and team_hp <= 0 then
        local valid = rec.max_hp == nil or (type(rec.max_hp) == "number" and rec.max_hp > 0)
        if valid and settled then
          if m.hp and m.hp > 0 then
            m.deaths = (m.deaths or 0) + 1
            facts[#facts + 1] = { kind = "death", mon = pid, species = m.species, nickname = m.nickname,
                                  route = m.route, deaths = m.deaths,
                                  species_name = note_species(st, opts, m.species, rec.species_name) }
          end
          m.hp = 0
        end
      elseif team_hp then
        m.hp = team_hp
      end
      m.fz = nil
      if type(rec.max_hp) == "number" then m.mhp = rec.max_hp end
    elseif team_known and boxes_known and m.where ~= "gone" then
      m.miss = (m.miss or 0) + 1 -- gone only after two snapshots in a row (no transient states)
      if m.miss >= 2 then
        facts[#facts + 1] = { kind = "moved", mon = pid, from = m.where, to = "gone" }
        m.where, m.miss = "gone", nil
      end
    end
  end

  -- new mons: a catch lands on the pending encounter's route, else on the current place
  for _, c in ipairs(list) do
    if not st.baseline[c.pid] and not st.mons[c.pid] then
      handle_catch(st, cfg, c, catch_place or pending_route(st, opts) or st.place.key, catch_place ~= nil, facts, family, opts)
    end
  end

  -- team order (tracked mons only)
  if team_known then
    st.order = {}
    for _, c in ipairs(list) do
      if c.where == "team" and st.mons[c.pid] then st.order[#st.order + 1] = c.pid end
    end
  end

  -- encounters and missed routes
  if seq_mode then
    if st.enc_seq == nil then
      st.enc_seq = newest_seq(enc)
    else
      for _, e in ipairs(enc) do
        if e.seq > st.enc_seq then
          st.enc_seq = e.seq
          if st.pend then expire_pending(st, facts, opts) end
          handle_encounter(st, cfg, encounter_route(st, e, opts), e, e.horde == true, facts, family, opts)
        end
      end
    end
  end
  if bat.known then
    if not seq_mode and bat.active and not st.inb and bat.wild then
      if st.pend then expire_pending(st, facts, opts) end
      handle_encounter(st, cfg, st.place.key, bat.foes[1] or {}, bat.horde, facts, family, opts)
    elseif not bat.active and st.inb then
      -- the battle ended: caught, missed or fled is not known yet (the catch shows up in the party or
      -- the boxes only after the Pokedex page and the nickname dialog), so the encounter stays pending
      if has_encounter(st, opts) then
        st.pend = { since = now, zone = st.inb_zone, loc = st.inb_loc }
      end
    end
    if bat.active then
      st.inb_zone, st.inb_loc = zone_id(loc_now.zone) or st.inb_zone, zone_id(loc_now.location) or st.inb_loc
    else
      st.inb_zone, st.inb_loc = nil, nil
    end
    st.inb = bat.active
  elseif not seq_mode and type(snap.encounters) == "table" then
    for _, e in ipairs(snap.encounters) do
      if type(e) == "table" then
        handle_encounter(st, cfg, st.place.key, e, e.horde == true, facts, family, opts)
      end
    end
  end

  -- a pending encounter ends as caught (see above), or as missed when the player moved on, the next
  -- wild battle started or the timeout passed
  if st.pend then
    if not has_encounter(st, opts) then
      st.pend = nil
    else
      local p = st.pend
      local moved = (p.loc ~= nil and zone_id(loc_now.location) ~= nil and p.loc ~= zone_id(loc_now.location))
        or (p.zone ~= nil and p.loc == nil and zone_id(loc_now.zone) ~= nil and p.zone ~= zone_id(loc_now.zone))
      if p.since == nil and now then p.since = now end
      if moved or (now and p.since and now - p.since >= D.PENDING_MS) then expire_pending(st, facts, opts) end
    end
  end

  return st, facts
end

return D
