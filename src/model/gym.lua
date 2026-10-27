-- Gym leader battle detection for the save snapshot "before Gym N". Pure; never touches fb.
-- pokemon.core marks no boss or gym battles, so a gym leader is recognised by what it does report:
-- a trainer battle (battle.kind == "trainer") in which a foe has reached the level cap of the next gym
-- (oras.level_cap(badges), the leader's strongest creature). Gym trainers before the leader stay below
-- the cap. The cap table is a local-verification hint (data/oras.lua), so this is a heuristic.
local M = {}

M.MAX_ATTEMPTS = 5 -- tries per gym and battle when fb.save.snapshot refuses (rate limit)

--- Number (1..8) of the gym whose leader fights now, or nil.
--- `battle` is the core's battle() table, `badges` the badges owned, `level_cap` the table lookup.
function M.gym_number(battle, badges, level_cap)
  if type(battle) ~= "table" or battle.active ~= true or battle.kind ~= "trainer" then return nil end
  if math.type(badges) ~= "integer" or badges < 0 or badges > 7 then return nil end
  local cap = level_cap(badges)
  if math.type(cap) ~= "integer" then return nil end
  local top = 0
  for _, foe in ipairs(type(battle.foes) == "table" and battle.foes or {}) do
    if type(foe) == "table" and math.type(foe.level) == "integer" and foe.level > top then top = foe.level end
  end
  if top >= cap then return badges + 1 end
  return nil
end

return M
