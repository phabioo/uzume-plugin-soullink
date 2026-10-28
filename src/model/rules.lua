-- Run rules: defaults and parsing of the run settings.
-- Settings live in the run settings under the plugin id:
--   run.settings["uzume.soullink"] = { mode = "soullink", rules = { dupes_clause = false, ... } }
local R = {}

R.PLUGIN_ID = "uzume.soullink"
R.MODES = { nuzlocke = true, soullink = true }

--- Default rule switches (all are booleans).
R.DEFAULTS = {
  first_encounter_only = true,
  dupes_clause = true,
  shiny_clause = true,
  hordes_count = false,
  pairs_differ_primary_type = false,
  only_linked_in_team = false,
  nickname_required = true,
  level_caps = true,
}

--- Rule keys in a fixed order (for UI lists).
R.ORDER = {
  "first_encounter_only", "dupes_clause", "shiny_clause", "hordes_count",
  "pairs_differ_primary_type", "only_linked_in_team", "nickname_required", "level_caps",
}

--- Fresh copy of the default rules.
function R.defaults()
  local t = {}
  for k, v in pairs(R.DEFAULTS) do t[k] = v end
  return t
end

--- Number of participants with status "joined" (a missing status counts as joined).
function R.joined_count(run)
  local n = 0
  for _, p in ipairs(type(run) == "table" and run.participants or {}) do
    if type(p) == "table" and (p.status == nil or p.status == "joined") then n = n + 1 end
  end
  return n
end

--- Parse the rules of a run (`uz.run.current()` result, may be nil).
--- Returns cfg = { mode = "nuzlocke"|"soullink", mode_set = bool, rules = {<flag> = bool} }.
--- Unknown keys are ignored, wrong types fall back to the defaults. Without a valid mode:
--- "soullink" with two or more joined participants, otherwise "nuzlocke".
function R.parse(run)
  local mine
  if type(run) == "table" and type(run.settings) == "table" then
    mine = run.settings[R.PLUGIN_ID]
  end
  if type(mine) ~= "table" then mine = {} end
  local cfg = { rules = R.defaults(), mode_set = false }
  if type(mine.mode) == "string" and R.MODES[mine.mode] then
    cfg.mode, cfg.mode_set = mine.mode, true
  else
    cfg.mode = R.joined_count(run) >= 2 and "soullink" or "nuzlocke"
  end
  if type(mine.rules) == "table" then
    for k, default in pairs(R.DEFAULTS) do
      local v = mine.rules[k]
      if type(v) == type(default) then cfg.rules[k] = v end
    end
  end
  return cfg
end

--- Accepts a cfg from parse(), a flat table of rule flags or nil; returns a complete cfg.
function R.normalize(x)
  if type(x) == "table" and type(x.rules) == "table" and R.MODES[x.mode] then
    local cfg = { mode = x.mode, mode_set = x.mode_set == true, rules = R.defaults() }
    for k, default in pairs(R.DEFAULTS) do
      if type(x.rules[k]) == type(default) then cfg.rules[k] = x.rules[k] end
    end
    return cfg
  end
  local cfg = { mode = "nuzlocke", mode_set = false, rules = R.defaults() }
  if type(x) == "table" then
    if type(x.mode) == "string" and R.MODES[x.mode] then cfg.mode, cfg.mode_set = x.mode, true end
    local flat = type(x.rules) == "table" and x.rules or x
    for k, default in pairs(R.DEFAULTS) do
      if type(flat[k]) == type(default) then cfg.rules[k] = flat[k] end
    end
  end
  return cfg
end

--- Settings table to store in the run settings for `cfg` (what a run creator writes).
function R.to_settings(cfg)
  cfg = R.normalize(cfg)
  local rules = {}
  for k, v in pairs(cfg.rules) do rules[k] = v end
  return { [R.PLUGIN_ID] = { mode = cfg.mode, rules = rules } }
end

return R
