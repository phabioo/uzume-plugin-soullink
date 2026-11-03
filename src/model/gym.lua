-- Gym leader battle detection for the save snapshot "before Gym N". Pure; never touches uz.
-- pokemon.core marks no boss or gym battles, so a gym leader is recognised by what it does report:
-- a trainer battle (battle.kind == "trainer") in which a foe has reached the level cap of the next gym
-- (oras.level_cap(badges), the leader's strongest creature) within CAP_MARGIN levels, because a randomized game
-- may change levels (0.9.6, issue 52). Gym trainers before the leader stay below
-- the cap. The cap table is a local-verification hint (data/oras.lua), so this is a heuristic.
local M = {}

--- Trainer battle that is running: kind "trainer", or no kind but explicitly not wild.
local function trainer_battle(b)
  if type(b) ~= "table" or b.active ~= true then return false end
  return b.kind == "trainer" or (b.kind == nil and b.wild == false)
end
M.trainer_battle = trainer_battle

--- Highest foe level of a battle (0 when none is readable).
function M.top_level(battle)
  local top = 0
  for _, foe in ipairs(type(battle) == "table" and type(battle.foes) == "table" and battle.foes or {}) do
    if type(foe) == "table" and math.type(foe.level) == "integer" and foe.level > top then top = foe.level end
  end
  return top
end

M.CAP_MARGIN = 2 -- a foe this far below the cap still counts (randomizer level changes, off-by-one caps)

M.MAX_ATTEMPTS = 5 -- tries per gym and battle when uz.save.snapshot refuses (rate limit)

--- Number (1..8) of the gym whose leader fights now, or nil.
--- `battle` is the core's battle() table, `badges` the badges owned, `level_cap` the table lookup.
function M.gym_number(battle, badges, level_cap)
  if not trainer_battle(battle) then return nil end
  if math.type(badges) ~= "integer" or badges < 0 or badges > 7 then return nil end
  local cap = level_cap(badges)
  if math.type(cap) ~= "integer" then return nil end
  local top = M.top_level(battle)
  if top > 0 and top >= cap - M.CAP_MARGIN then return badges + 1 end
  return nil
end

--- Fight stage of a boss battle: returns kind ("gym" | "elite4" | "champion") and n (gym number, else 1), or nil.
--- Gyms as in gym_number; with all eight badges a trainer battle whose strongest foe reaches
--- `elite_caps.champion` is the champion, else `elite_caps.elite4` the Elite Four (caps: data/oras.lua, unchecked).
function M.stage(battle, badges, level_cap, elite_caps)
  local n = M.gym_number(battle, badges, level_cap)
  if n then return "gym", n end
  if badges ~= 8 or not trainer_battle(battle) then return nil end
  if type(elite_caps) ~= "table" then return nil end
  local top = M.top_level(battle)
  if math.type(elite_caps.champion) == "integer" and top >= elite_caps.champion then return "champion", 1 end
  if math.type(elite_caps.elite4) == "integer" and top >= elite_caps.elite4 then return "elite4", 1 end
  return nil
end

return M
