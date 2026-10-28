-- Fake `uz` for tests. See uz_mock.new.
local M = {}

-- Minimal reader for flat JSON objects with string values.
function M.read_json_flat(s)
  local out = {}
  local esc = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
  local pos = 1
  while true do
    local k, e = s:match('^%s*[{,]?%s*"([^"]*)"%s*:%s*()', pos)
    if not k then break end
    pos = e
    assert(s:sub(pos, pos) == '"', "flat string values only")
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        if n == "u" then
          buf[#buf + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          buf[#buf + 1] = assert(esc[n], "bad escape")
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    out[k] = table.concat(buf)
  end
  return out
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local function check_value(v, depth)
  local tv = type(v)
  if tv == "function" or tv == "userdata" or tv == "thread" then
    error("value of type " .. tv .. " cannot be passed between plugins", 3)
  end
  if tv == "table" then
    if depth > 32 then error("value too deep", 3) end
    for k, x in pairs(v) do
      if type(k) == "table" then error("table used as key", 3) end
      check_value(x, depth + 1)
    end
  end
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = deep_copy(x) end
  return c
end

-- opts: game, memory = { {addr, data}, ... }, romfs = {path=data}, rom (string), codec, language, i18n_dir
function M.new(opts)
  opts = opts or {}
  local mock = { logs = {}, events = {}, provided = {}, watches = {}, dev_watches = {}, cache_files = {} }
  local regions = opts.memory or {}
  mock.regions = regions
  local uz = { api = 1, plugin = { id = "uzume.soullink", version = "0.9.1" } }
  uz.game = opts.game or {}
  if opts.language and not uz.game.language then uz.game.language = opts.language end
  mock.uz = uz

  local function read(addr, len)
    if type(addr) ~= "number" or len < 0 then return nil end
    for _, r in ipairs(regions) do
      if addr >= r.addr and addr + len <= r.addr + #r.data then
        local o = addr - r.addr
        return r.data:sub(o + 1, o + len)
      end
    end
    return nil
  end
  local function reader(fmt, size)
    return function(addr)
      local s = read(addr, size)
      if not s then return nil end
      return (string.unpack(fmt, s))
    end
  end

  uz.memory = {
    watch = function(key, addr, len) mock.watches[key] = { addr = addr, len = len } end,
    unwatch = function(key) mock.watches[key] = nil end,
    u8 = reader("<I1", 1), u16 = reader("<I2", 2), u32 = reader("<I4", 4), u64 = reader("<i8", 8),
    s8 = reader("<i1", 1), s16 = reader("<i2", 2), s32 = reader("<i4", 4),
    bytes = function(addr, len) return read(addr, len) end,
    frame = function() return opts.frame or 1 end,
  }

  local romfs = opts.romfs or {}
  uz.rom = {
    size = function() return opts.rom and #opts.rom or nil end,
    read = function(offset, len)
      if not opts.rom or offset >= #opts.rom then return nil end
      return opts.rom:sub(offset + 1, offset + len)
    end,
    romfs = function(path)
      local d = romfs[path]
      if d == nil then return nil, "file not found: " .. tostring(path) end
      return d
    end,
    romfs_list = function(dir)
      dir = dir:gsub("/+$", "")
      local seen, out = {}, {}
      for path, data in pairs(romfs) do
        local rest = path:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+)")
        if rest and not seen[rest] then
          seen[rest] = true
          local is_dir = path ~= dir .. "/" .. rest
          out[#out + 1] = { name = rest, dir = is_dir, size = is_dir and 0 or #data }
        end
      end
      table.sort(out, function(a, b) return a.name < b.name end)
      if #out == 0 then return nil, "directory not found: " .. dir end
      return out
    end,
  }

  uz.codec = opts.codec or {}

  uz.log = {}
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    uz.log[level] = function(...)
      local parts = table.pack(...)
      for i = 1, parts.n do parts[i] = tostring(parts[i]) end
      mock.logs[#mock.logs + 1] = { level = level, text = table.concat(parts, "\t", 1, parts.n) }
    end
  end

  local now = 1000
  local handlers = {}
  --- mock.fire_event(plugin_id, name, value): deliver an event to subscribers (host events: "uz"; "fb" on Uzume < 0.22).
  function mock.fire_event(plugin_id, name, value)
    for _, h in ipairs(handlers) do
      if (h[1] == "*" or h[1] == plugin_id) and h[2] == name then h[3](deep_copy(value), plugin_id, name) end
    end
  end
  --- mock.subscribed(plugin_id, name): true when a handler for that host source and event exists.
  function mock.subscribed(plugin_id, name)
    for _, h in ipairs(handlers) do
      if h[1] == plugin_id and h[2] == name then return true end
    end
    return false
  end
  uz.events = {
    emit = function(name, value)
      check_value(value, 1)
      mock.events[#mock.events + 1] = { name = name, value = deep_copy(value) }
    end,
    on = function(plugin_id, name, fn) handlers[#handlers + 1] = { plugin_id, name, fn } end,
  }

  uz.provide = function(name, tbl)
    assert(type(name) == "string" and type(tbl) == "table", "bad provide")
    mock.provided[name] = tbl
  end

  local tick_fn
  uz.on_tick = function(fn) tick_fn = fn end
  mock.frame = 0
  function mock.tick(n)
    for _ = 1, n or 1 do
      mock.frame = mock.frame + 1
      now = now + 34
      if tick_fn then tick_fn(mock.frame) end
    end
  end

  local strings = {}
  local dir = opts.i18n_dir or "plugin/i18n"
  strings = M.read_json_flat(read_file(dir .. "/en.json"))
  if opts.language and opts.language ~= "en" then
    local f = io.open(dir .. "/" .. opts.language .. ".json", "rb")
    if f then
      local s = f:read("a"); f:close()
      for k, v in pairs(M.read_json_flat(s)) do strings[k] = v end
    end
  end
  uz.i18n = {
    t = function(key, vars)
      local s = strings[key] or key
      return (s:gsub("{([%w_]+)}", function(k)
        if vars and vars[k] ~= nil then return tostring(vars[k]) end
      end))
    end,
  }

  -- uz.call: pluggable fake `pokemon.core` (or any other) provider.
  -- mock.set_provider("pokemon.core", { team = function() ... end, ... })
  mock.providers, mock.calls = {}, {}
  function mock.set_provider(name, tbl) mock.providers[name] = tbl end
  uz.call = function(name, fn, ...)
    local p = mock.providers[name]
    if not p then error("no plugin provides " .. tostring(name), 2) end
    local f = p[fn]
    if type(f) ~= "function" then error("interface " .. name .. " has no function " .. tostring(fn), 2) end
    local args = table.pack(...)
    for i = 1, args.n do check_value(args[i], 1); args[i] = deep_copy(args[i]) end
    mock.calls[#mock.calls + 1] = { name = name, fn = fn }
    local res = table.pack(f(table.unpack(args, 1, args.n)))
    for i = 1, res.n do check_value(res[i], 1); res[i] = deep_copy(res[i]) end
    return table.unpack(res, 1, res.n)
  end

  -- uz.run: fake run state, only when opts.run is given:
  --   opts.run = { current = { id, name, status, me, settings, plugins, participants },
  --                states = { [user_id] = state }, events = { ... } }
  if opts.run then
    local json = require("model.util")
    local run = { current = deep_copy(opts.run.current), states = {}, events = {}, board = nil,
                  handlers = { event = {}, state = {}, status = {}, participants = {} }, next_seq = 1,
                  client_ids = 0 }
    for u, st in pairs(opts.run.states or {}) do run.states[u] = deep_copy(st) end
    mock.run = run
    local me = run.current.me
    local plugin_id = uz.plugin.id
    run.attempts = 0 -- write calls (setState, event, setBoard) made while in view mode
    local function writable()
      if run.current.view then
        run.attempts = run.attempts + 1
        return false, "read only outside the game"
      end
      local s = run.current.status
      if s == "starting" or s == "active" then return true end
      return false, "run is " .. tostring(s)
    end
    local function fire(kind, ...)
      for _, h in ipairs(run.handlers[kind]) do h(...) end
    end
    -- add_event(user_id, spec) appends an event of another participant (or the own one)
    function run.add_event(user_id, spec)
      local ev = { seq = run.next_seq, user_id = user_id, user_name = user_id, plugin_id = plugin_id,
                   source = spec.source or "automatic", type = spec.type, text = spec.text,
                   payload = deep_copy(spec.payload or {}) }
      run.next_seq = run.next_seq + 1
      run.events[#run.events + 1] = ev
      fire("event", deep_copy(ev))
      return ev
    end
    function run.set_state_for(user_id, st)
      run.states[user_id] = deep_copy(st)
      fire("state", user_id, deep_copy(st), plugin_id)
    end
    for _, ev in ipairs(opts.run.events or {}) do run.add_event(ev.user_id, ev) end
    uz.run = {
      current = function() return deep_copy(run.current) end,
      state = function(user_id) return deep_copy(run.states[user_id or me]) end,
      states = function()
        local out = {}
        for u, st in pairs(run.states) do out[u] = deep_copy(st) end
        return out
      end,
      setState = function(tbl)
        if type(tbl) ~= "table" then error("setState: table expected", 2) end
        check_value(tbl, 1)
        if json.json_size(tbl) > 64 * 1024 then error("setState: state larger than 64 KiB", 2) end
        local ok, why = writable()
        if not ok then return nil, why end
        run.set_state_for(me, tbl)
        return true
      end,
      event = function(spec)
        if type(spec) ~= "table" or type(spec.type) ~= "string" then error("event: type required", 2) end
        if spec.text ~= nil and (type(spec.text) ~= "string" or utf8.len(spec.text) > 280) then
          error("event: text too long", 2)
        end
        if spec.payload ~= nil then
          if type(spec.payload) ~= "table" then error("event: payload must be a table", 2) end
          check_value(spec.payload, 1)
          if json.json_size(spec.payload) > 4096 then error("event: payload larger than 4 KiB", 2) end
        end
        if spec.source ~= nil and spec.source ~= "automatic" and spec.source ~= "manual" then
          error("event: bad source", 2)
        end
        local ok, why = writable()
        if not ok then return nil, why end
        run.client_ids = run.client_ids + 1
        local ev = run.add_event(me, spec)
        return string.format("00000000-0000-4000-8000-%012d", ev.seq)
      end,
      events = function(after_seq, limit)
        limit = math.max(1, math.min(limit or 100, 500))
        local out = {}
        for _, ev in ipairs(run.events) do
          if ev.seq > (after_seq or 0) and #out < limit then out[#out + 1] = deep_copy(ev) end
        end
        return out
      end,
      on = function(kind, fn)
        local list = run.handlers[kind]
        if not list then error("run.on: unknown kind " .. tostring(kind), 2) end
        local n = 0
        for _, l in pairs(run.handlers) do n = n + #l end
        if n >= 16 then error("run.on: at most 16 callbacks", 2) end
        list[#list + 1] = fn
      end,
      setBoard = function(tree)
        if type(tree) ~= "table" then error("setBoard: table expected", 2) end
        if json.json_size(tree) > 64 * 1024 then error("setBoard: tree larger than 64 KiB", 2) end
        local vok, verr = require("ui_validator").validate(tree)
        if not vok then error("setBoard: ui tree: " .. verr, 2) end
        local ok, why = writable()
        if not ok then return nil, why end
        run.board = deep_copy(tree)
        run.board_sets = (run.board_sets or 0) + 1
        return true
      end,
    }
  end

  -- uz.ui: validates every tree against the documented catalog and records what was shown.
  local ui_validator = require("ui_validator")
  local ui = { trees = {}, sets = {}, patches = {}, notes = {}, titles = {}, dot = nil, badge = nil }
  mock.ui = ui
  local function find_block(tree, id)
    return ui_validator.find(tree, id)
  end
  local function declared(slot)
    if slot == "panel" or slot == "hud" or slot == "screen" or slot == "detail" or slot == "run" then return true end
    return slot:match("^tile:[%w_.%-]+$") ~= nil
  end
  uz.ui = {
    set = function(slot, tree)
      if not declared(slot) then error("slot " .. tostring(slot) .. " not declared in manifest", 2) end
      local ok, err = ui_validator.validate(tree)
      if not ok then error("ui tree: " .. err, 2) end
      ui.trees[slot] = deep_copy(tree)
      ui.sets[slot] = (ui.sets[slot] or 0) + 1
    end,
    patch = function(slot, id, props)
      local tree = ui.trees[slot]
      if not tree then error("no tree in slot " .. tostring(slot), 2) end
      local b = find_block(tree, id)
      if not b then error("unknown id " .. tostring(id), 2) end
      if props.type or props.id or props.children then error("patch: type/id/children not allowed", 2) end
      local merged = deep_copy(b)
      for k, v in pairs(props) do merged[k] = deep_copy(v) end
      local ok, err = ui_validator.validate(merged)
      if not ok then error("ui patch: " .. err, 2) end
      for k, v in pairs(props) do b[k] = deep_copy(v) end
      ui.patches[slot] = (ui.patches[slot] or 0) + 1
    end,
    clear = function(slot) ui.trees[slot] = nil end,
    title = function(slot, text) ui.titles[slot] = text end,
    badge = function(n) ui.badge = n end,
    dot = function(kind) ui.dot = kind end,
    notify = function(n)
      if type(n) ~= "table" or type(n.text) ~= "string" or #n.text < 1 or #n.text > 300 then error("notify: bad text", 2) end
      if n.title and #n.title > 80 then error("notify: title too long", 2) end
      if n.tone and n.tone ~= "info" and n.tone ~= "important" and n.tone ~= "warning" then error("notify: bad tone", 2) end
      if n.actions and #n.actions > 2 then error("notify: at most 2 actions", 2) end
      ui.notes[#ui.notes + 1] = deep_copy(n)
      return #ui.notes
    end,
    on_action = function(fn) ui.handler = fn end,
  }
  -- uz.ui.open(slot): platform 0.11+ only; opts.no_ui_open leaves it out (older Uzume).
  ui.opened = {}
  if not opts.no_ui_open then
    uz.ui.open = function(slot)
      if slot ~= "screen" and slot ~= "panel" then error("open: slot " .. tostring(slot) .. " not declared", 2) end
      ui.opened[#ui.opened + 1] = slot
      return true
    end
  end
  --- mock.action(action, value, slot) calls the registered uz.ui.on_action handler.
  function mock.action(action, value, slot) return ui.handler(action, deep_copy(value), slot) end

  -- opts.video: fake uz.video (permission video.capture). { screens = list | false (nil), raise = true }
  -- mock.video.requests lists the capture targets; mock.video_result(ok_or_error, png, w, h) answers the
  -- pending request with a `video.captured` host event (ok_or_error = true or an error code).
  if opts.video then
    local v = type(opts.video) == "table" and opts.video or {}
    local screens = v.screens
    if screens == nil then screens = { { name = "top", x = 0, y = 0, w = 400, h = 240 }, { name = "bottom", x = 40, y = 240, w = 320, h = 240 } } end
    mock.video = { requests = {}, next_id = 1 }
    uz.video = {
      screens = function() return screens or nil end,
      capture = function(target)
        if type(target) ~= "string" and type(target) ~= "table" then error("bad capture target", 2) end
        if v.raise then error("capture failed", 2) end
        local id = mock.video.next_id
        mock.video.next_id = id + 1
        mock.video.requests[#mock.video.requests + 1] = { id = id, target = target }
        return id
      end,
    }
    function mock.video_result(res, png, w, h)
      local req = mock.video.requests[#mock.video.requests]
      local ev = { id = req.id, ok = res == true }
      if res == true then ev.png, ev.w, ev.h = png, w, h else ev.error = res end
      mock.fire_event("uz", "video.captured", ev)
    end
  end

  -- uz.save (Uzume 0.20+, no permission): only when opts.save is given, so the default mock is an older app.
  --   opts.save = true | { refuse = "rate limited" }; mock.snapshots lists the reasons passed.
  mock.snapshots = {}
  if opts.save then
    local cfg = type(opts.save) == "table" and opts.save or {}
    uz.save = { snapshot = function(reason)
      if type(reason) ~= "string" or #reason < 1 or #reason > 80 then error("snapshot: reason must be 1 to 80 characters", 2) end
      mock.snapshots[#mock.snapshots + 1] = reason
      if cfg.refuse then
        mock.snapshots[#mock.snapshots] = nil
        mock.snapshot_refusals = (mock.snapshot_refusals or 0) + 1
        return nil, cfg.refuse
      end
      return true
    end }
  end

  uz.cache = {
    write = function(name, data) mock.cache_files[name] = data; return true end,
    read = function(name) return mock.cache_files[name] end,
    exists = function(name) return mock.cache_files[name] ~= nil end,
  }

  uz.clock = function() return now end
  function mock.advance(ms) now = now + ms end
  uz.dev = {
    watch = function(label, addr, kind) mock.dev_watches[label] = { addr = addr, kind = kind } end,
    unwatch = function(label) mock.dev_watches[label] = nil end,
  }

  return mock
end

return M
