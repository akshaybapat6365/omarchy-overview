.pragma library
// Ops.js — validates ids and addresses and builds the hyprctl argv for each desk/window operation
// (SPEC 3.4). Owner: lane 1. Pure: no Qt types, no state (tested by tests/ops/tst_ops.qml).
//
// FROZEN CONTRACT (SPEC 3.4 / 4.1):
//   transport   one Process per drop: ["/usr/bin/hyprctl", "repl", 'return dofile("<shellDir>/ops/ovops.lua").<op>(<args>)']
//               "repl", not "eval": eval answers only "ok", repl prints the chunk's return value (HyprCtl.cpp:1110-1124,
//               evalRequest's repl flag). The absolute path skips ~/.local/bin/hyprctl, a bash wrapper that starts four
//               more programs per call and is first in the overview service's PATH (read 2026-11-19).
//   validation  shellDir ^[A-Za-z0-9_./-]+$ ; integers ^[0-9]{1,9}$ ; addresses ^0x[0-9a-f]{1,16}$ ; anything else -> null (nothing runs)
//   ops         reorder(orderIds[, positions]) | move(addr, desk) | insert(left, right|null, addr[, last]) | newdesk(addr[, desk]) | heal()
//               positions: the strip's own desks (sorted; empty desks the bar shows included), order a permutation of
//               them; last: the highest of them (an insert shifts every desk from right to last); desk: the number
//               the "New desk" tile showed
//   reply       one line: "ok" | "ok,<json>" | "fail,<step>,<why>" ; timeout 2 s ; parseReply() reads it
//   privacy     never a window title in an argv, a log line or a reply (amendment A3)

var HYPRCTL = "/usr/bin/hyprctl";

function dirOk(d) { return typeof d === "string" && /^[A-Za-z0-9_./-]+$/.test(d); }
// A whole number given as a number or a string of digits; returns the number or null.
function int(v) {
    var s = typeof v === "number" ? (Number.isInteger(v) && v >= 0 ? String(v) : "") : (typeof v === "string" ? v : "");
    return /^[0-9]{1,9}$/.test(s) ? parseInt(s, 10) : null;
}
function addr(a) { return typeof a === "string" && /^0x[0-9a-f]{1,16}$/.test(a) ? a : null; }

function argv(shellDir, call) {
    if (!dirOk(shellDir)) return null;
    return [HYPRCTL, "repl", 'return dofile("' + shellDir + '/ops/ovops.lua").' + call];
}

// A list that crossed a QML `var` signal (Scene.operate -> shell -> back end) arrives as a sequence wrapper,
// not a JS Array (Array.isArray is false; stage run integrated-20261119-210230 refused every reorder): copy it.
// Returns distinct whole numbers >= 1 as an Array, or null.
function idList(list) {
    if (list && !Array.isArray(list) && typeof list === "object" && typeof list.length === "number")
        list = Array.prototype.slice.call(list);
    if (!Array.isArray(list) || list.length < 1 || list.length > 99) return null;
    var out = [], seen = {};
    for (var i = 0; i < list.length; i++) {
        var n = int(list[i]);
        if (n === null || n < 1 || seen[n]) return null;
        seen[n] = true;
        out.push(n);
    }
    return out;
}
function reorder(shellDir, orderIds, positions) {
    var out = idList(orderIds);
    if (out === null) return null;
    if (positions === null || positions === undefined) return argv(shellDir, "reorder({" + out.join(",") + "})");
    var pos = idList(positions);
    if (pos === null || pos.length !== out.length) return null;
    var a = out.slice().sort(function (x, y) { return x - y; }), b = pos.slice().sort(function (x, y) { return x - y; });
    if (a.join() !== b.join()) return null;               // order must be a permutation of the positions
    return argv(shellDir, "reorder({" + out.join(",") + "},{" + b.join(",") + "})");
}
function move(shellDir, address, desk) {
    var a = addr(address), d = int(desk);
    if (a === null || d === null || d < 1) return null;
    return argv(shellDir, 'move("' + a + '",' + d + ")");
}
// left = 0: before the first desk; right = null/undefined: after the last.
function insert(shellDir, left, right, address, last) {
    var l = int(left), a = addr(address), r = (right === null || right === undefined) ? null : int(right);
    if (l === null || a === null || (right !== null && right !== undefined && (r === null || r <= l))) return null;
    var z = (last === null || last === undefined) ? null : int(last);
    if (last !== null && last !== undefined && (z === null || r === null || z < r)) return null;
    return argv(shellDir, "insert(" + l + "," + (r === null ? "nil" : r) + ',"' + a + '"' + (z === null ? "" : "," + z) + ")");
}
function newdesk(shellDir, address, desk) {
    var a = addr(address), d = (desk === null || desk === undefined) ? null : int(desk);
    if (a === null || (desk !== null && desk !== undefined && (d === null || d < 1))) return null;
    return argv(shellDir, 'newdesk("' + a + '"' + (d === null ? "" : "," + d) + ")");
}
function heal(shellDir) { return argv(shellDir, "heal()"); }

// The reply of one op: { ok, step, why, data }. Anything unexpected (a Lua error, a timeout, nothing) is a
// failure with a short, title-free reason.
function parseReply(text) {
    var t = String(text === undefined || text === null ? "" : text).trim();
    if (t === "ok") return { ok: true, step: 0, why: "", data: null };
    if (t.indexOf("ok,") === 0) {
        var data = null;
        try { data = JSON.parse(t.slice(3)); } catch (e) { data = null; }
        return { ok: true, step: 0, why: "", data: data };
    }
    var m = /^fail,([0-9]+),([a-z0-9+-]{1,60})$/.exec(t);
    if (m) return { ok: false, step: parseInt(m[1], 10), why: m[2], data: null };
    return { ok: false, step: -1, why: t === "" ? "no-reply" : "unexpected-reply", data: null };
}
