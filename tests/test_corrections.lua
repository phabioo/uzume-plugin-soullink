local t = require("t")
local C = require("model.corrections")
local E = require("model.events")
local util = require("model.util")

t.case("builders produce valid manual specs", function()
  local specs = {
    C.doesnt_count({ user = "u1", route = "route-104", reason = "dupe" }),
    C.doesnt_count({ user = "u1", mon = "0000abcd" }),
    C.undo_death({ group = "route-104", reason = "why", undone = { { owner = "u1", mon = "0000abcd", deaths = 1 } } }),
    C.set_group({ user = "u1", mon = "0000abcd", group = "route-105" }),
    C.set_group({ user = "u1", mon = "0000abcd", group = "none" }),
    C.add({ user = "u1", route = "route-121", species = 25, nickname = "X", level = 12, state = "team" }),
    C.add({ user = "u1", route = "place:Cave", species = 25, state = "dead" }),
    C.mark_missed({ user = "u1", route = "route-112" }),
    C.mark_dead({ user = "u1", mon = "0000abcd" }),
    C.set_gift({ user = "u1", mon = "0000abcd" }),
    C.revert({ target = 7, reason = "oops" }),
  }
  for i, s in ipairs(specs) do
    t.eq(s.type, "soullink.correction")
    t.eq(s.source, "manual")
    local ok, why = C.validate_spec(s)
    t.ok(ok, "spec " .. i .. ": " .. tostring(why))
  end
  t.eq(#C.KINDS, 9)
  t.eq(C.set_gift({ user = "u", mon = "m" }).payload.gift, true)
end)

t.case("validators reject bad payloads", function()
  local bad = {
    "x", {}, { kind = "nope" },
    { kind = "doesnt_count", user = "u" },
    { kind = "doesnt_count", user = "u", route = "bogus" },
    { kind = "doesnt_count", user = "u", route = "route-101", reason = "meh" },
    { kind = "undo_death", group = "route-101", undone = {} },
    { kind = "undo_death", group = "route-101", undone = { { owner = "u", mon = "m" } } },
    { kind = "undo_death", group = "nonsense", undone = { { owner = "u", mon = "m", deaths = 1 } } },
    { kind = "set_group", user = "u", mon = "m", group = "bogus" },
    { kind = "add", user = "u", route = "route-101", species = 25, state = "limbo" },
    { kind = "add", user = "u", route = "route-101", species = 0, state = "box" },
    { kind = "mark_missed", user = "u" },
    { kind = "mark_dead", mon = "m" },
    { kind = "set_gift", user = "u", mon = "m", gift = "yes" },
    { kind = "revert", target = 0 },
    { kind = "revert", target = "7" },
    { kind = "revert", target = 3, reason = 5 },
  }
  for i, p in ipairs(bad) do
    t.ok(not C.validate(p), "payload " .. i .. " should be invalid")
  end
  t.ok(not C.validate_spec({ type = "other", source = "manual", payload = { kind = "revert", target = 1 } }))
  t.ok(not C.validate_spec({ type = C.TYPE, source = "automatic", payload = { kind = "revert", target = 1 } }))
end)

t.case("payload limit is 4 KiB", function()
  local undone = {}
  for i = 1, 200 do undone[i] = { owner = "user-" .. i, mon = string.format("%08x", i), deaths = 1 } end
  local ok, why = C.validate(C.undo_death({ group = "route-101", undone = undone }).payload)
  t.ok(not ok); t.eq(why, "payload larger than 4 KiB")
  local ok2 = C.validate(C.revert({ target = 1, reason = string.rep("x", 400) }).payload)
  t.ok(not ok2)
end)

t.case("automatic event builders", function()
  local c = E.from_fact({ kind = "catch", mon = "00000100", species = 10, nickname = "Blob", level = 3,
    route = "route-101", where = "box", counts = true, shiny = false }, "u1")
  t.eq(c.type, "soullink.catch"); t.eq(c.source, "automatic")
  t.eq(c.payload, { user = "u1", mon = "00000100", species = 10, nickname = "Blob", level = 3,
    route = "route-101", where = "box", counts = true })
  local d = E.from_fact({ kind = "death", mon = "00000100", species = 10, deaths = 2, route = "route-101" }, "u1")
  t.eq(d.type, "soullink.death"); t.eq(d.payload.deaths, 2)
  local e = E.from_fact({ kind = "encounter", species = 30, counts = false, why = "dupe", route = "route-101", horde = true }, "u1")
  t.eq(e.type, "soullink.encounter"); t.eq(e.payload.outcome, "seen"); t.eq(e.payload.horde, true)
  local m = E.from_fact({ kind = "missed", route = "route-101", species = 30 }, "u1")
  t.eq(m.type, "soullink.encounter"); t.eq(m.payload.outcome, "missed"); t.eq(m.payload.counts, false)
  local p = E.from_fact({ kind = "place", key = "route-104", name = "N", manual = true }, "u1")
  t.eq(p.type, "soullink.place"); t.eq(p.payload.route, "route-104")
  t.eq(E.from_fact({ kind = "evolve" }, "u1"), nil)
  t.eq(#E.from_facts({ { kind = "moved" }, { kind = "death", mon = "m", species = 1, deaths = 1 } }, "u1"), 1)
  t.ok(E.fits(c.payload))
  t.ok(util.json_size(c.payload) < E.MAX_PAYLOAD)
end)
