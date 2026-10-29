-- Keeps uz.ui slots up to date: nothing when the tree is unchanged, uz.ui.patch when only props of
-- blocks with an id changed (same structure), uz.ui.set otherwise.
local util = require("model.util")

local S = {}
S.__index = S

S.MAX_PATCHES = 12

function S.new(uz) return setmetatable({ uz = uz, last = {}, sets = 0, patches = 0 }, S) end

-- `status_label` on `location` blocks (Uzume 21) is rejected by older apps: the first tree is sent with it; when the
-- app raises because of that key, it is dropped from this and all later trees and from the remembered trees.
local function strip_label(b)
  if type(b) ~= "table" then return end
  b.status_label = nil
  for _, c in ipairs(b.children or {}) do strip_label(c) end
end

local function is_label_error(err, already)
  return not already and tostring(err):find("status_label", 1, true) ~= nil
end

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
  if self.no_label then strip_label(tree) end
  local old = self.last[slot]
  if old then
    if self.no_label then strip_label(old) end
    if util.encode(old) == util.encode(tree) then return "same" end
    local patches = {}
    if diff(old, tree, patches) and #patches <= S.MAX_PATCHES then
      local ok, err = true, nil
      for _, p in ipairs(patches) do
        ok, err = pcall(self.uz.ui.patch, slot, p.id, p.props)
        if not ok then break end
      end
      if ok then
        self.last[slot] = util.copy(tree)
        self.patches = self.patches + #patches
        return "patch"
      end
      if not is_label_error(err, self.no_label) then error(err, 0) end
      self.no_label = true
      strip_label(tree)
    end
  end
  local ok, err = pcall(self.uz.ui.set, slot, tree)
  if not ok then
    if not is_label_error(err, self.no_label) then error(err, 0) end
    self.no_label = true
    strip_label(tree)
    self.uz.ui.set(slot, tree)
  end
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
