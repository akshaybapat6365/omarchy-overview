-- tests/lua/fakehl.lua — a fake `hl` for Lua 5.5 tests of hypr/overview.lua, hypr/input.lua and ops/ovops.lua.
-- It copies the behaviour of Hyprland 0.56.2 that the code relies on (code/src/hyprland, read 2026-11-19):
--  * hl.dsp.workspace.change_id refuses a taken id with a WARNING result { ok = false, error = "...: ID is taken" }
--    (ConfigActions.cpp:1063-1073 via checkResult/pushErrorResult), refuses a missing workspace and ids <= 0;
--    success returns { ok = true, pass_event = false } (pushSuccessResult); windows stay on the renumbered desk.
--  * hl.dsp.window.move{ workspace, follow = false, window = "address:..." } creates the target desk on demand;
--    an empty desk that is not the visible one is destroyed (Hyprland's inert-workspace cleanup).
--  * hl.gesture REPORTS (does not raise) a refused gesture: an axis conflicts with its directions and with
--    "swipe" on the same finger count and mods (TrackpadGestures.cpp:58-92); "unset" of a missing one is refused;
--    accepted callbacks are referenced in the Lua registry, refused ones are not (LuaBindingsConfigRules.cpp:756-963).
-- Failure injection: F.failAt = n makes the n-th dispatch refuse ({ ok = false }), F.lieAt = n makes it answer ok
-- without doing anything; F.tableForm = false refuses table actions; F.raise = true makes hl.gesture raise.
local F = {}

function F.new(opts)
  opts = opts or {}
  local st = { ws = {}, win = {}, visible = nil, dispatches = 0, events = {}, globals = {}, gestures = {},
               errors = {}, regkeys = {}, log = {} }
  F.failAt, F.lieAt, F.tableForm, F.raise = nil, nil, opts.tableForm ~= false, opts.raise or false
  local reg = debug.getregistry()

  local function wsById(id) return st.ws[id] end
  local function newWs(id) local w = { id = id }; st.ws[id] = w; return w end
  local function cleanup()
    for id, w in pairs(st.ws) do
      if w ~= st.visible then
        local n = 0
        for _, c in pairs(st.win) do if c.ws == w then n = n + 1 end end
        if n == 0 then st.ws[id] = nil end
      end
    end
  end

  local hl = { dsp = { workspace = {}, window = {} } }
  function hl.dsp.event(s) return { kind = "event", s = s } end
  function hl.dsp.global(s) return { kind = "global", s = s } end
  function hl.dsp.workspace.change_id(t) return { kind = "change_id", ws = t.workspace, id = t.id } end
  function hl.dsp.window.move(t) return { kind = "move", ws = t.workspace, follow = t.follow, window = t.window } end

  function hl.dispatch(d)
    st.dispatches = st.dispatches + 1
    local n = st.dispatches
    if d.kind == "event" then st.events[#st.events + 1] = d.s; return { ok = true } end
    if d.kind == "global" then st.globals[#st.globals + 1] = d.s; return { ok = true } end
    st.log[#st.log + 1] = d.kind .. " " .. tostring(d.ws) .. " " .. tostring(d.id or d.window)
    if F.failAt == n then return { ok = false, error = "hl.x: injected refusal", level = "warning", code = "unknown" } end
    if F.lieAt == n then return { ok = true, pass_event = false } end
    if d.kind == "change_id" then
      local w = wsById(tonumber(d.ws))
      if not w then return { ok = false, error = "hl.workspace.change_id: no such workspace", level = "warning" } end
      if w.id <= 0 then return { ok = false, error = "hl.workspace.change_id: cannot change id of workspace with a managed id" } end
      if wsById(d.id) then return { ok = false, error = "[string \"chunk\"]:1: ID is taken", level = "warning", code = "invalid_state" } end
      st.ws[w.id] = nil; w.id = d.id; st.ws[d.id] = w
      return { ok = true, pass_event = false }
    elseif d.kind == "move" then
      local addr = tostring(d.window):match("^address:(0x%x+)$")
      local c = addr and st.win[addr]
      if not c then return { ok = false, error = "hl.window.move: no such window" } end
      local id = tonumber(d.ws)
      local target = wsById(id) or newWs(id)
      c.ws = target
      cleanup()
      return { ok = true, pass_event = false }
    end
    return { ok = false, error = "unknown dispatcher" }
  end

  function hl.get_workspaces()
    local out = {}
    for _, w in pairs(st.ws) do out[#out + 1] = { id = w.id, special = w.id <= 0, name = tostring(w.id) } end
    return out
  end
  function hl.get_workspace(sel)
    local w = wsById(tonumber(sel))
    return w and { id = w.id, special = w.id <= 0 } or nil
  end
  function hl.get_window(sel)
    local addr = tostring(sel):match("^address:(0x%x+)$")
    local c = addr and st.win[addr]
    if not c then return nil end
    return { address = addr, pinned = c.pinned or false, class = c.class, workspace = { id = c.ws.id } }
  end

  local AXIS = { up = "vertical", down = "vertical", vertical = "vertical", left = "horizontal", right = "horizontal",
                 horizontal = "horizontal", swipe = "swipe", pinch = "pinch", pinchin = "pinch", pinchout = "pinch" }
  local function refuse(msg) st.errors[#st.errors + 1] = "hl.gesture: " .. msg end
  function hl.gesture(spec)
    if F.raise then error("hl.gesture: simulated raise") end
    local dir, mods, fingers = spec.direction, spec.mods or "", spec.fingers
    if not AXIS[dir] then return refuse("invalid direction") end
    if spec.action == "unset" then
      for i, g in ipairs(st.gestures) do
        if g.fingers == fingers and g.direction == dir and g.mods == mods then table.remove(st.gestures, i); return end
      end
      return refuse("Can't remove a non-existent gesture")
    end
    local a = spec.action
    local fns = {}
    if type(a) == "function" then fns = { a }
    elseif type(a) == "table" then
      if not F.tableForm then return refuse("unknown action") end
      for _, k in ipairs({ "start", "update", "finish" }) do
        if a[k] ~= nil and type(a[k]) ~= "function" then return refuse("action." .. k .. " must be a function") end
        if a[k] then fns[#fns + 1] = a[k] end
      end
      if #fns == 0 then return refuse("action callback table must define at least one of start, update, end, or finish") end
    elseif type(a) ~= "string" then return refuse("missing required field \"action\"") end
    local axis = AXIS[dir]
    for _, g in ipairs(st.gestures) do
      if g.fingers == fingers and g.mods == mods then
        local ga = g.direction
        if ga == axis or ga == dir or ((axis == "vertical" or axis == "horizontal") and ga == "swipe") then
          return refuse("Gesture will be overshadowed by a previous gesture. Previous " .. ga .. " shadows new " .. dir)
        end
      end
    end
    st.gestures[#st.gestures + 1] = { fingers = fingers, direction = dir, mods = mods, action = a,
                                      kind = type(a) == "table" and "table" or type(a) }
    for _, fn in ipairs(fns) do local k = {}; reg[k] = fn; st.regkeys[#st.regkeys + 1] = k end
  end
  -- Hyprland's require() (ConfigManager.cpp safeLuaRequire): "not found" raises; a module that fails to load or
  -- raises is put in the error list (the banner) and an empty table is returned and cached instead.
  function st.safeRequire(name)
    if package.loaded[name] ~= nil then return package.loaded[name] end
    local path = package.searchpath(name, package.path)
    if not path then error("module '" .. name .. "' not found", 2) end
    local chunk, err = loadfile(path)
    local ok, mod = chunk ~= nil, nil
    if chunk then ok, mod = pcall(chunk) end
    if not ok then
      st.errors[#st.errors + 1] = 'require("' .. name .. '"): ' .. tostring(err or mod)
      package.loaded[name] = {}
      return package.loaded[name]
    end
    package.loaded[name] = mod == nil and true or mod
    return package.loaded[name]
  end
  function hl.config() end
  function hl.device() end

  -- test helpers
  function st.addDesk(id, visible) local w = newWs(id); if visible then st.visible = w end; return w end
  function st.addWindow(addr, desk, pinned)
    local w = wsById(desk) or newWs(desk)
    st.win[addr] = { ws = w, pinned = pinned }
  end
  function st.ids()
    local out = {}
    for id in pairs(st.ws) do out[#out + 1] = id end
    table.sort(out)
    return out
  end
  function st.deskOf(addr) return st.win[addr].ws.id end
  function st.snapshot()     -- address -> desk, plus the id list, as one comparable string
    local a = {}
    for addr, c in pairs(st.win) do a[#a + 1] = addr .. "=" .. c.ws.id end
    table.sort(a)
    return table.concat(st.ids(), ",") .. "|" .. table.concat(a, ",")
  end
  function st.release()     -- drop the registry entries this fake made
    for _, k in ipairs(st.regkeys) do reg[k] = nil end
    st.regkeys = {}
  end
  function st.find(fingers, dir)
    for _, g in ipairs(st.gestures) do if g.fingers == fingers and g.direction == dir then return g end end
  end
  st.hl = hl
  return st
end

return F
