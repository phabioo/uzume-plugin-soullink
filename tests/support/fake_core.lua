-- Fake `pokemon.core` implementing the v0.3 contract plus locations() of v0.3.1 and diagnostics() of v0.3.2 and icon_variants() of v0.3.4 (synthetic data only; names are made up by code).
--   local core = fake_core.new()            core.provider = table for mock.set_provider("pokemon.core", ...)
--   core.world: team, box (flat list of box 1), location, badges, battle, areas, species types ...
--   core.world.locations: list of { id, name, zones, has_encounters } (v0.3.1); core:off("locations", "not_ready")
--   core:off("areas", "unsupported")        makes a function answer nil, "unsupported" | "not_ready"
--   core:encounter{ species=, location=, shiny=, horde= }   appends an entry to encounters() with the next seq
local B = require("build")

local F = {}

--- Default world: two team mons, empty box, three encounter areas (ids 301..303) and a town (id 400).
function F.new(over)
  local w = {
    team = { B.rec({ p = 0xB1, sp = 900, hp = 30, nick = "Alpha" }), B.rec({ p = 0xB2, sp = 901, hp = 30, nick = "Beta" }) },
    box = {},
    location = { zone = 10, location = 301, name = "Synthetic Area One", source = "memory" },
    badges = { count = 0, flags = { false, false, false, false, false, false, false, false } },
    areas = {
      { id = 301, name = "Synthetic Area One", zones = { 10 }, encounters = { grass = { { species = 910, form = 0, min = 2, max = 4 } } } },
      { id = 302, name = "Synthetic Area Two", zones = { 11 }, encounters = { surf = { { species = 911, form = 0, min = 5, max = 8 } } } },
      { id = 303, name = "Synthetic Area Three", zones = { 12 }, encounters = { horde = { { species = 912, form = 0, min = 3, max = 3 } } } },
    },
    -- v0.3.1 locations(): every location in game order, towns and caves included
    locations = {
      { id = 400, name = "Synthetic Town", zones = { 13 }, has_encounters = false },
      { id = 301, name = "Synthetic Area One", zones = { 10 }, has_encounters = true },
      { id = 401, name = "Synthetic Cave", zones = { 14 }, has_encounters = false },
      { id = 302, name = "Synthetic Area Two", zones = { 11 }, has_encounters = true },
      { id = 303, name = "Synthetic Area Three", zones = { 12 }, has_encounters = true },
    },
    zone_info = { [13] = { zone = 13, location = 400, name = "Synthetic Town" } },
    -- v0.3.2 diagnostics(): flat table of numbers/strings; core:off("diagnostics", "unsupported") = older core
    diag = { zones_state = "ready", zone_files = 3, zo_packs = 2, zones_with_encounters = 40, areas = 3, locations = 5,
             ids_assigned = 5, first_rejection = "none", text_state = "ready", lines_location = 5, revision = 7, language = "en" },
    battle = { active = false },
    encounters = {},
    types = {},            -- species -> { t1, t2 }
    off = {},              -- function name -> reason
    calls = {},
  }
  for k, v in pairs(over or {}) do w[k] = v end
  local self = { world = w }

  local function guard(fn, f)
    return function(...)
      w.calls[fn] = (w.calls[fn] or 0) + 1
      if w.off[fn] then return nil, w.off[fn] end
      return f(...)
    end
  end
  local p = {}
  p.team = guard("team", function() return w.team end)
  p.box_count = guard("box_count", function() return 1 end)
  p.box = guard("box", function() return w.box end)
  p.location = guard("location", function() return w.location end)
  p.badges = guard("badges", function() return w.badges end)
  p.areas = guard("areas", function() return w.areas end)
  p.locations = guard("locations", function() return w.locations end)
  p.diagnostics = guard("diagnostics", function() return w.diag end)
  -- v0.6.4 balls(): { count = n }; world.balls overrides. Older cores: `core.provider.balls = nil`.
  p.balls = guard("balls", function() return w.balls or { count = 0 } end)
  p.battle = guard("battle", function() return w.battle end)
  p.encounters = guard("encounters", function() return w.encounters end)
  p.zone_info = guard("zone_info", function(z) return w.zone_info[z] end)
  p.trainer = guard("trainer", function() return { name = "Synth", tid = 1, sid = 2, version = "x", language = "en", money = 0, badges = 0, play_time = { h = 0, m = 0, s = 0 } } end)
  p.species_info = guard("species_info", function(sp)
    local t = w.types[sp]
    if not t then return nil, "not_ready" end
    return { types = { t[1], t[2] or t[1] }, growth = 0 }
  end)
  p.name = guard("name", function(kind, id)
    if kind == "species" then return "Synthetic Species " .. id end
    if kind == "location" then
      for _, a in ipairs(w.areas) do if a.id == id then return a.name end end
      for _, l in ipairs(w.locations) do if l.id == id then return l.name end end
      return "Synthetic Place " .. id
    end
    return nil, "unsupported"
  end)
  -- map_candidates() / map_image(id) / map_selected(): only when world.maps is given (older cores have none).
  -- maps = { scan = n (calls answered "not_ready" first), list = { {id, w, h}, ... }, images = { [id] = png string },
  --          selected = id | nil }
  if w.maps then
    local m = w.maps
    p.map_candidates = guard("map_candidates", function()
      if (m.scan or 0) > 0 then m.scan = m.scan - 1; return nil, "not_ready" end
      return m.list
    end)
    p.map_image = guard("map_image", function(id)
      if m.images[id] then return m.images[id] end
      return nil, "unknown_map"
    end)
    p.map_selected = guard("map_selected", function() return m.selected end)
  end
  -- v0.3.4 icon_variants(species, form?): up to 4 { label = "A".."D", desc, png }. world.variants = { count = n (default 4),
  -- scan = n (answers "not_ready" first) }; core:off("icon_variants", "unsupported") = older core.
  w.variants = w.variants or {}
  p.icon_variants = guard("icon_variants", function(species, form)
    local v = w.variants
    if (v.scan or 0) > 0 then v.scan = v.scan - 1; return nil, "not_ready" end
    local out = {}
    for i = 1, v.count or 4 do
      local label = string.char(64 + i)
      out[i] = { label = label, desc = "Synthetic variant " .. label .. " of " .. tostring(species), png = "PNG-" .. label .. "-" .. tostring(species) .. "-" .. tostring(form or 0) }
    end
    return out
  end)
  p.info = guard("info", function() return { features = { names = true, areas = true, locations = true } } end)
  self.provider = p

  function self:off(fn, reason) w.off[fn] = reason end
  function self:on(fn) w.off[fn] = nil end
  --- Append a wild encounter (oldest first, at most 64 kept) with the next seq.
  function self:encounter(o)
    w.next_seq = (w.next_seq or 0) + 1
    w.encounters[#w.encounters + 1] = { seq = w.next_seq, species = o.species or 910, form = 0, level = o.level or 3,
      shiny = o.shiny or false, horde = o.horde or false, zone = o.zone or w.location.zone,
      location = o.location or w.location.location, frame = w.next_seq * 100 }
    while #w.encounters > 64 do table.remove(w.encounters, 1) end
  end
  --- Move to an area (by id) or a town.
  function self:go(location, name, zone)
    w.location = { zone = zone or location, location = location, name = name or ("Synthetic Place " .. location), source = "memory" }
  end
  function self:battle_start(o)
    o = o or {}
    w.battle = { active = true, kind = o.kind or "wild", horde = o.horde or false,
      foes = { B.rec({ p = 0xF00D, sp = o.species or 910, hp = 10 }) }, own = o.own or {} }
  end
  function self:battle_end() w.battle = { active = false } end
  return self
end

return F
