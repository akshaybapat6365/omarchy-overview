.pragma library
// Desks.js — which desks the strip shows on a screen: exactly the desks Omarchy's bar shows there, in its order.
// Pure (no Qt types, no state); tested by tests/qml/tst_desks.qml. Both back ends feed it; nothing else decides.
//
// The bar's rule (/usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml, workspaceIds(), read 2026-11-19):
//   Every screen owns a block of `slots` (10) desk numbers: block b holds b*10+1 .. b*10+10. Which block a screen
//   owns is in Omarchy's state file (~/.local/state/omarchy/monitor-workspaces, "<block>\t<connector>\t<identity>",
//   written by default/hypr/monitor-workspaces.lua); until it is written, the block of the desk the screen shows.
//   Listed: the block's first five numbers always (existing or not), plus every desk of the block that exists (on
//   any screen), sorted; then the "guests": desks of another block that sit on this screen, sorted. Special desks
//   (id <= 0) never.
// One difference, on purpose: a desk on a temporary number (>= 100000, only inside a reorder, healed on the next
// open) is never listed. The bar may draw one for a frame as a guest; the open overview covers the bar then.
//
// facts = { slots: 10, blocks: { "<connector>": block }, screens: [{ name, shown }], desks: [{ id, screen }] }
// forScreen(facts, name) -> { block, base, own: [ids], guests: [ids], ids: own.concat(guests) }
// strip(facts, name, info) -> the scene's desks: [{ id, name, isNew, waiting, count, exists, guest }], the bar's desks
//   then "New desk" (the first number after the screen's own that no desk holds). info = { <id>: { name, waiting,
//   count } } for desks with windows; exists = Hyprland has the desk (an empty one the bar lists may not).

var SLOTS = 10;
var TEMP = 100000;

function blockOf(id, slots) { return Math.floor((id - 1) / (slots || SLOTS)); }
function slotOf(id, slots) { return (id - 1) % (slots || SLOTS) + 1; }

function screenBlock(facts, name) {
    var slots = facts.slots || SLOTS, b = facts.blocks ? facts.blocks[name] : undefined;
    if (typeof b === "number" && b >= 0 && b === Math.floor(b)) return b;
    var screens = facts.screens || [];
    for (var i = 0; i < screens.length; i++)
        if (screens[i].name === name) return screens[i].shown > 0 ? blockOf(screens[i].shown, slots) : 0;
    return 0;
}

function forScreen(facts, name) {
    facts = facts || {};
    var slots = facts.slots || SLOTS, block = screenBlock(facts, name), base = block * slots;
    var own = [base + 1, base + 2, base + 3, base + 4, base + 5], guests = [], desks = facts.desks || [];
    for (var i = 0; i < desks.length; i++) {
        var id = desks[i].id;
        if (typeof id !== "number" || id <= 0 || id >= TEMP) continue;
        if (blockOf(id, slots) === block) { if (own.indexOf(id) < 0) own.push(id); }
        else if (desks[i].screen === name && guests.indexOf(id) < 0) guests.push(id);
    }
    var up = function (a, b) { return a - b; };
    own.sort(up); guests.sort(up);
    return { block: block, base: base, own: own, guests: guests, ids: own.concat(guests) };
}

function strip(facts, name, info) {
    facts = facts || {};
    info = info || {};
    // A screen the back end does not name (the mock's, or one not read yet) is its only screen when there is one.
    var screens = facts.screens || [], known = false, i;
    for (i = 0; i < screens.length; i++) if (screens[i].name === name) known = true;
    if (!known && screens.length === 1) name = screens[0].name;
    var r = forScreen(facts, name), have = {}, out = [], desks = facts.desks || [];
    for (i = 0; i < desks.length; i++) have[desks[i].id] = true;
    for (var d in info) have[d] = true;
    for (i = 0; i < r.ids.length; i++) {
        var id = r.ids[i], k = info[id];
        out.push({ id: id, name: k ? k.name : "Empty", isNew: false, waiting: k ? k.waiting : 0, count: k ? k.count : 0,
                   exists: have[id] === true, guest: i >= r.own.length });
    }
    var plus = r.own[r.own.length - 1] + 1;
    while (have[plus]) plus++;
    out.push({ id: plus, name: "New desk", isNew: true, waiting: 0, count: 0, exists: false, guest: false });
    return out;
}
