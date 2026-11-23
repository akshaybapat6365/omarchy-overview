// Two facts of Qt 6.12's DragHandler that the overview's pointer code depends on (review, interaction share).
//   /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input tests/qml/tst_qt_draghandler_facts.qml
// 1. Inside onActiveChanged (becoming active) `translation` is still (0,0): it cannot tell a pull-down from a
//    sideways drag (DeskTile.qml decides window-or-desk from it).
// 2. A DragHandler disabled while active stays active, gets no further moves, and lets go only at the release
//    (WindowCard.qml's handler is enabled only while scene.settled; a hover-hold page turn clears that mid-drag).
import QtQuick
import QtTest
Item {
    id: root; width: 400; height: 400
    property var seen: []
    property bool en: true
    property int moves: 0
    Rectangle {
        x: 100; y: 100; width: 100; height: 100
        DragHandler {
            id: dh; target: null; dragThreshold: 8; enabled: root.en
            onActiveChanged: { var s = root.seen.slice(); s.push((active ? "on " : "off ") + translation.x + "," + translation.y); root.seen = s; }
            onCentroidChanged: if (active) root.moves++
        }
    }
    TestCase {
        name: "QtDragHandlerFacts"; when: windowShown
        function test_translation_is_zero_when_it_becomes_active() {
            root.seen = [];
            mousePress(root, 150, 150, Qt.LeftButton);
            for (var i = 1; i <= 6; i++) mouseMove(root, 150, 150 + i * 10, 16, Qt.LeftButton);
            mouseRelease(root, 150, 210, Qt.LeftButton);
            compare(root.seen[0], "on 0,0", "a 60 px pull straight down reports no translation at activation");
        }
        function test_disabled_while_active_freezes_until_release() {
            root.seen = []; root.en = true;
            mousePress(root, 150, 150, Qt.LeftButton);
            for (var i = 1; i <= 4; i++) mouseMove(root, 150 + i * 10, 150, 16, Qt.LeftButton);
            verify(dh.active);
            root.en = false;
            var m = root.moves;
            for (i = 1; i <= 4; i++) mouseMove(root, 200 + i * 10, 150, 16, Qt.LeftButton);
            compare(dh.active, true, "still active after being disabled");
            compare(root.moves, m, "no centroid updates while disabled");
            mouseRelease(root, 240, 150, Qt.LeftButton);
            compare(dh.active, false, "lets go at the release");
            root.en = true;
        }
    }
}
