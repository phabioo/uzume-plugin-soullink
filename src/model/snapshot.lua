-- Builds the detection snapshot from the `pokemon.core` interface.
-- Every method may be missing (nil, "unsupported") or not ready (nil, "not_ready"); a missing
-- part stays nil in the snapshot ("unknown"), which detect.diff handles without inventing data.
-- Shapes follow pokemon.core v0.3 (location {zone, location, name}, battle {active, kind, horde, foes, own},
-- encounters [{seq, species, form, shiny, horde, zone, location}], badges {count, flags}).
local P = {}

P.INTERFACE = "pokemon.core"

--- collect(call) -> snapshot, issues
---   call(fn, ...) returns what pokemon.core's `fn` returns (see from_core). Errors are caught.
---   issues = { team = reason?, boxes = reason?, location = ..., battle = ..., encounters = ..., badges = ... }
--- opts.unsupported: table kept by the caller; a part the core answers with "unsupported" is recorded
--- there and not asked again.
--- opts.skip_boxes: do not read the boxes, use opts.boxes (the last complete read) instead.
--- Box numbers run 1..box_count() (assumption; the core documents box(n) without a base: open).
function P.collect(call, opts)
  opts = opts or {}
  local snap, issues = {}, {}
  local function ask(fn, ...)
    local ok, a, b = pcall(call, fn, ...)
    if not ok then return nil, "error" end
    return a, b
  end
  local function part(name, fn, ...)
    if opts.unsupported and opts.unsupported[name] then issues[name] = "unsupported"; return end
    local v, why = ask(fn, ...)
    if why == "unsupported" and opts.unsupported then opts.unsupported[name] = true end
    if type(v) == "table" or (name == "badges" and type(v) == "number") then
      snap[name] = v
    else
      issues[name] = why or "unavailable"
    end
  end

  part("team", "team")
  local n, why
  if opts.skip_boxes then
    snap.boxes = opts.boxes
    if not opts.boxes then issues.boxes = "not_ready" end
    n = -1
  else
    n, why = ask("box_count")
  end
  if n == -1 then
    -- boxes taken from the cache above
  elseif math.type(n) == "integer" and n >= 0 then
    local boxes, complete = {}, true
    for i = 1, n do
      local box = ask("box", i)
      if type(box) == "table" then boxes[i] = box else complete = false; issues.boxes = "not_ready"; break end
    end
    if complete then snap.boxes = boxes end
  else
    issues.boxes = why or "unavailable"
  end
  part("location", "location")
  part("battle", "battle")
  -- core v0.3: kind = "wild" | "trainer" | nil; the detection reads `wild`
  if type(snap.battle) == "table" and snap.battle.wild == nil then
    local b = {}
    for k, v in pairs(snap.battle) do b[k] = v end
    b.wild = b.kind == "wild"
    snap.battle = b
  end
  part("encounters", "encounters")
  part("badges", "badges")
  return snap, issues
end

--- Snapshot from the live core: uz.call("pokemon.core", fn, ...).
function P.from_core(uz, opts)
  return P.collect(function(fn, ...) return uz.call(P.INTERFACE, fn, ...) end, opts)
end

return P
