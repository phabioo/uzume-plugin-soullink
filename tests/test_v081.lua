-- v0.8.1: icon cache keyed by pokemon-core info().icon_rev. Synthetic data only.
local t = require("t")
local mock = require("uz_mock")
local Icons = require("app.icons")

local function setup(info)
  local m = mock.new({})
  local provider = { info = info, icon = function() return "x" end }
  m.set_provider("pokemon.core", provider)
  return m, Icons.new(m.uz), provider
end

t.case("icons: icon_rev gives a folder per revision", function()
  local m, ic = setup(function() return { features = { icons = true }, icon_rev = "r3-o1" } end)
  ic:src(25, 0)
  ic:pump(0)
  t.ok(m.cache_files["icons/r3-o1/25-0.png"], "written under the revision")
  t.eq(ic:src(25, 0), "cache:icons/r3-o1/25-0.png")
end)

t.case("icons: no icon_rev keeps the old path", function()
  local m, ic = setup(function() return { features = { icons = true } } end)
  ic:src(25, 0)
  ic:pump(0)
  t.ok(m.cache_files["icons/25-0.png"], "old name")
  t.eq(ic:src(25, 0), "cache:icons/25-0.png")
end)

t.case("icons: invalid icon_rev keeps the old path", function()
  for _, bad in ipairs({ "", "a/b", "..\\x", "r 3", string.rep("a", 33), 5, true }) do
    local m, ic = setup(function() return { features = { icons = true }, icon_rev = bad } end)
    ic:src(25, 0)
    ic:pump(0)
    t.ok(m.cache_files["icons/25-0.png"], "old name for " .. tostring(bad))
  end
end)

t.case("icons: info() failing is retried after INFO_MS", function()
  local up = false
  local m, ic = setup(function()
    if not up then error("not ready") end
    return { features = { icons = true }, icon_rev = "r1" }
  end)
  t.eq(ic:src(1, 0), nil)
  up = true
  t.eq(ic:src(2, 0), nil) -- still inside the retry delay
  ic:pump(Icons.INFO_MS)
  ic:src(3, 0)
  ic:pump(Icons.INFO_MS + 1)
  t.ok(m.cache_files["icons/r1/3-0.png"], "revision picked up on the later call")
end)

t.case("icons: a deleted cache file is fetched again", function()
  local m, ic, prov = setup(function() return { features = { icons = true }, icon_rev = "r1" } end)
  local calls = 0
  prov.icon = function() calls = calls + 1; return "png" end
  ic:src(25, 0); ic:pump(0)
  t.eq(ic:src(25, 0), "cache:icons/r1/25-0.png")
  t.eq(calls, 1)
  m.cache_files["icons/r1/25-0.png"] = nil -- cache folder wiped while the plugin runs
  ic:pump(Icons.RECHECK_MS)
  t.eq(ic:src(25, 0), nil, "missing file is not reported as present")
  ic:pump(Icons.RECHECK_MS + 1)
  t.eq(calls, 2, "icon() asked again")
  t.eq(m.cache_files["icons/r1/25-0.png"], "png", "rewritten")
  t.eq(ic:src(25, 0), "cache:icons/r1/25-0.png")
end)

t.case("icons: info() without icon_rev is retried, late rev refetches under it", function()
  local rev
  local m, ic = setup(function() return { features = { icons = true }, icon_rev = rev } end)
  ic:src(7, 0); ic:pump(0)
  t.ok(m.cache_files["icons/7-0.png"], "rev-less name while unknown")
  t.eq(ic.rev_done, false, "not final after the first answer")
  rev = "r9"
  ic:pump(Icons.INFO_MS)
  t.eq(ic:src(7, 0), nil, "old file is not reused under the new revision")
  ic:pump(Icons.INFO_MS + 1)
  t.eq(ic.rev, "r9")
  t.eq(ic:src(7, 0), "cache:icons/r9/7-0.png")
end)

t.case("icons: rev-less answers stop being retried after REV_TRIES", function()
  local n = 0
  local m, ic = setup(function() n = n + 1; return { features = { icons = true } } end)
  for i = 0, Icons.REV_TRIES + 2 do ic.now = i * Icons.INFO_MS; ic:src(1, 0) end
  t.eq(ic.rev_done, true)
  t.eq(n, Icons.REV_TRIES)
end)
