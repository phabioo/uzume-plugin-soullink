-- v0.8.1: icon cache keyed by pokemon-core info().icon_rev. Synthetic data only.
local t = require("t")
local mock = require("fb_mock")
local Icons = require("app.icons")

local function setup(info)
  local m = mock.new({})
  local provider = { info = info, icon = function() return "x" end }
  m.set_provider("pokemon.core", provider)
  return m, Icons.new(m.fb), provider
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
