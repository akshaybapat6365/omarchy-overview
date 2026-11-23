import QtQuick
import QtQuick.Effects

// ResultPill — the one bold pill at the bottom centre that reports an operation (SPEC 2.4).
// Owner: lane 2.
//
// FROZEN CONTRACT (SPEC 2.4, amendments A3/A4):
//   success   accent pill "Moved · Undo" (Undo is a button, Ctrl+Z too), 4 s
//   failure   bold amber pill "Couldn't move it — nothing changed", 2.4 s
//   words     plain English only; never a window title
//   API       show(kind: "ok"|"fail", text), signal undoRequested()
// Lane 2 extras: show(kind, text, undoable) (third argument optional, default false), hide(), shownKind, shownText.
//
// Design: a crisp frosted-glass HUD capsule with a quiet hairline rim, layered elevation shadow,
// and a small accent (or amber) status dot; when undoable, a concentric filled accent pill holds
// "Undo" so it reads unmistakably as an interactive button on both dark and light themes.
// It rises 12 u and scales in from 0.94 (180 ms OutCubic) and leaves the same way; nothing about
// it takes the keyboard.
Item {
    id: pill
    required property var scene
    signal undoRequested()

    property string shownKind: ""
    property string shownText: ""
    property bool undoable: false
    property bool up: false
    readonly property real u: scene.u
    readonly property bool failure: shownKind === "fail"
    readonly property color glassFill: failure
                                       ? (scene.lightMode ? Qt.rgba(1.0, 0.97, 0.90, 0.96) : Qt.rgba(0.16, 0.11, 0.06, 0.92))
                                       : (scene.lightMode ? Qt.rgba(1, 1, 1, 0.92) : Qt.rgba(0.10, 0.11, 0.15, 0.88))
    readonly property color glassRim: failure
                                      ? Qt.rgba(scene.amber.r, scene.amber.g, scene.amber.b, scene.lightMode ? 0.65 : 0.60)
                                      : (scene.lightMode ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.18))
    readonly property color ink: failure ? (scene.lightMode ? "#6a4000" : "#ffd58a") : scene.ink
    readonly property color dotColor: failure ? scene.amber : scene.accent

    function show(kind, text, canUndo) {
        shownKind = kind === "fail" ? "fail" : "ok";
        shownText = String(text || "");
        undoable = !!canUndo && !failure;
        up = true;
        life.interval = failure ? 2400 : 4000;
        life.restart();
    }
    function hide() { up = false; life.stop(); }
    // Where the Undo button is, in scene coordinates (status and the stage's real pointer; no words).
    function undoRect() {
        if (!undoBtn.visible) return null;
        var r = undoBtn.mapToItem(pill.scene, 0, 0, undoBtn.width, undoBtn.height);
        return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
    }
    Timer { id: life; onTriggered: pill.up = false }

    anchors.horizontalCenter: parent.horizontalCenter
    width: body.width
    height: 48 * u
    y: parent.height - height - 38 * u + (up ? 0 : 12 * u)
    Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    opacity: up ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    scale: up ? 1 : 0.94
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    visible: opacity > 0.01
    z: 2000

    RectangularShadow {
        anchors.fill: body
        radius: body.radius
        blur: 32 * pill.u
        offset: Qt.vector2d(0, 10 * pill.u)
        color: pill.scene.lightMode ? Qt.rgba(0.05, 0.07, 0.15, 0.22) : Qt.rgba(0, 0, 0, 0.58)
    }
    RectangularShadow {
        anchors.fill: body
        radius: body.radius
        blur: 8 * pill.u
        offset: Qt.vector2d(0, 2 * pill.u)
        color: pill.scene.contactColor
    }
    Rectangle {
        id: body
        height: parent.height
        width: row.implicitWidth + 18 * pill.u + (pill.undoable ? 8 : 20) * pill.u
        radius: height / 2
        color: pill.glassFill
        border.width: Math.max(1, pill.u)
        border.color: pill.glassRim
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }
        // Crisp 1px top specular highlight along the frosted HUD capsule rim.
        Rectangle {
            anchors.top: parent.top
            anchors.topMargin: Math.max(1, pill.u)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: body.radius * 0.85
            anchors.rightMargin: body.radius * 0.85
            height: Math.max(1, pill.u)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.22; color: Qt.rgba(1, 1, 1, pill.scene.lightMode ? 0.84 : (pill.failure ? 0.20 : 0.26)) }
                GradientStop { position: 0.78; color: Qt.rgba(1, 1, 1, pill.scene.lightMode ? 0.84 : (pill.failure ? 0.20 : 0.26)) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Row {
            id: row
            anchors.verticalCenter: parent.verticalCenter
            x: 18 * pill.u
            spacing: 10 * pill.u
            Rectangle {
                width: 8 * pill.u
                height: width
                radius: width / 2
                color: pill.dotColor
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pill.shownText
                color: pill.ink
                font.family: pill.scene.uiFont
                font.pixelSize: 16 * pill.u
                font.weight: Font.DemiBold
                font.letterSpacing: -0.1 * pill.u
            }
            Text {
                visible: pill.undoable
                anchors.verticalCenter: parent.verticalCenter
                text: "·"
                color: Qt.rgba(pill.ink.r, pill.ink.g, pill.ink.b, 0.42)
                font.family: pill.scene.uiFont
                font.pixelSize: 16 * pill.u
                font.weight: Font.Bold
            }
            Rectangle {
                id: undoBtn
                visible: pill.undoable
                anchors.verticalCenter: parent.verticalCenter
                height: 32 * pill.u
                width: undoText.implicitWidth + 26 * pill.u
                radius: height / 2
                color: undoMouse.pressed ? Qt.darker(pill.scene.accent, 1.15)
                       : undoMouse.containsMouse ? Qt.lighter(pill.scene.accent, 1.12)
                       : pill.scene.accent
                scale: undoMouse.pressed ? 0.96 : 1
                Behavior on color { ColorAnimation { duration: 100 } }
                Behavior on scale { NumberAnimation { duration: 80 } }
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: Math.max(1, pill.u)
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: undoBtn.radius * 0.8
                    anchors.rightMargin: undoBtn.radius * 0.8
                    height: Math.max(1, pill.u)
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.25; color: Qt.rgba(1, 1, 1, 0.34) }
                        GradientStop { position: 0.75; color: Qt.rgba(1, 1, 1, 0.34) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
                Text {
                    id: undoText
                    anchors.centerIn: parent
                    text: "Undo"
                    color: pill.scene.accentInk
                    font.family: pill.scene.uiFont
                    font.pixelSize: 14.5 * pill.u
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    id: undoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { pill.hide(); pill.undoRequested(); }
                }
            }
        }
    }
}
