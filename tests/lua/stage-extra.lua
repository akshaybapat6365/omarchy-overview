-- tests/lua/stage-extra.lua — STAGE_HYPR_EXTRA for tests/stage/ops.sh (lane 1). Runs inside the NESTED stage
-- Hyprland at every config load, never on his desktop. It loads this tree's hypr/input.lua the way his
-- hyprland.lua does (require finds hypr/overview.lua next to it), in one of these cases:
--   stream   (default; the first load)   the module as built
--   missing  input.lua with no hypr/overview.lua anywhere on the path
--   syntax   a copy of the module with a syntax error
--   raise    a copy of the module that raises while loading
--   control  the module, then one gesture Hyprland must refuse (3 fingers up after 3 vertical): proves the checks
--            can see a config error and its banner at all
-- The step chooses the case for the next `hyprctl reload` by appending its name as a line to
-- $STAGE_OUT/<prefix>-lua-case.txt (the last line counts). Broken copies live in $STAGE_OUT/<prefix>-case-<name>/hypr/.
local here = debug.getinfo(1, "S").source:sub(2)           -- <rundir>/user-extra.lua
local rundir = here:match("^(.*)/[^/]+$")
local prefix = rundir:match("([^/]+)$")
local out = os.getenv("STAGE_OUT") or ""
local case = "stream"
local f = io.open(out .. "/" .. prefix .. "-lua-case.txt")
if f then for line in f:lines() do if line:match("^%a+$") then case = line end end f:close() end

local base = package.path
if case == "stream" or case == "control" then
  package.path = rundir .. "/tree/?.lua;" .. base
elseif case == "syntax" or case == "raise" then
  package.path = out .. "/" .. prefix .. "-case-" .. case .. "/?.lua;" .. base
end
package.loaded["hypr.overview"] = nil
dofile(rundir .. "/tree/hypr/input.lua")
if case == "control" then hl.gesture({ fingers = 3, direction = "up", action = function() end }) end
package.path = base
print("stage-extra: case " .. case)
