-- tests/lua/review_compositor.lua — adversarial review of the compositor side (branch review-tests-compositor).
-- Lua 5.5, no stage. Run from the tree:  lua tests/lua/review_compositor.lua   (exit 0 = every check passed)
-- Each check states the behaviour the product SHOULD have. A FAIL here is a finding, not a broken test.
assert(_VERSION == "Lua 5.5", "run these with Lua 5.5 (the version Hyprland links), not " .. _VERSION)
local ROOT = (arg and arg[0] or ""):match("^(.*)/tests/lua/review_compositor%.lua$") or "."
package.path = ROOT .. "/tests/lua/?.lua;" .. package.path
local F = require("fakehl")
local OPS = ROOT .. "/ops/ovops.lua"

local pass, fail = 0, 0
local function check(cond, what)
  if cond then pass = pass + 1; print("ok   " .. what) else fail = fail + 1; print("FAIL " .. what) end
end
local function withHl(st, fn)
  local old = rawget(_G, "hl"); _G.hl = st.hl
  local ok, err = pcall(fn)
  _G.hl = old
  if not ok then error(err, 0) end
end
local function world(ids, active)
  local st = F.new()
  for i, id in ipairs(ids) do st.addDesk(id, id == (active or ids[1])); st.addWindow(("0x%x"):format(0xa0 + i), id) end
  return st
end
local function call(st, fn, ...)
  local args, r, O = table.pack(...)
  withHl(st, function() O = dofile(OPS); r = O[fn](table.unpack(args, 1, args.n)) end)
  return r
end
-- The reply grammar Ops.js parseReply accepts (Ops.js:72). Anything else becomes "unexpected-reply", step -1.
local function parses(r) return type(r) == "string" and (r == "ok" or r:sub(1, 3) == "ok," or r:match("^fail,[0-9]+,[a-z0-9+-]+$") ~= nil and #r:match("^fail,[0-9]+,(.*)$") <= 60) end

-- ---------------------------------------------------------------------------------------------------
print("-- ovops: a failure whose rollback also fails")
do
  -- 6 desks, 2 -> 5 is 8 change_id steps. Refuse every change_id from the 8th on: step 8 fails and all 7
  -- rollback steps fail too (a compositor that stops accepting renumbering mid-op, e.g. a rule re-creating ids).
  local st = world({ 1, 2, 3, 4, 5, 6 })
  local real = st.hl.dispatch
  local n = 0
  st.hl.dispatch = function(d)
    if d.kind == "change_id" then n = n + 1; if n >= 8 then return { ok = false, error = "hl.workspace.change_id: ID is taken" } end end
    return real(d)
  end
  local r = call(st, "reorder", { 1, 3, 4, 5, 2, 6 })
  print("  reply: " .. r .. "  (" .. #r .. " chars)")
  check(parses(r), "the reply still parses in Ops.parseReply (else the overview logs 'unexpected-reply', step -1)")
  local temp = 0
  for _, id in ipairs(st.ids()) do if id >= 100000 then temp = temp + 1 end end
  print("  desks left on temporary ids: " .. temp .. "  " .. st.snapshot())
  st.hl.dispatch = real
  local r2 = call(st, "reorder", { 1, 2, 3, 4, 5, 6 })
  check(r2 == "fail,0,temp-taken", "while a desk sits on a temporary id every reorder is refused until heal(): " .. r2)
  local h = call(st, "heal")
  local still = 0
  for _, id in ipairs(st.ids()) do if id >= 100000 then still = still + 1 end end
  check(still == 0, "heal() brings every temporary desk back: " .. h .. " / " .. st.snapshot())
end

-- ---------------------------------------------------------------------------------------------------
print("-- ovops: what a refusal text can put into the reply (A3: replies and logs never carry a title)")
do
  -- word() copies the last words of Hyprland's error text into the reply, which the back end logs (lastOp,
  -- journal line 'overview-op: ...'). If a future Hyprland error names the window ("...: <title>"), its title
  -- lands in his journal. The reply should carry a fixed word, never free text from the compositor.
  local st = world({ 1, 2 })
  local real = st.hl.dispatch
  st.hl.dispatch = function(d)
    if d.kind == "move" then return { ok = false, error = "hl.window.move: cannot move window Bank Statement March" } end
    return real(d)
  end
  local r = call(st, "move", "0xa1", 2)
  print("  reply: " .. r)
  check(not r:find("bank") and not r:find("statement"), "a refusal's free text does not reach the reply")
end

print(("lua %s: %d passed, %d failed"):format(_VERSION, pass, fail))
os.exit(fail == 0 and 0 or 1)
