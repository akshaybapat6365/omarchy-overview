-- Keyboard, pointer, and touchpad behavior measured and tuned for the
-- ELAN 04F3:311C in this XPS 17.
hl.config({
  input = {
    kb_layout = "us",
    kb_options = "compose:caps",
    repeat_rate = 40,
    repeat_delay = 250,
    numlock_by_default = true,
    sensitivity = 0.45,  -- 2026-08-24: 0.15 -> 0.45 (custom accel curve is inert under the Lua provider; this is the lever that actually works)
    accel_profile = "adaptive",
    emulate_discrete_scroll = false,

    touchpad = {
      natural_scroll = true,
      tap_to_click = true,
      tap_and_drag = false,
      drag_lock = false,
      clickfinger_behavior = true,
      tap_button_map = "lrm",
      drag_3fg = false,
      scroll_factor = 1.0,  -- 2026-08-24: 0.5 -> 1.0 (scroll_points curve inert; 0.5 alone was half-speed)
      disable_while_typing = true,
    },
  },

  gestures = {
    workspace_swipe_distance = 350,
    workspace_swipe_cancel_ratio = 0.35,
    workspace_swipe_min_speed_to_force = 28,
    workspace_swipe_create_new = true,
    workspace_swipe_direction_lock = true,
    workspace_swipe_direction_lock_threshold = 8,
    workspace_swipe_forever = true,
    workspace_swipe_use_r = true,
  },
})

-- Per-application scroll speed overrides.
o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.0 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 1.0 })
o.window("Aether", { scroll_touchpad = 1.0 })
-- Omarchy's TUIs (btop, the agent console, ...) launch under org.omarchy.* /
-- TUI.* classes and are matched by their terminal's initial title; the stock
-- rule gives Ghostty ones 0.2, a fifth of every other Ghostty window here.
o.window({ class = "(org\\.omarchy\\..*|TUI\\..*)", initial_title = "(Ghostty|Alacritty|kitty|foot)" }, { scroll_touchpad = 1.0 })

-- Native continuous workspace gesture plus discrete user-space actions.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-- Three and four fingers up or down open and close the overview, following the
-- fingers: hypr/overview.lua streams each stroke to it (no program is started).
-- If that file is missing or broken, the same swipes still open and close it,
-- in one step when the fingers lift. It is loaded by hand, not with require():
-- Hyprland's require() turns a broken module into an error banner and an empty
-- table instead of an error a pcall could catch.
local function load_overview()
  local path = package.searchpath("hypr.overview", package.path)
  local chunk = path and loadfile(path)
  if not chunk then return false end
  local ok, module = pcall(chunk)
  if not ok or type(module) ~= "table" then return false end
  package.loaded["hypr.overview"] = module
  return true
end
if not load_overview() then
  local function toggle() hl.dispatch(hl.dsp.global("omarchy-overview:toggle")) end
  local function close() hl.dispatch(hl.dsp.global("omarchy-overview:close")) end
  for _, fingers in ipairs({ 3, 4 }) do
    pcall(hl.gesture, { fingers = fingers, direction = "up", action = toggle })
    pcall(hl.gesture, { fingers = fingers, direction = "down", action = close })
  end
end
hl.gesture({ fingers = 3, direction = "pinchout", action = function() hl.exec_cmd("omarchy-menu toggle apps") end })

hl.gesture({ fingers = 4, direction = "left", action = function() hl.dispatch(hl.dsp.window.move({ workspace = "r-1", follow = true })) end })
hl.gesture({ fingers = 4, direction = "right", action = function() hl.dispatch(hl.dsp.window.move({ workspace = "r+1", follow = true })) end })
hl.gesture({ fingers = 4, direction = "pinchin", action = function() hl.exec_cmd("omarchy-menu toggle apps") end })
hl.gesture({ fingers = 4, direction = "pinchout", action = function() hl.dispatch(hl.dsp.focus({ workspace = "empty" })) end })
hl.gesture({ fingers = 5, direction = "swipe", action = function() hl.exec_cmd("omarchy-menu toggle apps") end })

-- rinertia's momentum arrives through its virtual device, which Hyprland
-- classifies as a MOUSE — so the touchpad's scroll_factor never applies to
-- the coast, and without this the lift-off jumps to rinertia's raw rate.
-- rinertia emits at its own factor 1.3, so ~1/1.3 = 0.77 makes the coast
-- start at the same speed the finger was moving. Keep this in step with the
-- touchpad scroll_factor above: rinertia_device = touchpad_factor / 1.3.
hl.device({
  name = "rinertia-virtual-device",
  scroll_factor = 0.77,
})
