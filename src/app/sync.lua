-- Keeps uz.ui slots up to date: nothing when the tree is unchanged, uz.ui.patch when only props of
-- blocks with an id changed (same structure), uz.ui.set otherwise.
local util = require("model.util")

local S = {}
S.__index = S

S.MAX_PATCHES = 12

function S.new(uz) return setmetatable({ uz = uz, last = {}, sets = 0, patches = 0 }, S) end

local function diff(old, new, patches)
  if old.type ~= new.type or old.id ~= new.id then return false end
  local oc, nc = old.children or {}, new.children or {}
  if #oc ~= #nc then return false end
  local changed
  for k, v in pairs(new) do
    if k ~= "type" and k ~= "id" and k ~= "children" and util.encode(v) ~= util.encode(old[k]) then
      changed = changed or {}
      changed[k] = v
    end
  end
  for k in pairs(old) do
    if k ~= "type" and k ~= "id" and k ~= "children" and new[k] == nil then return false end -- patch cannot remove
  end
  if changed then
    if not new.id then return false end
    patches[#patches + 1] = { id = new.id, props = changed }
  end
  for i = 1, #nc do
    if not diff(oc[i], nc[i], patches) then return false end
  end
  return true
end

--- Show `tree` in `slot`. Returns "same", "patch" or "set".
function S:push(slot, tree)
  local old = self.last[slot]
  if old then
    if util.encode(old) == util.encode(tree) then return "same" end
    local patches = {}
    if diff(old, tree, patches) and #patches <= S.MAX_PATCHES then
      for _, p in ipairs(patches) do self.uz.ui.patch(slot, p.id, p.props) end
      self.last[slot] = util.copy(tree)
      self.patches = self.patches + #patches
      return "patch"
    end
  end
  self.uz.ui.set(slot, tree)
  self.last[slot] = util.copy(tree)
  self.sets = self.sets + 1
  return "set"
end

function S:clear(slot)
  if self.last[slot] then
    self.uz.ui.clear(slot)
    self.last[slot] = nil
  end
end

return S
