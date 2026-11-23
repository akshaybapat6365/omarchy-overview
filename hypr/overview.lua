-- hypr/overview.lua — the gesture stream for the overview (qs -c overview). Owner: lane 1.
-- Ships as ~/.config/hypr/overview.lua, loaded from input.lua by pcall(require, "hypr.overview").
--
-- FROZEN INTERFACE (SPEC 3.1, 3.2, 4.1, coordinator addendum L1-L6, amendment A1):
--   M.handlers = { start, update, finish }   gesture callbacks; they only send events, each body runs in pcall:
--       hl.dispatch(hl.dsp.event("ovg,<...>")) -> socket2 "custom>>ovg,<...>"; no process is ever started
--   events (frozen; distances in MILLIMETRES of finger travel since the stroke began, two decimals,
--   positive = fingers moved up; t_ms = Hyprland's time_ms, milliseconds since boot):
--       ovg,hello                       once per config load
--       ovg,b,<fingers>,<UP|DOWN>,0.00,<t_ms>   stroke begins (direction = the stroke's first direction, L2)
--       ovg,u,<mm>,<t_ms>               progress, at most one per 12 ms, only while the fingers move (L4)
--       ovg,e,<mm>,<t_ms>,<0|1>         stroke ends (1 = cancelled); always carries the final value
--       ovg,ping,<n>                    sent by the overview itself (self-check), never by this file
--   registration: hl.gesture{ fingers = 3|4, direction = "vertical", action = M.handlers }, each in pcall and
--       verified (Hyprland drops its references to a refused gesture). Where that fails, the one-shot pair for that
--       finger count is registered instead: up -> hl.dsp.global("omarchy-overview:toggle"),
--       down -> hl.dsp.global("omarchy-overview:close"), run once at lift-off; no process is started.
--   M.mode = "stream" | "legacy" | "none"   ("legacy" when any finger count fell back; M.byFingers has each one)
--   Never raises. A Lua error anywhere in here is caught; it never reaches Hyprland's error banner.
--   Note: hl.gesture REPORTS a refused gesture (conflict) as a config error instead of raising it, so no pcall can
--   hide that one; it cannot happen with input.lua as shipped (the old 3/4 up/down lines are gone).
local M = { mode = "none", byFingers = {}, stats = { strokes = 0, updates = 0, sent = 0, errors = 0 } }

-- ---- finger distance (addendum L6) --------------------------------------------------------------
-- Hyprland's swipe deltas are libinput's ACCELERATED pointer units, not distance. Progress must follow
-- finger distance, so every update is converted to millimetres with libinput's touchpad curve.
-- UNITS_PER_MM: units per mm of finger travel between 7 and 130 mm/s. Measured 2026-11-19 on the live
-- Hyprland 0.56.2 with a uinput copy of his ELAN pad (31 device units/mm) driven at 20, 40 and 80 mm/s
-- (24.7 units/mm each), at his input.sensitivity = 0.45, adaptive profile. It scales with
-- input.sensitivity: re-measure if that setting changes.
local UNITS_PER_MM = 24.75
local V_MAX = 520            -- mm/s; the curve is flat beyond
local function gain(v)       -- units per mm at finger speed v (mm/s); threshold 130 mm/s
  local f
  if v < 7 then f = (0.1 * v + 0.3) / 0.9
  elseif v <= 130 then f = 1
  else v = math.min(v, V_MAX); f = 1 + 0.0025 * (v / 130) * (v - 130) / 0.9 end
  return UNITS_PER_MM * f
end
-- Built once: delivered speed s (units/ms) at finger speed v = 0, 5, ... 520 mm/s, and the gain there.
local SPD, GAIN = {}, {}
for i = 0, V_MAX // 5 do
  local v = i * 5
  GAIN[i + 1] = gain(v)
  SPD[i + 1] = v * GAIN[i + 1] / 1000
end
local NS = #SPD
local function gainAt(s)     -- gain for a delivered speed s (units/ms): binary search + linear blend
  if s <= 0 then return GAIN[1] end
  if s >= SPD[NS] then return GAIN[NS] end
  local lo, hi = 1, NS
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if SPD[mid] <= s then lo = mid else hi = mid end
  end
  local k = (s - SPD[lo]) / (SPD[hi] - SPD[lo])
  return GAIN[lo] + k * (GAIN[hi] - GAIN[lo])
end
M.gainAt, M.UNITS_PER_MM = gainAt, UNITS_PER_MM

-- ---- the stream ---------------------------------------------------------------------------------
local fmt, upper, sqrt = string.format, string.upper, math.sqrt
local stats = M.stats
local mm, lastT, sentAt, first = 0, 0, -1e9, true
local MIN_GAP_MS = 12        -- <= 84 progress events a second (about 71 at the pad's 7 ms frames)

local function send(s)
  hl.dispatch(hl.dsp.event("ovg," .. s))
  stats.sent = stats.sent + 1
end

-- start uses no delta: its delta arrives again in the first update (L3).
local function onStart(e)
  mm, lastT, sentAt, first = 0, e.time_ms, e.time_ms, true
  stats.strokes = stats.strokes + 1
  send(fmt("b,%d,%s,0.00,%d", e.fingers or 0, upper(tostring(e.direction)), e.time_ms))
end
local function onUpdate(e)
  local t, d = e.time_ms, e.delta
  local dt = first and 8 or t - lastT
  if dt < 4 then dt = 4 elseif dt > 40 then dt = 40 end
  first, lastT = false, t
  local dx, dy = d.x, d.y
  mm = mm - dy / gainAt(sqrt(dx * dx + dy * dy) / dt)
  stats.updates = stats.updates + 1
  if t - sentAt >= MIN_GAP_MS then
    sentAt = t
    send(fmt("u,%.2f,%d", mm, t))
  end
end
local function onFinish(e)
  send(fmt("e,%.2f,%d,%d", mm, e.time_ms or lastT, e.cancelled and 1 or 0))
end

local function guarded(fn)
  return function(e)
    if not pcall(fn, e) then stats.errors = stats.errors + 1 end
  end
end
M.handlers = { start = guarded(onStart), update = guarded(onUpdate), finish = guarded(onFinish) }

-- ---- registration (amendment A1) ----------------------------------------------------------------
-- How many references Hyprland's Lua registry holds to fn. hl.gesture refs each callback and drops the
-- refs again when it refuses the gesture, so a change in this count is the proof it registered.
local function refs(fn)
  if not (debug and debug.getregistry) then return nil end
  local n = 0
  for _, v in pairs(debug.getregistry()) do if v == fn then n = n + 1 end end
  return n
end
local function register(spec, fn)
  local before = refs(fn)
  if not pcall(hl.gesture, spec) then return false end
  return before == nil or refs(fn) > before
end
local function toggle() hl.dispatch(hl.dsp.global("omarchy-overview:toggle")) end
local function close() hl.dispatch(hl.dsp.global("omarchy-overview:close")) end

local function registerAll()
  local streamed, legacy = 0, 0
  for _, f in ipairs({ 3, 4 }) do
    if register({ fingers = f, direction = "vertical", action = M.handlers }, M.handlers.start) then
      streamed, M.byFingers[f] = streamed + 1, "stream"
    else
      local up = register({ fingers = f, direction = "up", action = toggle }, toggle)
      local down = register({ fingers = f, direction = "down", action = close }, close)
      M.byFingers[f] = (up or down) and "legacy" or "none"
      if up or down then legacy = legacy + 1 end
    end
  end
  M.mode = (streamed == 2 and "stream") or (streamed + legacy > 0 and "legacy") or "none"
end

pcall(registerAll)
pcall(send, "hello")
return M
