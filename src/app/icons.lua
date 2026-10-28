-- Creature icons from pokemon-core `icon(species, form)` (PNG string, or nil + "not_ready" /
-- "unsupported"), fetched lazily and cached in the own cache as `icons/<rev>/<species>-<form>.png`, with
-- `<rev>` = info().icon_rev of the core (a fixed icon decoder gets a new folder); a core without a valid
-- icon_rev keeps `icons/<species>-<form>.png`. The revision is read from info(), retried (every INFO_MS, at
-- most REV_TRIES answers) while info() fails or answers without a valid icon_rev; files cached under a
-- rev-less name are fetched again under the revision once it arrives. A "have" entry is only a hint:
-- its file is re-checked in the cache every RECHECK_MS, so a deleted cache is refilled.
-- The UI asks for `src(species, form)` while rendering: nil until the file is in the cache, so the
-- builders fall back to no icon. Failures are remembered, `not_ready` is retried later with a growing delay.
local I = {}
I.__index = I

I.CORE = "pokemon.core"
I.PER_TICK = 3        -- core calls per tick
I.RETRY_MS = 5000     -- first retry of "not_ready"; grows by this much per try
I.RETRY_MAX_MS = 30000
I.INFO_MS = 10000     -- re-check of info().features.icons while it is false
I.REV_TRIES = 3       -- info() answers without a valid icon_rev before the rev-less name is final
I.RECHECK_MS = 5000   -- re-check of the cache file behind a "have" entry
I.MAX_BAD = 5         -- consecutive failures without any success before icons are switched off

function I.new(uz)
  return setmetatable({ uz = uz, entries = {}, queue = {}, bad = 0, ok_once = false, disabled = false,
                        feature_ok = false, next_info = 0, errors = {},
                        now = 0, rev = nil, rev_done = false, next_rev = 0, rev_tries = 0 }, I)
end

local function valid_rev(r)
  return type(r) == "string" and #r > 0 and #r <= 32 and not r:find("[^%w%-_.]")
end

--- info() of the core; remembers icon_rev on the first answer. Returns the info table or nil.
function I:info()
  local ok, info = pcall(self.uz.call, I.CORE, "info")
  if ok and type(info) == "table" then
    if not self.rev_done and self.now >= self.next_rev then
      if valid_rev(info.icon_rev) then
        self.rev, self.rev_done = info.icon_rev, true
      else
        self.rev_tries = self.rev_tries + 1
        if self.rev_tries >= I.REV_TRIES then self.rev_done = true
        else self.next_rev = self.now + I.INFO_MS end
      end
    end
    return info
  end
  if not self.rev_done then self.next_rev = self.now + I.INFO_MS end
  return nil
end

local function norm(species, form)
  if math.type(species) ~= "integer" or species < 1 or species > 100000 then return nil end
  if math.type(form) ~= "integer" or form < 0 or form > 1000 then form = 0 end
  return species, form
end

function I.name(species, form, rev)
  return "icons/" .. (rev and (rev .. "/") or "") .. species .. "-" .. form .. ".png"
end

--- `cache:` src of the icon when it is in the cache, else nil (and the icon is queued once).
function I:src(species, form)
  if self.disabled then return nil end
  local sp, fm = norm(species, form)
  if not sp then return nil end
  if not self.rev_done and self.now >= self.next_rev then self:info() end
  local k = sp .. "-" .. fm
  local e = self.entries[k]
  local name = I.name(sp, fm, self.rev)
  if e and e.st == "have" and (e.name ~= name or self.now >= e.chk + I.RECHECK_MS) then
    -- revision arrived late, or time to prove the file is still there
    local okc, have = pcall(self.uz.cache.exists, e.name)
    if e.name == name and okc and have then
      e.chk = self.now
    else
      e = nil -- missing or unreadable: fetch again through the normal queue
    end
  end
  if not e then
    local okc, have = pcall(self.uz.cache.exists, name)
    if okc and have then
      e = { st = "have", name = name, chk = self.now }
    else
      e = { st = "queued", name = name, sp = sp, fm = fm, tries = 0 }
      self.queue[#self.queue + 1] = k
    end
    self.entries[k] = e
  end
  if e.st == "have" then return "cache:" .. e.name end
  return nil
end

function I:fail(e, why)
  e.st = "failed"
  self.bad = self.bad + 1
  if self.bad >= I.MAX_BAD and not self.ok_once then
    self.disabled = true
    self.uz.log.info("icons: pokemon-core provides none (" .. tostring(why) .. "), not asked again")
  end
end

--- Fetch a few queued icons. Returns true when at least one became available.
function I:pump(now)
  self.now = now
  if self.disabled then return false end
  for k, e in pairs(self.entries) do
    if e.st == "retry" and now >= e.at then e.st = "queued"; self.queue[#self.queue + 1] = k end
  end
  if #self.queue == 0 then return false end
  if not self.feature_ok then
    if now < self.next_info then return false end
    local info = self:info()
    if info and type(info.features) == "table" and info.features.icons ~= true then
      self.next_info = now + I.INFO_MS
      return false
    end
    self.feature_ok = true -- supported, or info() unknown: just try
  end
  local changed = false
  for _ = 1, I.PER_TICK do
    local k = table.remove(self.queue, 1)
    if not k then break end
    local e = self.entries[k]
    if e and e.st == "queued" then
      e.name = I.name(e.sp, e.fm, self.rev) -- the revision may have arrived since src()
      local ok, png, why = pcall(self.uz.call, I.CORE, "icon", e.sp, e.fm)
      if not ok then
        self:fail(e, "error")
      elseif type(png) == "string" and #png > 0 then
        local wok = pcall(self.uz.cache.write, e.name, png)
        if wok then
          e.st, e.chk, changed, self.ok_once, self.bad = "have", now, true, true, 0
        else
          self:fail(e, "cache")
        end
      elseif why == "not_ready" then
        e.tries = e.tries + 1
        e.st, e.at = "retry", now + math.min(I.RETRY_MS * e.tries, I.RETRY_MAX_MS)
        break -- the core is busy: do not ask for the rest now
      else
        self:fail(e, why)
      end
    end
  end
  return changed
end

return I
