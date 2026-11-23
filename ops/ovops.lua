-- ops/ovops.lua — compositor-side desk and window operations for the overview (Lua 5.5, no globals).
-- Interface: M.ok, M.ids, M.reorder(order[, positions]), M.move, M.insert, M.newdesk, M.heal, M.layoutGuard.
-- Replies: "ok" | "ok,<json>" | "fail,<step>,<why>" (ids, addresses, counts only; never window titles).
local M, TEMP = {}, 100000
function M.ok(r) return r == nil or r == true or (type(r) == "table" and r.ok ~= false and r.success ~= false) end
local function exists(id) return hl.get_workspace(tostring(id)) ~= nil end
function M.ids()
  local out = {}
  for _, ws in ipairs(hl.get_workspaces()) do if not ws.special and ws.id > 0 then out[#out + 1] = ws.id end end
  table.sort(out); return out
end
local function json(ids) return "[" .. table.concat(ids, ",") .. "]" end
local WORDS = { invalid_state = "taken", no_target = "gone" }
local function word(r) return type(r) == "table" and WORDS[r.code] or "refused" end
local function renumber(from, to)
  if exists(to) then return false, "taken" end
  local r = hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(from), id = to }))
  if not M.ok(r) then return false, word(r) end
  if exists(from) or not exists(to) then return false, "not-applied" end
  return true
end
local function rollback(done)
  local failed = 0
  for j = #done, 1, -1 do if not renumber(done[j][2], done[j][1]) then failed = failed + 1 end end
  return failed > 0 and ("+rollback-failed-" .. failed) or ""
end
local function run(steps)
  local done = {}
  for i, s in ipairs(steps) do
    local ok, why = renumber(s[1], s[2])
    if not ok then return "fail," .. i .. "," .. why .. rollback(done) end
    done[#done + 1] = s
  end
  return nil, done
end

-- Per-desk tiled layouts (e.g. scrolling) migrate with their desk when o.workspace_mode or hl.workspace_rule exists;
-- floating-mode desks (async timer tags) and environments without a rule setter stay guarded.
local function layoutGuard(numbers, movedMap)
  local okDef, def = pcall(hl.get_config, "general.layout")
  if not okDef or type(def) ~= "string" then def = nil end
  local floating, okW, tagged = {}, pcall(hl.get_windows, { tag = "omarchy-floating-workspace" })
  for _, w in ipairs(okW and type(tagged) == "table" and tagged or {}) do
    if w.workspace and w.workspace.id then floating[w.workspace.id] = true end
  end
  local uniq, list, oldModes, hasCustom = {}, {}, {}, false
  local om = rawget(_G, "o")
  local canMigrate = (type(om) == "table" and type(om.workspace_mode) == "function") or type(hl.workspace_rule) == "function"
  for _, n in ipairs(numbers) do if not uniq[n] then uniq[n], list[#list + 1] = true, n end end
  table.sort(list)
  for _, n in ipairs(list) do
    if floating[n] then return n, nil end
    local ws = hl.get_workspace(tostring(n))
    local own = ws and def and type(ws.tiled_layout) == "string" and ws.tiled_layout ~= "" and ws.tiled_layout ~= def
    if own then
      if not movedMap or not canMigrate then return n, nil end
      oldModes[n], hasCustom = ws.tiled_layout, true
    end
  end
  if not hasCustom then return nil, nil end
  local newModes, affected = {}, {}
  for _, n in ipairs(list) do affected[n] = true end
  for oldId, mode in pairs(oldModes) do local dst = movedMap[oldId] or oldId; newModes[dst], affected[dst] = mode, true end
  return nil, { def = def, oldModes = oldModes, newModes = newModes, affected = affected }
end
M.layoutGuard = layoutGuard

local function applyLayoutPlan(plan)
  if not plan then return end
  local om = rawget(_G, "o")
  local useOm = type(om) == "table" and type(om.workspace_mode) == "function"
  for id, _ in pairs(plan.affected) do
    local mode = plan.newModes[id] or plan.def
    if useOm then pcall(om.workspace_mode, { workspace = tostring(id), mode = mode })
    elseif type(hl.workspace_rule) == "function" then pcall(hl.workspace_rule, { workspace = tostring(id), layout = mode }) end
  end
  local home = os and os.getenv and os.getenv("HOME")
  if not home or home == "" or not io or not io.open then return end
  local dir, hadAny = home .. "/.local/state/omarchy/workspace-layouts", false
  for id, _ in pairs(plan.oldModes) do local f = io.open(dir .. "/" .. id .. ".lua", "r"); if f then f:close(); hadAny = true; break end end
  if not hadAny then return end
  for id, _ in pairs(plan.affected) do
    local p, mode = dir .. "/" .. id .. ".lua", plan.newModes[id]
    if mode and mode ~= plan.def then
      local f = io.open(p, "w"); if f then f:write(string.format('o.workspace_mode({ workspace = "%d", mode = "%s" })\n', id, mode)); f:close() end
    elseif os.remove then pcall(os.remove, p) end
  end
end

local function idset(list)            -- a sorted copy of distinct ordinary ids, or nil
  if type(list) ~= "table" then return nil end
  local out, seen = {}, {}
  for i, id in ipairs(list) do
    if math.type(id) ~= "integer" or id < 1 or id >= TEMP or seen[id] then return nil end
    seen[id], out[i] = true, id
  end
  table.sort(out); return out
end

function M.reorder(order, positions)
  local all = M.ids()
  -- A desk still on a temporary id (a reorder cut short by a crash): heal() first, nothing is touched here.
  if all[#all] and all[#all] >= TEMP then return "fail,0,temp-taken" end
  local S = positions == nil and all or idset(positions)
  if not S or type(order) ~= "table" or #order ~= #S then return "fail,0,invalid" end
  local seen, known = {}, {}
  for _, id in ipairs(S) do known[id] = true end
  for i = 1, #order do
    local id = order[i]
    if math.type(id) ~= "integer" or not known[id] or seen[id] or id >= TEMP then return "fail,0,invalid" end
    seen[id] = true
  end
  local A, B, changed, movedMap = {}, {}, {}, {}
  for i = 1, #S do
    if order[i] ~= S[i] then           -- TEMP + i is free: no ordinary id is >= TEMP (checked above)
      changed[#changed + 1], changed[#changed + 2] = S[i], order[i]
      if exists(order[i]) then
        A[#A + 1], B[#B + 1] = { order[i], TEMP + i }, { TEMP + i, S[i] }
        movedMap[order[i]] = S[i]
      end
    end
  end
  if #A == 0 then return "ok," .. '{"steps":0,"ids":' .. json(all) .. "}" end
  local own, plan = layoutGuard(changed, movedMap)
  if own then return "fail,0,desk-layout-" .. own end
  for _, s in ipairs(B) do A[#A + 1] = s end
  local err = run(A)
  if err then return err end
  applyLayoutPlan(plan)
  return "ok," .. '{"steps":' .. #A .. ',"ids":' .. json(M.ids()) .. "}"
end

local function window(addr)
  if type(addr) ~= "string" or not addr:match("^0x%x+$") then return nil end
  return hl.get_window("address:" .. addr)
end
local function deskOf(w) return w.workspace and w.workspace.id end

-- The move itself, verified by lookup. Returns nil on success, else a reason.
local function moveWindow(addr, desk)
  local r = hl.dispatch(hl.dsp.window.move({ workspace = tostring(desk), follow = false, window = "address:" .. addr }))
  if not M.ok(r) then return word(r) end
  local w = window(addr)
  if not w or deskOf(w) ~= desk then return "not-applied" end
  return nil
end
local function checkMovable(addr, desk)
  if math.type(desk) ~= "integer" or desk < 1 or desk >= TEMP then return "fail,0,invalid" end
  local w = window(addr)
  if not w then return "fail,0,no-window" end
  if w.pinned then return "fail,0,pinned" end
  if not deskOf(w) or deskOf(w) < 1 then return "fail,0,special" end
  return nil, w
end

function M.move(addr, desk)
  local err, w = checkMovable(addr, desk)
  if err then return err end
  if deskOf(w) == desk then return 'ok,{"steps":0}' end
  local why = moveWindow(addr, desk)
  if why then return "fail,1," .. why end
  return 'ok,{"steps":1,"desk":' .. desk .. "}"
end

function M.newdesk(addr, desk)
  local S = M.ids()
  if desk ~= nil and math.type(desk) == "integer" and exists(desk) then return "fail,0,taken" end
  return M.move(addr, desk or (S[#S] or 0) + 1)
end

function M.insert(left, right, addr, last)
  if math.type(left) ~= "integer" or left < 0 or (right ~= nil and (math.type(right) ~= "integer" or right <= left))
    or (last ~= nil and (right == nil or math.type(last) ~= "integer" or last < right or last >= TEMP)) then
    return "fail,0,invalid"
  end
  local err = checkMovable(addr, left + 1)
  if err then return err end
  local limit = right or math.huge
  for k = left + 1, math.min(limit - 1, TEMP - 1) do
    if not exists(k) then return M.move(addr, k) end
  end
  -- No free number between the neighbours: every desk from right to last (default: the run right, right+1, ...)
  -- moves up by one, from the top down; a number with no desk in between is a gap that moves along.
  local top = last or right
  while not last and exists(top + 1) do top = top + 1 end
  if top + 1 >= TEMP or (last and exists(last) and exists(last + 1)) then return "fail,0,no-room" end
  local steps, shifted, movedMap = {}, { top + 1 }, {}
  for id = top, right, -1 do
    if exists(id) then
      steps[#steps + 1], shifted[#shifted + 1] = { id, id + 1 }, id
      movedMap[id] = id + 1
    end
  end
  local own, plan = layoutGuard(shifted, movedMap)
  if own then return "fail,0,desk-layout-" .. own end
  local failed, done = run(steps)
  if failed then return failed end
  local why = moveWindow(addr, right)
  if why then return "fail," .. (#steps + 1) .. "," .. why .. rollback(done) end
  applyLayoutPlan(plan)
  return 'ok,{"steps":' .. (#steps + 1) .. ',"desk":' .. right .. ',"ids":' .. json(M.ids()) .. "}"
end

function M.heal()
  local S, steps, taken, free = M.ids(), {}, {}, 1
  for _, id in ipairs(S) do taken[id] = true end
  for _, id in ipairs(S) do
    if id >= TEMP then
      while taken[free] do free = free + 1 end
      steps[#steps + 1] = { id, free }
      taken[free] = true
    end
  end
  if #steps == 0 then return 'ok,{"steps":0}' end
  local err = run(steps)
  if err then return err end
  return 'ok,{"steps":' .. #steps .. ',"ids":' .. json(M.ids()) .. "}"
end

return M
