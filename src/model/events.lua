-- Payload builders for the automatic run events. Posting (fb.run.event) is done by the caller.
-- Builders return a spec { type =, payload =, source = "automatic" }; `text` (at most 280
-- characters, translated, with names read from the game) is added by the caller.
local util = require("model.util")

local E = {}

E.TYPES = {
  catch = "soullink.catch",
  death = "soullink.death",
  encounter = "soullink.encounter",
  place = "soullink.place",
  badge = "soullink.badge",
  correction = "soullink.correction",
}
E.MAX_PAYLOAD = 4096

local function put(t, k, v) if v ~= nil then t[k] = v end end

--- Build the event spec for a detection fact, or nil for facts without an event
--- (evolve, moved). `user` is the user id of the own participant.
---   catch     payload { user, mon, species, species_name?, form?, nickname?, level?, shiny?, route?, counts, why?, gift?, starter?, where }
---   death     payload { user, mon, species, species_name?, nickname?, route?, deaths }
---   encounter payload { user, outcome = "seen"|"missed", route?, species?, species_name?, form?, shiny?, horde?, counts, why? }
---   place     payload { user, route?, name?, manual }
---   badge     payload { user, index, count } (badge number 1..8; no names)
function E.from_fact(fact, user)
  local k = fact.kind
  local p = { user = user }
  if k == "catch" then
    p.mon, p.species, p.counts, p.where = fact.mon, fact.species, fact.counts, fact.where
    put(p, "form", fact.form); put(p, "nickname", fact.nickname); put(p, "level", fact.level)
    put(p, "route", fact.route); put(p, "why", fact.why); put(p, "species_name", fact.species_name)
    if fact.shiny then p.shiny = true end
    if fact.gift then p.gift = true end
    if fact.starter then p.starter = true end
    return { type = E.TYPES.catch, payload = p, source = "automatic" }
  elseif k == "death" then
    p.mon, p.species, p.deaths = fact.mon, fact.species, fact.deaths
    put(p, "nickname", fact.nickname); put(p, "route", fact.route); put(p, "species_name", fact.species_name)
    return { type = E.TYPES.death, payload = p, source = "automatic" }
  elseif k == "encounter" or k == "missed" then
    p.outcome = k == "missed" and "missed" or "seen"
    if k == "missed" then p.counts = false else p.counts = fact.counts end
    put(p, "route", fact.route); put(p, "species", fact.species)
    if k == "encounter" then
      put(p, "form", fact.form); put(p, "why", fact.why); put(p, "species_name", fact.species_name)
      if fact.shiny then p.shiny = true end
      if fact.horde then p.horde = true end
    end
    return { type = E.TYPES.encounter, payload = p, source = "automatic" }
  elseif k == "badge" then
    p.index, p.count = fact.index, fact.count
    return { type = E.TYPES.badge, payload = p, source = "automatic" }
  elseif k == "place" then
    put(p, "route", fact.key); put(p, "name", fact.name)
    p.manual = fact.manual == true
    return { type = E.TYPES.place, payload = p, source = "automatic" }
  end
  return nil
end

--- All specs for a list of facts, in order.
function E.from_facts(facts, user)
  local out = {}
  for _, f in ipairs(facts) do
    local s = E.from_fact(f, user)
    if s then out[#out + 1] = s end
  end
  return out
end

--- True when the payload fits the platform limit (4 KiB).
function E.fits(payload) return util.json_size(payload) <= E.MAX_PAYLOAD end

return E
