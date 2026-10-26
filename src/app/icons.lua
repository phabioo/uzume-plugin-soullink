-- Creature icons from pokemon-core `icon(species, form)` (PNG string, or nil + "not_ready" /
-- "unsupported"), fetched lazily and cached in the own cache as `icons/<rev>/<species>-<form>.png`, with
-- `<rev>` = info().icon_rev of the core (a fixed icon decoder gets a new folder); a core without a valid
-- icon_rev keeps `icons/<species>-<form>.png`. The revision is read once, retried while info() fails.
-- The UI asks for `src(species, form)` while rendering: nil until the file is in the cache, so the
-- builders fall back to no icon. Failures are remembered, `not_ready` is retried later with a growing delay.
local I = {}
I.__index = I

I.CORE = "pokemon.core"
I.PER_TICK = 3        -- core calls per tick
I.RETRY_MS = 5000     -- first retry of "not_ready"; grows by this much per try
I.RETRY_MAX_MS = 30000
I.INFO_MS = 10000     -- re-check of info().features.icons while it is false
I.MAX_BAD = 5         -- consecutive failures without any success before icons are switched off

function I.new(fb)
  return setmetatable({ fb = fb, entries = {}, queue = {}, bad = 0, ok_once = false, disabled = false,
                        feature_ok = false, next_info = 0, errors = {},
                        now = 0, rev = nil, rev_done = false, next_rev = 0 }, I)
end

local function valid_rev(r)
  return type(r) == "string" and #r > 0 and #r <= 32 and not r:find("[^%w%-_.]")
end

--- info() of the core; remembers icon_rev on the first answer. Returns the info table or nil.
function I:info()
  local ok, info = pcall(self.fb.call, I.CORE, "info")
  if ok and type(info) == "table" then
    if not self.rev_done then
      self.rev_done = true
      if valid_rev(info.icon_rev) then self.rev = info.icon_rev end
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
  if not e then
    local name = I.name(sp, fm, self.rev)
    local okc, have = pcall(self.fb.cache.exists, name)
    if okc and have then
      e = { st = "have", name = name }
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
    self.fb.log.info("icons: pokemon-core provides none (" .. tostring(why) .. "), not asked again")
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
      local ok, png, why = pcall(self.fb.call, I.CORE, "icon", e.sp, e.fm)
      if not ok then
        self:fail(e, "error")
      elseif type(png) == "string" and #png > 0 then
        local wok = pcall(self.fb.cache.write, e.name, png)
        if wok then
          e.st, changed, self.ok_once, self.bad = "have", true, true, 0
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
