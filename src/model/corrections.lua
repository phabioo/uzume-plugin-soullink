-- Manual corrections: run events of type "soullink.correction" with source "manual".
-- Corrections are applied by model/view.lua in seq order on top of the own states; they never
-- rewrite the own state. Builders return a spec { type, source = "manual", payload }; the caller
-- adds `text` and posts it with uz.run.event.
--
-- payload.user is the player the correction is about (the author is the event's user_id).
local util = require("model.util")
local oras = require("data.oras")

local C = {}

C.TYPE = "soullink.correction"
C.MAX_PAYLOAD = 4096
C.KINDS = {
  "doesnt_count", "undo_death", "set_group", "add", "mark_missed", "mark_dead", "set_gift", "revert",
  "reopen",
}
C.REASONS = { dupe = true, shiny = true, wrong = true }
C.ADD_STATES = { team = true, box = true, dead = true }

local function spec(payload)
  return { type = C.TYPE, source = "manual", payload = payload }
end

--- "This encounter/catch doesn't count". `route` and/or `mon`; `reason` = dupe|shiny|wrong.
--- Without `mon`: reopens an encounter/missed route (or excludes the route's counted mon).
--- With `mon`: that mon stops counting and its route reopens.
function C.doesnt_count(a)
  return spec({ kind = "doesnt_count", user = a.user, route = a.route, mon = a.mon, reason = a.reason })
end

--- Undo the death of a whole link group. `group` = route key; `undone` = list of
--- { owner = user id, mon = mon id, deaths = death count that is undone } (use C.undo_entries).
function C.undo_death(a)
  return spec({ kind = "undo_death", group = a.group, reason = a.reason, undone = a.undone })
end

--- Build the `undone` list from a view group (member list as produced by view.view).
function C.undo_entries(group)
  local out = {}
  for _, m in ipairs(group.members or {}) do
    out[#out + 1] = { owner = m.owner, mon = m.id, deaths = m.deaths }
  end
  return out
end

--- Move a mon to the link group of `group` (route key) or to no group ("none").
function C.set_group(a)
  return spec({ kind = "set_group", user = a.user, mon = a.mon, group = a.group })
end

--- Hand-added mon. state = team|box|dead. Replaces "missed"/open on the route.
function C.add(a)
  return spec({ kind = "add", user = a.user, route = a.route, species = a.species, form = a.form,
                nickname = a.nickname, level = a.level, state = a.state or "box", shiny = a.shiny })
end

function C.mark_missed(a) return spec({ kind = "mark_missed", user = a.user, route = a.route }) end

--- Reopen a route that was closed as missed (typically automatically): its next encounter is the first again.
function C.reopen(a) return spec({ kind = "reopen", user = a.user, route = a.route }) end

function C.mark_dead(a) return spec({ kind = "mark_dead", user = a.user, mon = a.mon, reason = a.reason }) end

--- Mark (or unmark with gift = false) a mon as a gift: no link group.
function C.set_gift(a)
  local g = a.gift
  if g == nil then g = true end
  return spec({ kind = "set_gift", user = a.user, mon = a.mon, gift = g })
end

--- Revert the correction event with seq `target`.
function C.revert(a) return spec({ kind = "revert", target = a.target, reason = a.reason }) end

--- Effective corrections of a list of run events: valid ones only, in seq order, without the reverted
--- ones (a reverted revert cancels nothing). Returns the list `{ seq, author, p }` and the seqs of
--- invalid correction events.
function C.effective(events)
  local list = {}
  for _, ev in ipairs(events or {}) do
    if type(ev) == "table" and math.type(ev.seq) == "integer" and ev.type == C.TYPE then list[#list + 1] = ev end
  end
  table.sort(list, function(a, b) return a.seq < b.seq end)
  local corr, invalid = {}, {}
  for _, ev in ipairs(list) do
    local p = type(ev.payload) == "table" and ev.payload or {}
    if C.validate(p) then corr[#corr + 1] = { seq = ev.seq, author = ev.user_id, p = p }
    else invalid[#invalid + 1] = ev.seq end
  end
  local reverted = {}
  for i = #corr, 1, -1 do
    local c = corr[i]
    if c.p.kind == "revert" and not reverted[c.seq] and c.p.target < c.seq then reverted[c.p.target] = true end
  end
  local out = {}
  for _, c in ipairs(corr) do
    if c.p.kind ~= "revert" and not reverted[c.seq] then out[#out + 1] = c end
  end
  return out, invalid
end

--- Route overrides of one player: what the effective corrections (`C.effective`) do to the routes of
--- the player's own state `st`. Used by the view and by detection, so both agree. Returns
--- `overrides`, `excluded`:
---   overrides[route] = { kind = "reopen"|"missed"|"taken", seq = correction seq, mon? (taken: "add-<seq>") }
---   excluded[mon id] = the correction `{ seq, p }` that excluded it   (mons that "doesn't count" removed)
--- A route entry of the state with `rs` (reset seq) >= override seq was created after the correction
--- and is valid; older entries are shadowed by the override. Corrections apply to what happened
--- before them, never to later facts. "reopen": the route is open again (doesn't count); "missed":
--- marked missed; "taken": a hand-added mon holds the route. A route whose counted mon still counts
--- is not changed by mark_missed / add (the mon holds the slot).
function C.route_overrides(effective, user, st)
  local routes = type(st) == "table" and type(st.routes) == "table" and st.routes or {}
  local ov, excluded, taken = {}, {}, {}
  -- the mon that counts on `route` at the time of the correction `at` (entries stamped `rs` >= at were
  -- created after it and do not exist yet)
  local function holder(route, at)
    local o, e = ov[route], routes[route]
    if e and (e.rs or 0) >= at then e = nil end
    if o and (not e or (e.rs or 0) < o.seq) then
      return (o.kind == "taken" and not excluded[o.mon]) and o.mon or nil
    end
    if e and e.status == "caught" and e.mon and not excluded[e.mon] then return e.mon end
    return nil
  end
  for _, c in ipairs(effective or {}) do
    local p = c.p
    if p.user == user then
      if p.kind == "doesnt_count" then
        if p.mon then
          local route = taken[p.mon]
          if not route then
            for _, key in ipairs(util.keys(routes)) do
              if holder(key, c.seq) == p.mon then route = key; break end
            end
          end
          local holds = route and holder(route, c.seq) == p.mon
          excluded[p.mon] = c
          if holds then ov[route] = { kind = "reopen", seq = c.seq } end
        else
          local h = holder(p.route, c.seq)
          if h then excluded[h] = c end
          ov[p.route] = { kind = "reopen", seq = c.seq }
        end
      elseif p.kind == "reopen" then
        if not holder(p.route, c.seq) then ov[p.route] = { kind = "reopen", seq = c.seq } end
      elseif p.kind == "mark_missed" then
        if not holder(p.route, c.seq) then ov[p.route] = { kind = "missed", seq = c.seq } end
      elseif p.kind == "add" then
        if not holder(p.route, c.seq) then
          local id = "add-" .. c.seq
          ov[p.route] = { kind = "taken", seq = c.seq, mon = id }
          taken[id] = p.route
        end
      end
    end
  end
  return ov, excluded
end

local function is_str(v, max) return type(v) == "string" and #v > 0 and #v <= (max or 64) end
local function is_route_ref(v) return type(v) == "string" and oras.is_key(v) end
local function opt(v, f) return v == nil or f(v) end
local function is_int(v) return math.type(v) == "integer" end

local checks = {
  doesnt_count = function(p)
    return is_str(p.user) and (p.route ~= nil or p.mon ~= nil) and opt(p.route, is_route_ref)
      and opt(p.mon, is_str) and opt(p.reason, function(r) return C.REASONS[r] == true end)
  end,
  undo_death = function(p)
    if not is_route_ref(p.group) or type(p.undone) ~= "table" or #p.undone == 0 then return false end
    for _, e in ipairs(p.undone) do
      if type(e) ~= "table" or not is_str(e.owner) or not is_str(e.mon) or not is_int(e.deaths) or e.deaths < 0 then
        return false
      end
    end
    return true
  end,
  set_group = function(p)
    return is_str(p.user) and is_str(p.mon) and (p.group == "none" or is_route_ref(p.group))
  end,
  add = function(p)
    return is_str(p.user) and is_route_ref(p.route) and is_int(p.species) and p.species > 0
      and C.ADD_STATES[p.state] == true and opt(p.level, is_int)
      and opt(p.nickname, function(n) return is_str(n, 48) end) and opt(p.form, is_int)
  end,
  mark_missed = function(p) return is_str(p.user) and is_route_ref(p.route) end,
  reopen = function(p) return is_str(p.user) and is_route_ref(p.route) end,
  mark_dead = function(p) return is_str(p.user) and is_str(p.mon) end,
  set_gift = function(p) return is_str(p.user) and is_str(p.mon) and type(p.gift) == "boolean" end,
  revert = function(p) return is_int(p.target) and p.target > 0 end,
}

--- Validate a correction payload. Returns true, or false plus a reason string.
function C.validate(payload)
  if type(payload) ~= "table" then return false, "payload is not a table" end
  local check = checks[payload.kind]
  if not check then return false, "unknown kind" end
  if payload.reason ~= nil and type(payload.reason) ~= "string" then return false, "bad reason" end
  if type(payload.reason) == "string" and #payload.reason > 280 then return false, "reason too long" end
  if not check(payload) then return false, "invalid fields for " .. payload.kind end
  if util.json_size(payload) > C.MAX_PAYLOAD then return false, "payload larger than 4 KiB" end
  return true
end

--- Validate a spec returned by a builder (type, source and payload).
function C.validate_spec(s)
  if type(s) ~= "table" or s.type ~= C.TYPE or s.source ~= "manual" then return false, "not a correction spec" end
  return C.validate(s.payload)
end

return C
