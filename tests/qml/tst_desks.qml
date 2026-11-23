import QtQuick
import QtTest
import "../../Desks.js" as D

// The strip lists exactly the desks Omarchy's bar lists (Desks.js header; the bar's Workspaces.qml workspaceIds()).
// Each row was worked out from the bar's source by hand, not from Desks.js.
TestCase {
    name: "Desks"

    function f(blocks, screens, desks) { return { slots: 10, blocks: blocks, screens: screens, desks: desks }; }
    function on(screen, ids) { return ids.map(function (id) { return { id: id, screen: screen }; }); }

    function test_rule_data() {
        var one = [{ name: "eDP-1", shown: 3 }];
        var two = [{ name: "eDP-1", shown: 3 }, { name: "DP-1", shown: 11 }];
        return [
            { tag: "today: 1 2 3 5 6 in use gives 1 2 3 4 5 6", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [1, 2, 3, 5, 6])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 6], own: [1, 2, 3, 4, 5, 6] },
            { tag: "fewer than five in use: the first five always", facts: f({ "eDP-1": 0 }, [{ name: "eDP-1", shown: 1 }], on("eDP-1", [1, 2])), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "nothing known yet: still the first five", facts: f({}, [], []), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "more than five", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [1, 2, 3, 4, 5, 6, 7, 8])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 6, 7, 8] },
            { tag: "sparse beyond five: only what exists", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [1, 2, 9])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 9] },
            { tag: "desk 10 is the block's last", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [3, 10])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 10] },
            { tag: "second screen, own block 11-20", facts: f({ "eDP-1": 0, "DP-1": 1 }, two, on("eDP-1", [1, 2, 3]).concat(on("DP-1", [11, 13]))), screen: "DP-1", want: [11, 12, 13, 14, 15] },
            { tag: "first screen does not list the second's block", facts: f({ "eDP-1": 0, "DP-1": 1 }, two, on("eDP-1", [1, 2, 3]).concat(on("DP-1", [11, 13, 17]))), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "a desk of the block sitting on another screen is still listed", facts: f({ "eDP-1": 0, "DP-1": 1 }, two, on("eDP-1", [1]).concat(on("DP-1", [11, 7]))), screen: "eDP-1", want: [1, 2, 3, 4, 5, 7] },
            { tag: "guest: another block's desk on this screen comes last", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [1, 2, 6, 23, 21])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 6, 21, 23], own: [1, 2, 3, 4, 5, 6], guests: [21, 23] },
            { tag: "a guest elsewhere is not listed here", facts: f({ "eDP-1": 0, "DP-1": 1 }, two, on("eDP-1", [1]).concat(on("DP-1", [11, 23]))), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "special and zero desks ignored", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [-98, -99, 0, 2, 6])), screen: "eDP-1", want: [1, 2, 3, 4, 5, 6] },
            { tag: "temporary numbers ignored (inside a reorder)", facts: f({ "eDP-1": 0 }, one, on("eDP-1", [1, 2, 100003, 100005])), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "no state file: the block of the desk the screen shows", facts: f({}, [{ name: "DP-1", shown: 14 }], on("DP-1", [14, 16])), screen: "DP-1", want: [11, 12, 13, 14, 15, 16] },
            { tag: "no state file, nothing shown: block 0", facts: f({}, [{ name: "eDP-1", shown: -1 }], on("eDP-1", [2])), screen: "eDP-1", want: [1, 2, 3, 4, 5] },
            { tag: "state file wins over the shown desk", facts: f({ "eDP-1": 1 }, one, on("eDP-1", [3, 12])), screen: "eDP-1", want: [11, 12, 13, 14, 15, 3], guests: [3] }
        ];
    }
    function test_rule(d) {
        var r = D.forScreen(d.facts, d.screen);
        compare(JSON.stringify(r.ids), JSON.stringify(d.want));
        if (d.own) compare(JSON.stringify(r.own), JSON.stringify(d.own));
        if (d.guests) compare(JSON.stringify(r.guests), JSON.stringify(d.guests));
    }
    function test_slots() {
        compare(D.blockOf(10), 0); compare(D.blockOf(11), 1); compare(D.slotOf(20), 10); compare(D.slotOf(13), 3);
    }
}
