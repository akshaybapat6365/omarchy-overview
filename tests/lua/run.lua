-- tests/lua/run.lua — lane 1 fast tests (SPEC 4.2 lane 1 (a), addendum L3/L6, amendment A1). Lua 5.5, no stage.
-- Run from the tree: lua tests/lua/run.lua        (exit 0 = every check passed)
assert(_VERSION == "Lua 5.5", "run these with Lua 5.5 (the version Hyprland links), not " .. _VERSION)
local ROOT = (arg and arg[0] or ""):match("^(.*)/tests/lua/run%.lua$") or "."
package.path = ROOT .. "/tests/lua/?.lua;" .. package.path
local F = require("fakehl")

local pass, fail = 0, 0
local function check(cond, what)
  if cond then pass = pass + 1; print("ok   " .. what) else fail = fail + 1; print("FAIL " .. what) end
end
local function section(s) print("-- " .. s) end
local function withHl(st, fn)              -- run fn with st.hl as the global hl
  local old = rawget(_G, "hl"); _G.hl = st.hl
  local ok, err = pcall(fn)
  _G.hl = old
  if not ok then error(err, 0) end
end
local function loadOverview(st, path)   -- leaves st.hl as the global hl: the handlers use it when called
  _G.hl = st.hl
  return dofile(path or (ROOT .. "/hypr/overview.lua"))
end

-- ===================================================================================================
section("overview.lua: registration (A1)")
do
  local st = F.new()
  local M = loadOverview(st)
  check(M.mode == "stream", "mode stream, got " .. tostring(M.mode))
  check(M.byFingers[3] == "stream" and M.byFingers[4] == "stream", "3 and 4 fingers stream")
  local g3, g4 = st.find(3, "vertical"), st.find(4, "vertical")
  check(g3 and g3.kind == "table" and g3.action.finish and g3.action.start and g3.action.update, "3 vertical table form with start/update/finish")
  check(g4 and g4.kind == "table", "4 vertical table form")
  check(#st.errors == 0, "no config error: " .. table.concat(st.errors, "; "))
  check(st.events[#st.events] == "ovg,hello", "hello sent")
  st.release()

  -- Table form refused (an older or changed Hyprland): one-shot pairs instead, no process started.
  st = F.new({ tableForm = false })
  M = loadOverview(st)
  check(M.mode == "legacy", "table form refused -> legacy, got " .. tostring(M.mode))
  for _, f in ipairs({ 3, 4 }) do
    local up, down = st.find(f, "up"), st.find(f, "down")
    check(up and up.kind == "function" and down and down.kind == "function", f .. " fingers up/down one-shots")
    withHl(st, function() up.action(); down.action() end)
  end
  check(st.globals[1] == "omarchy-overview:toggle" and st.globals[2] == "omarchy-overview:close", "one-shots send hl.dsp.global toggle/close")
  st.release()

  -- hl.gesture raises: nothing registers, the module still loads and never raises.
  st = F.new({ raise = true })
  local ok, M2 = pcall(loadOverview, st)
  check(ok and M2 and M2.mode == "none", "hl.gesture raising -> module loads, mode none")
  st.release()

  -- A vertical gesture already there for 3 fingers: refused (reported, not raised), detected per finger count;
  -- the one-shots are refused too (an axis shadows its directions), so 3 fingers keep what was there.
  st = F.new()
  withHl(st, function() hl.gesture({ fingers = 3, direction = "vertical", action = function() end }) end)
  M = loadOverview(st)
  check(M.byFingers[3] == "none" and M.byFingers[4] == "stream" and M.mode == "legacy", "refusal detected per finger count (3 none, 4 stream)")
  check(#st.errors == 3, "a refused gesture is reported, not raised (3 reports: vertical, up, down)")
  st.release()

  -- The old 3-finger up/down lines still present: Hyprland's check is one-sided (TrackpadGestures.cpp:82 compares
  -- the EARLIER gesture's direction with the new one's axis), so vertical is accepted after up/down, and the
  -- earlier up/down win every stroke (first match). Nothing breaks; the strokes stay one-shot.
  st = F.new()
  withHl(st, function()
    hl.gesture({ fingers = 3, direction = "up", action = function() end })
    hl.gesture({ fingers = 3, direction = "down", action = function() end })
  end)
  M = loadOverview(st)
  check(M.byFingers[3] == "stream" and #st.errors == 0 and st.gestures[1].direction == "up", "vertical after up/down: accepted, no report, up/down stay first")
  st.release()
end

-- ===================================================================================================
section("overview.lua: stream format (recorded rig sample replayed through the handlers)")
local function parseSample(path)
  local strokes, cur = {}, nil
  for line in io.lines(path) do
    local kind, t = line:match("GESTURE_SWIPE_(%u+)%s+%d*%s*%+(%d+%.%d+)s")
    if kind == "BEGIN" then cur = { t0 = tonumber(t), ups = {} }
    elseif kind == "UPDATE" and cur then
      local dx, dy = line:match("%+%d+%.%d+s\t%d+%s+(%-?%d+%.%d+)/%s*(%-?%d+%.%d+)")
      cur.ups[#cur.ups + 1] = { t = tonumber(t), dx = tonumber(dx), dy = tonumber(dy) }
    elseif kind == "END" and cur then
      cur.t1, cur.cancelled = tonumber(t), line:find("cancelled") ~= nil
      if #cur.ups > 0 then strokes[#strokes + 1] = cur end
      cur = nil
    end
  end
  return strokes
end
local BASE_MS = 158725363
local function ms(t) return BASE_MS + math.floor(t * 1000 + 0.5) end
local function replay(M, s, fingers)
  local u1 = s.ups[1]
  local dir = u1.dy < 0 and "UP" or "DOWN"
  M.handlers.start({ phase = "start", direction = dir, type = "swipe", fingers = fingers, time_ms = ms(u1.t), delta = { x = u1.dx, y = u1.dy } })
  for _, u in ipairs(s.ups) do
    M.handlers.update({ phase = "update", direction = dir, type = "swipe", fingers = fingers, time_ms = ms(u.t), delta = { x = u.dx, y = u.dy } })
  end
  M.handlers.finish({ phase = "end", direction = dir, type = "swipe", time_ms = ms(s.t1), cancelled = s.cancelled })
end
do
  local sample = ROOT .. "/tests/lua/recorded-rig-g2_swipe_mac.txt"   -- copy of gestures/samples/ (libinput 1.32 log)
  local strokes = parseSample(sample)
  check(#strokes > 200, "sample parsed: " .. #strokes .. " strokes")
  local st = F.new()
  local M = loadOverview(st)
  local first = #st.events + 1
  local nUpdates = 0
  for i, s in ipairs(strokes) do replay(M, s, i % 2 == 0 and 4 or 3); nUpdates = nUpdates + #s.ups end
  local okFmt, b, e, u, badGap, order = true, 0, 0, 0, 0, true
  local open, lastT = false, nil
  for i = first, #st.events do
    local ev = st.events[i]
    if ev:match("^ovg,b,[34],[%u]+,0%.00,%d+$") then
      b = b + 1; if open then order = false end; open = true; lastT = tonumber(ev:match(",(%d+)$"))
    elseif ev:match("^ovg,u,%-?%d+%.%d%d,%d+$") then
      u = u + 1; if not open then order = false end
      local t = tonumber(ev:match(",(%d+)$")); if t - lastT < 12 then badGap = badGap + 1 end; lastT = t
    elseif ev:match("^ovg,e,%-?%d+%.%d%d,%d+,[01]$") then
      e = e + 1; if not open then order = false end; open = false
    else okFmt = false; print("  bad event: " .. ev) end
  end
  check(okFmt, "every event matches the frozen format")
  check(b == #strokes and e == #strokes, ("exactly one b and one e per stroke (%d strokes, b %d, e %d)"):format(#strokes, b, e))
  check(order, "b ... u ... e order inside every stroke")
  check(badGap == 0, "no two progress events of a stroke closer than 12 ms (" .. badGap .. " too close)")
  check(M.stats.updates == nUpdates and M.stats.errors == 0, "every update handled, none failed")
  print(("  %d strokes, %d updates in, %d u out (%.0f%%)"):format(#strokes, nUpdates, u, 100 * u / nUpdates))

  -- Injected errors are swallowed: a malformed table, a nil event, a dispatcher that raises.
  local before = M.stats.errors
  local ok = pcall(function()
    M.handlers.update({ phase = "update", time_ms = 1 })      -- no delta
    M.handlers.start(nil)
    local d = st.hl.dispatch; st.hl.dispatch = function() error("boom") end
    M.handlers.finish({ phase = "end", time_ms = 5, cancelled = false })
    st.hl.dispatch = d
  end)
  check(ok and M.stats.errors == before + 3, "injected errors swallowed and counted (" .. (M.stats.errors - before) .. ")")
  st.release()
end

-- ===================================================================================================
section("overview.lua: finger distance (addendum L6, 8 ms frames as measured)")
do
  local st = F.new()
  local M = loadOverview(st)
  local function gain(v)    -- the formula, independently of the module's table
    local f = v < 7 and (0.1 * v + 0.3) / 0.9 or v <= 130 and 1 or 1 + 0.0025 * (math.min(v, 520) / 130) * (math.min(v, 520) - 130) / 0.9
    return 24.75 * f
  end
  local function lastE() local ev = st.events[#st.events]; return tonumber(ev:match("^ovg,e,(%-?[%d.]+),")), ev end
  local cases = { { 20, 236, -933.6, 37.8 }, { 40, 118, -933.6, 37.8 }, { 80, 58, -925.4, 37.1 },
                  { 150, 31, -993.5, 37.2 }, { 300, 15, -1773.1, 36.0 }, { 500, 8, -3916.2, 32.0 } }
  for _, c in ipairs(cases) do
    local v, n, sum, want = c[1], c[2], c[3], c[4]
    local t = 1000
    M.handlers.start({ direction = "UP", fingers = 3, time_ms = t, delta = { x = 0, y = sum / n } })
    for _ = 1, n do M.handlers.update({ direction = "UP", fingers = 3, time_ms = t, delta = { x = 0, y = sum / n } }); t = t + 8 end
    M.handlers.finish({ direction = "UP", time_ms = t, cancelled = false })
    local got = lastE()
    local err = math.abs(got - want) / want
    check(err <= 0.08, ("%3d mm/s: %d updates, sum %.1f -> %.2f mm, measured %.1f (%.1f%%)"):format(v, n, sum, got, want, 100 * err))
    print(("  %3d mm/s: %.2f mm vs %.1f measured (%.1f%% off); gain at that speed %.1f units/mm (formula %.1f)")
      :format(v, got, want, 100 * err, M.gainAt(math.abs(sum / n) / 8), gain(v)))
  end
  -- Mixed stroke: 40 mm up in 400 ms, 150 ms rest, 15 mm back in 200 ms (addendum L6/L4), 8 ms frames.
  local t, ups, sum, maxGap, lastT = 5000, 0, 0, 0, nil
  local function frame(dmm, v)
    local dy = -dmm * gain(v)
    if lastT then maxGap = math.max(maxGap, t - lastT) end; lastT = t
    M.handlers.update({ direction = "UP", fingers = 3, time_ms = t, delta = { x = 0, y = dy } }); ups = ups + 1; sum = sum + dy
  end
  M.handlers.start({ direction = "UP", fingers = 3, time_ms = t, delta = { x = 0, y = -0.8 * gain(100) } })
  local nEvBefore = #st.events
  for _ = 1, 50 do frame(0.8, 100); t = t + 8 end
  local beforeRest = #st.events
  t = t + 150                                     -- resting fingers: no event at all
  check(#st.events == beforeRest, "nothing is sent while the fingers rest")
  for _ = 1, 25 do frame(-0.6, 75); t = t + 8 end
  M.handlers.finish({ direction = "UP", time_ms = t, cancelled = false })
  local got, ev = lastE()
  check(math.abs(got - 25) / 25 <= 0.08, ("mixed stroke ends at %.2f mm (25 expected): %s"):format(got, ev))
  local b = st.events[nEvBefore]
  check(b:match("^ovg,b,3,UP,0%.00,"), "direction stays UP for the whole mixed stroke: " .. b)
  print(("  mixed: %d updates, sum %.1f, largest gap %d ms, final %.2f mm"):format(ups, sum, maxGap, got))
  -- Handler cost: 100k updates, budget 0.2 ms each (SPEC 3.7).
  local c0 = os.clock()
  M.handlers.start({ direction = "UP", fingers = 3, time_ms = 0, delta = { x = 0, y = -5 } })
  for i = 1, 100000 do M.handlers.update({ direction = "UP", fingers = 3, time_ms = i * 7, delta = { x = 1, y = -5 } }) end
  local per = (os.clock() - c0) / 100000 * 1000
  check(per < 0.2, ("update handler %.4f ms each (budget 0.2)"):format(per))
  print(("  update handler: %.4f ms each, including the event string (fake dispatch)"):format(per))
  st.release()
end

-- ===================================================================================================
section("input.lua: the module, a missing module, a broken module (A1)")
do
  local tmp = os.tmpname(); os.remove(tmp)
  local dirs = { broken = tmp .. "-broken", raising = tmp .. "-raising", empty = tmp .. "-empty" }
  for _, d in pairs(dirs) do os.execute("mkdir -p '" .. d .. "/hypr'") end
  local fh = io.open(dirs.broken .. "/hypr/overview.lua", "w"); fh:write("local M = {\nreturn M  -- syntax error\n"); fh:close()
  fh = io.open(dirs.raising .. "/hypr/overview.lua", "w"); fh:write("error('broken on purpose')\n"); fh:close()
  local function loadInput(path)
    local st = F.new()
    local oldPath, oldO = package.path, rawget(_G, "o")
    package.path = path .. "/?.lua"      -- only that folder: as on his machine, nothing else to find
    package.loaded["hypr.overview"] = nil
    _G.o = { window = function() end }
    local oldRequire = require
    _G.require = st.safeRequire                 -- as in Hyprland: a broken module does not raise
    local ok, err = pcall(withHl, st, function() dofile(ROOT .. "/hypr/input.lua") end)
    package.path, _G.o, _G.require = oldPath, oldO, oldRequire
    local mod = package.loaded["hypr.overview"]
    package.loaded["hypr.overview"] = nil
    return st, ok, err, mod
  end
  local expectAlways = { { 3, "horizontal" }, { 3, "pinchout" }, { 4, "left" }, { 4, "right" }, { 4, "pinchin" }, { 4, "pinchout" }, { 5, "swipe" } }
  local function always(st, tag)
    for _, g in ipairs(expectAlways) do check(st.find(g[1], g[2]), tag .. ": " .. g[1] .. " " .. g[2] .. " still registered") end
  end
  local st, ok, err, mod = loadInput(ROOT)
  check(ok, "input.lua with the module loads: " .. tostring(err))
  check(mod and mod.mode == "stream", "module mode stream")
  check(st.find(3, "vertical") and st.find(4, "vertical") and not st.find(3, "up") and not st.find(4, "down"), "vertical streams, no one-shots")
  check(#st.errors == 0, "no config error with the module: " .. table.concat(st.errors, "; "))
  always(st, "module"); st.release()
  for _, case in ipairs({ { "missing", dirs.empty }, { "syntax error", dirs.broken }, { "raises on load", dirs.raising } }) do
    st, ok, err, mod = loadInput(case[2])
    check(ok, case[1] .. ": input.lua still loads: " .. tostring(err))
    for _, f in ipairs({ 3, 4 }) do
      local up, down = st.find(f, "up"), st.find(f, "down")
      check(up and down and up.kind == "function", case[1] .. ": " .. f .. " fingers up/down one-shots registered")
    end
    check(not st.find(3, "vertical"), case[1] .. ": no vertical stream")
    check(#st.errors == 0, case[1] .. ": no config error (" .. table.concat(st.errors, "; ") .. ")")
    always(st, case[1])
    withHl(st, function() st.find(3, "up").action(); st.find(4, "down").action() end)
    check(st.globals[1] == "omarchy-overview:toggle" and st.globals[2] == "omarchy-overview:close", case[1] .. ": one-shots reach the overview through hl.dsp.global")
    st.release()
  end
  -- Why input.lua cannot use pcall(require, ...): with Hyprland's require a broken module never raises.
  local st2 = F.new()
  local oldPath = package.path
  package.path = dirs.broken .. "/?.lua"
  package.loaded["hypr.overview"] = nil
  local okReq, mod2 = pcall(st2.safeRequire, "hypr.overview")
  package.path = oldPath
  package.loaded["hypr.overview"] = nil
  check(okReq and type(mod2) == "table" and next(mod2) == nil and #st2.errors == 1,
        "Hyprland-style require of a broken module: no error to catch, an empty table and a banner entry (so input.lua loads by hand)")
  for _, d in pairs(dirs) do os.execute("rm -rf '" .. d .. "'") end
end

-- ===================================================================================================
section("ovops.lua: reorder, move, insert, newdesk, heal against the fake (change_id refuses taken ids)")
local OPS = ROOT .. "/ops/ovops.lua"
local function world(ids, active)
  local st = F.new()
  for i, id in ipairs(ids) do st.addDesk(id, id == (active or ids[1])); st.addWindow(("0x%x"):format(0xa0 + i), id) end
  return st
end
local function ops(st)
  local before = {}
  for k in pairs(_G) do before[k] = true end
  local O
  withHl(st, function() O = dofile(OPS) end)
  for k in pairs(_G) do if not before[k] then check(false, "ovops.lua made a global: " .. k) end end
  return O
end
local function call(st, O, fn, ...)
  local args, r = table.pack(...)
  withHl(st, function() r = O[fn](table.unpack(args, 1, args.n)) end)
  return r
end
local function perms(list)
  local out = {}
  local function rec(a, n)
    if n <= 1 then out[#out + 1] = table.move(a, 1, #a, 1, {}) return end
    for i = 1, n do a[n], a[i] = a[i], a[n]; rec(a, n - 1); a[n], a[i] = a[i], a[n] end
  end
  rec(table.move(list, 1, #list, 1, {}), #list)
  return out
end
-- After reorder(order): the desk that had id order[i] now has id S[i]; its window went with it.
local function expected(ids, order)
  local m = {}
  for i, old in ipairs(order) do m[("0x%x"):format(0xa0 + (function() for j, v in ipairs(ids) do if v == old then return j end end end)())] = ids[i] end
  local a = {}
  for addr, d in pairs(m) do a[#a + 1] = addr .. "=" .. d end
  table.sort(a)
  return table.concat(ids, ",") .. "|" .. table.concat(a, ",")
end
do
  local O = ops(F.new())
  local lines = 0; for _ in io.lines(OPS) do lines = lines + 1 end
  check(lines <= 220, "ovops.lua is " .. lines .. " lines (<= 220; SPEC said 200, the bar's empty desks added 15)")

  for _, ids in ipairs({ { 1, 2, 3, 4, 5, 6 }, { 1, 2, 4, 7 } }) do
    local all, okAll, failRestored, failCount, steps = perms(ids), 0, 0, 0, 0
    for _, order in ipairs(all) do
      local st = world(ids); O = ops(st)
      local r = call(st, O, "reorder", order)
      if r:match("^ok") and st.snapshot() == expected(ids, order) then okAll = okAll + 1
      else print("  reorder " .. table.concat(order, " ") .. " -> " .. r .. " / " .. st.snapshot()) end
      local n = st.dispatches
      steps = math.max(steps, n)
      -- the same reorder with a refusal, then with a silent no-op, injected at every step
      for k = 1, n do
        for _, mode in ipairs({ "failAt", "lieAt" }) do
          local s2 = world(ids); local O2 = ops(s2)
          local start = s2.snapshot()
          F[mode] = k
          local r2 = call(s2, O2, "reorder", order)
          F.failAt, F.lieAt = nil, nil
          failCount = failCount + 1
          if r2:match("^fail," .. k .. ",") and s2.snapshot() == start then failRestored = failRestored + 1
          else print(("  %s %d on %s -> %s / %s"):format(mode, k, table.concat(order, " "), r2, s2.snapshot())) end
        end
      end
    end
    check(okAll == #all, ("reorder: all %d permutations of {%s} end correct (%d)"):format(#all, table.concat(ids, ","), okAll))
    check(failRestored == failCount, ("reorder: failure injected at every step (%d cases, refusal and silent no-op) restores the start exactly (%d)"):format(failCount, failRestored))
  end

  -- "2 to 5" on desks 1-6, the worked example of SPEC 3.4.
  local st = world({ 1, 2, 3, 4, 5, 6 }); O = ops(st)
  local r = call(st, O, "reorder", { 1, 3, 4, 5, 2, 6 })
  check(r == 'ok,{"steps":8,"ids":[1,2,3,4,5,6]}', "2 to 5 reply: " .. r)
  check(table.concat(st.log, ";") == "change_id 3 100002;change_id 4 100003;change_id 5 100004;change_id 2 100005;change_id 100002 2;change_id 100003 3;change_id 100004 4;change_id 100005 5", "2 to 5 steps as SPEC 3.4: " .. table.concat(st.log, ";"))
  check(st.deskOf("0xa2") == 5 and st.deskOf("0xa3") == 2 and st.deskOf("0xa5") == 4 and st.deskOf("0xa1") == 1 and st.deskOf("0xa6") == 6, "2 to 5: old 2 -> 5, old 3 -> 2, old 5 -> 4, 1 and 6 untouched")

  -- A pre-occupied temp id: refused before anything changes.
  st = world({ 1, 2, 3, 100002 }); O = ops(st)
  local start = st.snapshot()
  r = call(st, O, "reorder", { 1, 3, 2, 100002 })
  check(r == "fail,0,temp-taken" and st.snapshot() == start and st.dispatches == 0, "a desk on a temporary id: refused before anything changes: " .. r)
  st = world({ 1, 2, 3, 4 }); O = ops(st); start = st.snapshot()
  for _, bad in ipairs({ { 1, 2, 3 }, { 1, 2, 3, 3 }, { 1, 2, 3, 5 }, { 1, 2, 3, "4" }, { 1, 2, 3, 4.5 }, "1,2,3,4" }) do
    r = call(st, O, "reorder", bad)
    check(r == "fail,0,invalid" and st.snapshot() == start, "malformed order refused: " .. tostring(type(bad) == "table" and table.concat(bad, " ") or bad))
  end
  r = call(st, O, "reorder", { 1, 2, 3, 4 })
  check(r == 'ok,{"steps":0,"ids":[1,2,3,4]}' and st.dispatches == 0, "identity reorder changes nothing: " .. r)

  -- move / newdesk
  st = world({ 1, 2, 3 }); st.addWindow("0xbeef", 2, true); O = ops(st)
  check(call(st, O, "move", "0xa1", 3) == 'ok,{"steps":1,"desk":3}' and st.deskOf("0xa1") == 3, "move 0xa1 to 3")
  check(call(st, O, "move", "0xa2", 2) == 'ok,{"steps":0}', "move to its own desk is a no-op")
  check(call(st, O, "move", "0xbeef", 1) == "fail,0,pinned" and st.deskOf("0xbeef") == 2, "pinned window refused")
  check(call(st, O, "move", "0xdead", 1) == "fail,0,no-window", "missing window refused")
  check(call(st, O, "move", "title with spaces", 1) == "fail,0,no-window", "malformed address refused")
  check(call(st, O, "move", "0xa2", 0) == "fail,0,invalid" and call(st, O, "move", "0xa2", 100001) == "fail,0,invalid", "desk 0 and temp-range desks refused")
  F.failAt = st.dispatches + 1
  check(call(st, O, "move", "0xa2", 1):match("^fail,1,refused$") and st.deskOf("0xa2") == 2, "a refused move reports fail,1 and nothing changed")
  F.failAt = nil
  F.lieAt = st.dispatches + 1
  check(call(st, O, "move", "0xa2", 1) == "fail,1,not-applied" and st.deskOf("0xa2") == 2, "a move that silently did nothing is caught by lookup")
  F.lieAt = nil
  st = world({ 1, 2, 4, 7 }); O = ops(st)
  r = call(st, O, "newdesk", "0xa1")
  check(r == 'ok,{"steps":1,"desk":8}' and st.deskOf("0xa1") == 8, "newdesk -> max+1 (8): " .. r)

  -- insert: a free number between the neighbours first, else the run moves up by one.
  st = world({ 1, 2, 4, 7 }); st.addWindow("0xc0", 1); O = ops(st)
  r = call(st, O, "insert", 2, 4, "0xc0")
  check(r == 'ok,{"steps":1,"desk":3}' and st.deskOf("0xc0") == 3 and table.concat(st.ids(), ",") == "1,2,3,4,7", "insert 2|4 uses the free 3, nothing renumbered: " .. r)
  st = world({ 1, 2, 4, 7 }); st.addWindow("0xc0", 1); O = ops(st)
  r = call(st, O, "insert", 1, 2, "0xc0")
  check(r:match('^ok,{"steps":2,"desk":2') and st.deskOf("0xc0") == 2 and st.deskOf("0xa2") == 3 and st.deskOf("0xa3") == 4 and st.deskOf("0xa4") == 7,
        "insert 1|2 on {1,2,4,7}: old 2 -> 3, window on the new 2, 4 and 7 untouched: " .. r .. " " .. st.snapshot())
  st = world({ 1, 2, 3, 4, 5, 6 }); st.addWindow("0xc0", 6); O = ops(st)
  r = call(st, O, "insert", 1, 2, "0xc0")
  check(r == 'ok,{"steps":6,"desk":2,"ids":[1,2,3,4,5,6,7]}' and st.deskOf("0xc0") == 2 and st.deskOf("0xa2") == 3 and st.deskOf("0xa6") == 7,
        "insert 1|2 on 1-6: 2..6 move up by one, top first: " .. r)
  st = world({ 1, 2, 3 }); st.addWindow("0xc0", 3); O = ops(st)
  r = call(st, O, "insert", 3, nil, "0xc0")
  check(r == 'ok,{"steps":1,"desk":4}' and st.deskOf("0xc0") == 4, "insert after the last -> next number: " .. r)
  st = world({ 1, 2, 3 }); st.addWindow("0xc0", 3); O = ops(st)
  r = call(st, O, "insert", 0, 1, "0xc0")
  check(r:match('^ok,{"steps":4,"desk":1') and st.deskOf("0xc0") == 1 and st.deskOf("0xa1") == 2, "insert before the first: " .. r)
  local insFail, insCases = 0, 0
  for k = 1, 6 do
    for _, mode in ipairs({ "failAt", "lieAt" }) do
      st = world({ 1, 2, 3, 4, 5, 6 }); st.addWindow("0xc0", 6); O = ops(st); start = st.snapshot()
      F[mode] = k
      r = call(st, O, "insert", 1, 2, "0xc0")
      F.failAt, F.lieAt = nil, nil
      insCases = insCases + 1
      if r:match("^fail," .. k .. ",") and st.snapshot() == start then insFail = insFail + 1 else print("  insert " .. mode .. " " .. k .. " -> " .. r .. " " .. st.snapshot()) end
    end
  end
  check(insFail == insCases, ("insert: failure injected at each of its 6 steps restores the start exactly (%d/%d)"):format(insFail, insCases))
  check(call(world({ 1, 2 }), O, "insert", 2, 1, "0xa1") == "fail,0,invalid", "insert with right <= left refused")

  -- Omarchy's per-desk layouts (review: compositor, major): a reorder or a shifting insert that would change which
  -- desk holds a number with a layout of its own is refused before anything changes; one that does not touch it runs.
  local function withLayouts(st, layouts, floatingDesks)
    local get = st.hl.get_workspace
    st.hl.get_config = function(k) if k == "general.layout" then return "dwindle" end end
    st.hl.get_workspace = function(sel) local w = get(sel); if w then w.tiled_layout = layouts[w.id] or "dwindle" end; return w end
    st.hl.get_windows = function(f)
      local out = {}
      if f and f.tag == "omarchy-floating-workspace" then for _, d in ipairs(floatingDesks or {}) do out[#out + 1] = { workspace = { id = d } } end end
      return out
    end
    return st
  end
  st = withLayouts(world({ 1, 2, 3, 4, 5, 6 }), { [2] = "scrolling" }); O = ops(st)
  local start = st.snapshot()
  r = call(st, O, "reorder", { 1, 3, 4, 5, 2, 6 })
  check(r == "fail,0,desk-layout-2" and st.snapshot() == start and st.dispatches == 0, "2 to 5 with desk 2 scrolling: refused, nothing changed: " .. r)
  r = call(st, O, "reorder", { 1, 2, 4, 3, 5, 6 })
  check(r:match("^ok") ~= nil and st.deskOf("0xa3") == 4, "a reorder that leaves desk 2 alone still runs: " .. r)
  st = withLayouts(world({ 1, 2, 3, 4, 5, 6 }), {}, { 4 }); O = ops(st); start = st.snapshot()
  r = call(st, O, "reorder", { 1, 3, 4, 5, 2, 6 })
  check(r == "fail,0,desk-layout-4" and st.snapshot() == start, "a floating-mode desk (tagged windows) is guarded too: " .. r)
  st = withLayouts(world({ 1, 2, 3 }), { [3] = "scrolling" }); O = ops(st); start = st.snapshot()
  r = call(st, O, "insert", 1, 2, "0xa1")
  check(r == "fail,0,desk-layout-3" and st.snapshot() == start, "an insert that shifts a scrolling desk is refused: " .. r)
  st = withLayouts(world({ 1, 3, 4 }), { [3] = "scrolling" }); O = ops(st)
  r = call(st, O, "insert", 1, 3, "0xa1")
  check(r:match("^ok") ~= nil and st.deskOf("0xa1") == 2, "an insert into a free number shifts nothing and runs: " .. r)

  -- When the runtime exposes hl.workspace_rule, custom tiled layouts (e.g., scrolling) travel with their desk.
  do
    local liveLayouts = { [2] = "scrolling" }
    local st2 = withLayouts(world({ 1, 2, 3, 4, 5, 6 }), liveLayouts)
    st2.hl.workspace_rule = function(spec)
      local id = tonumber(spec.workspace)
      if id then liveLayouts[id] = spec.layout end
    end
    local O2 = ops(st2)
    r = call(st2, O2, "reorder", { 1, 3, 4, 5, 2, 6 })
    check(r:match("^ok") ~= nil and st2.deskOf("0xa2") == 5 and liveLayouts[5] == "scrolling" and liveLayouts[2] == "dwindle",
          "2 to 5 with desk 2 scrolling migrates scrolling to desk 5 and resets desk 2 to dwindle: " .. r)
  end

  -- The bar's desks (empty ones included) as positions: reorder(order, positions) and insert(..., last).
  -- A world with gaps: windows 0xa1.. sit one per existing desk, in the order given.
  local function gapWorld(ids, active)
    local st = F.new()
    for i, id in ipairs(ids) do st.addDesk(id, id == (active or ids[1])); st.addWindow(("0x%x"):format(0xa0 + i), id) end
    return st
  end
  -- Expected after reorder(order, P): the desk that had id order[i] (if any) now has P[i].
  local function expectedP(ids, P, order)
    local to, a, now = {}, {}, {}
    for i, o in ipairs(order) do to[o] = P[i] end
    for j, id in ipairs(ids) do local d = to[id] or id; a[#a + 1] = ("0x%x"):format(0xa0 + j) .. "=" .. d; now[#now + 1] = d end
    table.sort(a); table.sort(now)
    return table.concat(now, ",") .. "|" .. table.concat(a, ",")
  end
  local G, P6 = { 1, 2, 3, 5, 6 }, { 1, 2, 3, 4, 5, 6 }
  st = gapWorld(G); O = ops(st)
  r = call(st, O, "reorder", { 1, 3, 4, 5, 2, 6 }, P6)
  check(r:match("^ok") and st.snapshot() == expectedP(G, P6, { 1, 3, 4, 5, 2, 6 }) and table.concat(st.ids(), ",") == "1,2,4,5,6",
        "2 to 5 over the gap at 4: old 3 -> 2, the gap -> 3, old 5 -> 4, old 2 -> 5; 1 and 6 untouched: " .. r .. " " .. st.snapshot())
  r = call(st, O, "reorder", { 1, 5, 2, 3, 4, 6 }, P6)
  check(r:match("^ok") and st.snapshot() == gapWorld(G).snapshot(), "and 5 back to 2: the start exactly, the gap back on 4: " .. r)
  do
    local all, okAll, failCount, failOk = perms(P6), 0, 0, 0
    for _, order in ipairs(all) do
      local s1 = gapWorld(G); local O1 = ops(s1)
      local r1 = call(s1, O1, "reorder", order, P6)
      if r1:match("^ok") and s1.snapshot() == expectedP(G, P6, order) then okAll = okAll + 1 else print("  gap reorder " .. table.concat(order, " ") .. " -> " .. r1) end
      for k = 1, s1.dispatches do
        for _, mode in ipairs({ "failAt", "lieAt" }) do
          local s2 = gapWorld(G); local O2 = ops(s2); local start = s2.snapshot()
          F[mode] = k; local r2 = call(s2, O2, "reorder", order, P6); F.failAt, F.lieAt = nil, nil
          failCount = failCount + 1
          if r2:match("^fail," .. k .. ",") and s2.snapshot() == start then failOk = failOk + 1 end
        end
      end
    end
    check(okAll == #all, ("reorder over positions 1-6 with desk 4 empty: all %d permutations end as the picture (%d)"):format(#all, okAll))
    check(failOk == failCount, ("... failure injected at every step restores the start exactly (%d/%d)"):format(failOk, failCount))
  end
  st = gapWorld({ 1, 2, 3 }); O = ops(st)
  r = call(st, O, "reorder", { 1, 2, 3, 5, 4 }, { 1, 2, 3, 4, 5 })
  check(r == 'ok,{"steps":0,"ids":[1,2,3]}' and st.dispatches == 0, "two empty desks trading places: nothing to renumber, nothing sent: " .. r)
  st = gapWorld({ 1, 2, 3, 12 }); O = ops(st)
  r = call(st, O, "reorder", { 2, 1, 3, 4, 5 }, { 1, 2, 3, 4, 5 })
  check(r:match("^ok") and st.deskOf("0xa1") == 2 and st.deskOf("0xa2") == 1 and st.deskOf("0xa4") == 12, "a desk outside the positions (12, another screen's) is untouched: " .. r)
  st = gapWorld(G); O = ops(st); start = st.snapshot()
  for _, bad in ipairs({ { { 1, 2, 3, 5, 6 }, P6 }, { { 1, 2, 3, 4, 5, 7 }, P6 }, { { 1, 2 }, { 1, 1 } }, { { 1, 2 }, { 0, 1 } }, { { 1, 100001 }, { 1, 100001 } }, { { 2, 1 }, "1,2" } }) do
    r = call(st, O, "reorder", bad[1], bad[2])
    check(r == "fail,0,invalid" and st.snapshot() == start and st.dispatches == 0, "malformed positions refused: " .. r)
  end
  -- insert with last: every desk from right to last moves up one, the gap moves along
  st = gapWorld(G); st.addWindow("0xc0", 6); O = ops(st)
  r = call(st, O, "insert", 1, 2, "0xc0", 6)
  check(r:match("^ok") and st.deskOf("0xc0") == 2 and st.deskOf("0xa2") == 3 and st.deskOf("0xa3") == 4 and st.deskOf("0xa4") == 6 and st.deskOf("0xa5") == 7
        and table.concat(st.ids(), ",") == "1,2,3,4,6,7", "insert 1|2 on 1 2 3 _ 5 6: new 2, old 2-3 -> 3-4, the gap -> 5, old 5-6 -> 6-7: " .. r .. " " .. st.snapshot())
  st = gapWorld(G); st.addWindow("0xc0", 1); O = ops(st)
  r = call(st, O, "insert", 3, 4, "0xc0", 6)
  check(r:match("^ok") and st.deskOf("0xc0") == 4 and st.deskOf("0xa4") == 6 and st.deskOf("0xa5") == 7, "insert 3|4 (4 empty): new 4, old 5-6 -> 6-7: " .. r)
  local lf, lc = 0, 0
  for k = 1, 5 do
    for _, mode in ipairs({ "failAt", "lieAt" }) do
      st = gapWorld(G); st.addWindow("0xc0", 6); O = ops(st); start = st.snapshot()
      F[mode] = k; r = call(st, O, "insert", 1, 2, "0xc0", 6); F.failAt, F.lieAt = nil, nil
      lc = lc + 1
      if r:match("^fail," .. k .. ",") and st.snapshot() == start then lf = lf + 1 else print("  insert last " .. mode .. " " .. k .. " -> " .. r) end
    end
  end
  check(lf == lc, ("insert with last: failure injected at each of its 5 steps restores the start (%d/%d)"):format(lf, lc))
  st = gapWorld({ 1, 2, 3, 4, 5, 6, 7 }); O = ops(st); start = st.snapshot()
  check(call(st, O, "insert", 1, 2, "0xa1", 6) == "fail,0,no-room" and st.snapshot() == start, "insert with last when last+1 is taken: no room, nothing changed")
  check(call(st, O, "insert", 1, 3, "0xa1", 2) == "fail,0,invalid", "insert with last < right refused")
  -- newdesk onto the number the "New desk" tile showed
  st = gapWorld({ 1, 2, 3 }); O = ops(st)
  r = call(st, O, "newdesk", "0xa1", 6)
  check(r == 'ok,{"steps":1,"desk":6}' and st.deskOf("0xa1") == 6, "newdesk onto 6 (the strip shows 1-5): " .. r)
  check(call(st, O, "newdesk", "0xa2", 3) == "fail,0,taken" and st.deskOf("0xa2") == 2, "newdesk onto an existing desk refused")

  -- heal
  st = world({ 1, 100003, 100005 }); O = ops(st)
  r = call(st, O, "heal")
  check(r == 'ok,{"steps":2,"ids":[1,2,3]}' and st.deskOf("0xa2") == 2 and st.deskOf("0xa3") == 3, "heal: 100003 -> 2, 100005 -> 3, order kept: " .. r)
  st = world({ 1, 2 }); O = ops(st)
  check(call(st, O, "heal") == 'ok,{"steps":0}' and st.dispatches == 0, "heal with nothing to heal sends nothing")
  st = world({ 2, 100001 }); O = ops(st)
  check(call(st, O, "heal") == 'ok,{"steps":1,"ids":[1,2]}' and st.deskOf("0xa2") == 1, "heal takes the lowest free id (1)")

  -- replies never carry a title: only digits, ids, addresses and fixed words
  for _, rep in ipairs({ r, call(world({ 1 }), O, "move", "0xa1", 2) }) do check(not rep:find("Test"), "reply has no title") end
end

print(("lua %s: %d passed, %d failed"):format(_VERSION, pass, fail))
os.exit(fail == 0 and 0 or 1)
