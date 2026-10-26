local t = require("t")
local mock = require("fb_mock")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

t.case("plugin/main.lua is up to date", function()
  local p = assert(io.popen("lua5.4 tools/bundle.lua --check 2>&1"))
  local out = p:read("a")
  local ok = p:close()
  t.ok(ok, out)
end)

t.case("bundled plugin loads in the mock sandbox", function()
  local m = mock.new({ language = "de" })
  _G.fb = m.fb
  local chunk = assert(loadfile("plugin/main.lua"))
  chunk()
  _G.fb = nil
  t.eq(m.logs[1].text, "SoulLink & Nuzlocke 0.8.1 geladen.")
end)

t.case("sources use no sandbox-forbidden globals", function()
  local p = assert(io.popen("ls src/*.lua src/*/*.lua"))
  for path in p:lines() do
    local src = read(path)
    for _, bad in ipairs({ "io%.", "os%.", "package%.", "debug%.", "dofile", "loadstring", "[^%w_]load%(" }) do
      t.ok(not src:find(bad), path .. " uses " .. bad)
    end
  end
  p:close()
end)

t.case("manifest", function()
  local s = read("plugin/manifest.json")
  for _, needle in ipairs({
    '"id": "uzume.soullink"', '"name": "SoulLink & Nuzlocke"', '"version": "0.8.1"', '"api": 1',
    '"uzume.soullink-core": ">=0.4.0"', '"000400000011C400"', '"000400000011C500"',
    '"permissions": ["ui", "run.state", "video.capture"]', '"entry": "main.lua"', '"panel": { "title": "SoulLink" }',
    '"hud": true', '"tile": true', '"screen": { "title": "SoulLink" }',
    '"toggle-hud"', '"Ctrl+H"', '"doesnt-count"', '"Ctrl+D"', '"open-run"', '"Ctrl+R"',
    "Show or hide the SoulLink widget", "Encounter doesn't count", "Open the run",
  }) do
    t.ok(s:find(needle, 1, true), "manifest lacks " .. needle)
  end
  t.ok(not s:find("memory.write", 1, true))
end)

t.case("i18n: German has exactly the keys of English", function()
  local en = mock.read_json_flat(read("plugin/i18n/en.json"))
  local de = mock.read_json_flat(read("plugin/i18n/de.json"))
  for k in pairs(en) do t.ok(de[k] ~= nil, "de lacks " .. k) end
  for k in pairs(de) do t.ok(en[k] ~= nil, "en lacks " .. k) end
  t.ok(en.route:find("{n}", 1, true))
end)
