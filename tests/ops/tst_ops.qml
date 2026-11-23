// tests/ops/tst_ops.qml — Ops.js (SPEC 4.2 lane 1 (b)): every malformed id, address or folder is refused
// (null: nothing runs), every good one gives the exact argv, replies are read safely.
// Run: /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/ops/tst_ops.qml
import QtQuick
import QtTest
import "../../Ops.js" as Ops

TestCase {
    name: "Ops"
    readonly property string dir: "/home/u/.config/quickshell/overview"
    readonly property var badDirs: ["", "a b", "a\"b", "a'b", "a;b", "a)b", "a\nb", "$HOME", "a`b", "a\\b", "a]b", null, undefined, 5]
    readonly property var badInts: [-1, 1.5, NaN, Infinity, -0.5, "", " 1", "1 ", "1;", "0x10", "1e3", "+1", "-1", "１",
                                     "1234567890", 1e12, null, undefined, true, [], ({}), "1); os.exit(", "nil"]
    readonly property var badAddrs: ["", "0x", "0X1a", "0xG1", "0xAB", "1a2b", "address:0x1a", " 0x1a", "0x1a ", "0x1a\"",
                                     "0x1a\")", "0x1a,1", "0x" + "f".repeat(17), null, undefined, 26, "Test window 1"]

    // The real path: Scene.operate(var op) -> shell -> back end. A list that crosses a `var` signal is no JS Array.
    signal carry(var op)
    property var carried: null
    onCarry: function (op) { carried = Ops.reorder(dir, op.order); }
    function test_reorder_through_a_var_signal() {
        carry({ op: "reorder", order: [1, 3, 4, 5, 2, 6] });
        compare(carried, ["/usr/bin/hyprctl", "repl", 'return dofile("' + dir + '/ops/ovops.lua").reorder({1,3,4,5,2,6})']);
    }
    function test_good_argv() {
        compare(Ops.reorder(dir, [1, 3, 4, 5, 2, 6]),
                ["/usr/bin/hyprctl", "repl", 'return dofile("' + dir + '/ops/ovops.lua").reorder({1,3,4,5,2,6})']);
        compare(Ops.reorder(dir, ["1", "2"])[2], 'return dofile("' + dir + '/ops/ovops.lua").reorder({1,2})');
        compare(Ops.move(dir, "0x55d0c3a0", 4)[2], 'return dofile("' + dir + '/ops/ovops.lua").move("0x55d0c3a0",4)');
        compare(Ops.insert(dir, 1, 2, "0xab")[2], 'return dofile("' + dir + '/ops/ovops.lua").insert(1,2,"0xab")');
        compare(Ops.insert(dir, 3, null, "0xab")[2], 'return dofile("' + dir + '/ops/ovops.lua").insert(3,nil,"0xab")');
        compare(Ops.insert(dir, 0, 1, "0xab")[2], 'return dofile("' + dir + '/ops/ovops.lua").insert(0,1,"0xab")');
        compare(Ops.newdesk(dir, "0xab")[2], 'return dofile("' + dir + '/ops/ovops.lua").newdesk("0xab")');
        compare(Ops.heal(dir), ["/usr/bin/hyprctl", "repl", 'return dofile("' + dir + '/ops/ovops.lua").heal()']);
    }

    // The bar's desks as positions (empty ones included), a shifting insert up to the last of them, a new desk's number.
    signal carryP(var op)
    property var carriedP: null
    onCarryP: function (op) { carriedP = Ops.reorder(dir, op.order, op.positions); }
    function test_positions_last_desk() {
        var L = 'return dofile("' + dir + '/ops/ovops.lua").';
        compare(Ops.reorder(dir, [1, 3, 4, 5, 2, 6], [1, 2, 3, 4, 5, 6])[2], L + "reorder({1,3,4,5,2,6},{1,2,3,4,5,6})");
        compare(Ops.reorder(dir, [2, 1], [2, 1])[2], L + "reorder({2,1},{1,2})", "positions are sent sorted");
        carryP({ op: "reorder", order: [1, 3, 4, 5, 2, 6], positions: [1, 2, 3, 4, 5, 6] });
        compare(carriedP[2], L + "reorder({1,3,4,5,2,6},{1,2,3,4,5,6})", "both lists survive a var signal");
        compare(Ops.reorder(dir, [1, 2, 3], [1, 2, 4]), null, "order not a permutation of the positions");
        compare(Ops.reorder(dir, [1, 2], [1, 2, 3]), null, "lengths differ");
        compare(Ops.reorder(dir, [1, 2], [1, 1]), null, "duplicate positions");
        compare(Ops.reorder(dir, [1, 2], "1,2"), null, "positions not a list");
        for (var i = 0; i < badInts.length; i++) if (badInts[i] !== null && badInts[i] !== undefined)
            compare(Ops.reorder(dir, [1, 2], [1, badInts[i]]), null, "position " + String(JSON.stringify(badInts[i])));
        compare(Ops.insert(dir, 1, 2, "0xab", 6)[2], L + 'insert(1,2,"0xab",6)');
        compare(Ops.insert(dir, 1, 2, "0xab", 1), null, "last < right");
        compare(Ops.insert(dir, 3, null, "0xab", 6), null, "last without right");
        compare(Ops.insert(dir, 1, 2, "0xab", "6;"), null, "last malformed");
        compare(Ops.newdesk(dir, "0xab", 7)[2], L + 'newdesk("0xab",7)');
        compare(Ops.newdesk(dir, "0xab", 0), null, "desk 0");
        compare(Ops.newdesk(dir, "0xab", "7)"), null, "desk malformed");
        var inner = [Ops.reorder(dir, [2, 1], [1, 2]), Ops.insert(dir, 1, 2, "0x1", 6), Ops.newdesk(dir, "0x2", 7)];
        for (i = 0; i < inner.length; i++) verify(/^[a-z]+\([0-9a-x{},"nil]*\)$/.test(inner[i][2].replace(L, "")), inner[i][2]);
    }

    function test_bad_dirs() {
        for (var i = 0; i < badDirs.length; i++) {
            var d = badDirs[i];
            compare(Ops.heal(d), null, "dir " + JSON.stringify(d));
            compare(Ops.move(d, "0x1", 2), null, "dir " + JSON.stringify(d));
            compare(Ops.reorder(d, [1, 2]), null, "dir " + JSON.stringify(d));
        }
    }

    function test_bad_ints() {
        for (var i = 0; i < badInts.length; i++) {
            var v = badInts[i], tag = String(JSON.stringify(v));
            compare(Ops.move(dir, "0x1", v), null, "move desk " + tag);
            compare(Ops.reorder(dir, [1, v]), null, "reorder id " + tag);
            compare(Ops.insert(dir, v, 5, "0x1"), null, "insert left " + tag);
            if (v !== null && v !== undefined) compare(Ops.insert(dir, 1, v, "0x1"), null, "insert right " + tag);
        }
        compare(Ops.move(dir, "0x1", 0), null, "desk 0");
        compare(Ops.reorder(dir, [1, 2, 1]), null, "duplicate ids");
        compare(Ops.reorder(dir, [0, 1]), null, "id 0");
        compare(Ops.reorder(dir, []), null, "empty order");
        compare(Ops.reorder(dir, "1,2"), null, "order not an array");
        compare(Ops.insert(dir, 2, 2, "0x1"), null, "right == left");
        compare(Ops.insert(dir, 3, 2, "0x1"), null, "right < left");
    }

    function test_bad_addrs() {
        for (var i = 0; i < badAddrs.length; i++) {
            var a = badAddrs[i], tag = String(JSON.stringify(a));
            compare(Ops.move(dir, a, 2), null, "move " + tag);
            compare(Ops.newdesk(dir, a), null, "newdesk " + tag);
            compare(Ops.insert(dir, 1, 2, a), null, "insert " + tag);
        }
    }

    function test_no_quote_can_escape() {
        // Whatever passes validation contains no character that could end the Lua string or the call.
        var all = [Ops.reorder(dir, [1, 2, 3]), Ops.move(dir, "0xdeadbeef", 99), Ops.insert(dir, 0, null, "0x1"), Ops.newdesk(dir, "0x2")];
        for (var i = 0; i < all.length; i++) {
            var inner = all[i][2].replace('return dofile("' + dir + '/ops/ovops.lua").', "");
            verify(/^[a-z]+\([0-9a-x{},"nil]*\)$/.test(inner), inner);
        }
    }

    function test_replies() {
        compare(Ops.parseReply("ok\n"), { ok: true, step: 0, why: "", data: null });
        compare(Ops.parseReply('ok,{"steps":8,"ids":[1,2,3]}').data.steps, 8);
        compare(Ops.parseReply("fail,3,id-is-taken"), { ok: false, step: 3, why: "id-is-taken", data: null });
        compare(Ops.parseReply("fail,0,invalid").step, 0);
        compare(Ops.parseReply("fail,2,not-applied+rollback-1").why, "not-applied+rollback-1");
        compare(Ops.parseReply("error: [string \"return dofile(...)\"]:1: cannot open").why, "unexpected-reply");
        compare(Ops.parseReply("").why, "no-reply");
        compare(Ops.parseReply(undefined).why, "no-reply");
        compare(Ops.parseReply("fail,1,Some Window Title").why, "unexpected-reply");   // never echoes free text
        compare(Ops.parseReply("ok,{broken").ok, true);
    }
}
