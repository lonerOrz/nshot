import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: root

    property var targetScreen: null
    property var modes: ["save", "copy", "ocr", "annotate", "lens"]
    property string currentMode: "save"
    property string fullScreenshot: ""  // temp file, cleaned up
    property string savedFile: ""       // permanent, NOT cleaned up

    // Mode labels: icon + text for each mode
    readonly property var modeLabels: ({
        "ocr": "󰈙 OCR",
        "lens": "󰍉 Lens",
        "copy": "󰆏 Copy",
        "save": "󰋮 Save",
        "annotate": "󰈊 Draw"
    })

    // Helper: Shell-escape a string
    function shellEscape(str) {
        return "'" + str.replace(/'/g, "'\\''") + "'";
    }

    // Helper: Format current date for filename
    function formatTimestamp() {
        const d = new Date();
        const pad = n => String(n).padStart(2, '0');
        return `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    }

    // Helper: Build the crop command (shared by all modes)
    function buildCrop(w, h, x, y) {
        return `magick ${shellEscape(root.fullScreenshot)} -crop ${w}x${h}+${x}+${y}`;
    }

    // Unified cleanup function - only clean up temp files (fullScreenshot)
    function cleanupFiles() {
        if (root.fullScreenshot)
            Quickshell.execDetached(["rm", "-f", root.fullScreenshot]);
    }

    // Action execution flags
    property bool doCleanup: false
    property bool doQuit: false
    property bool doDelayedCleanup: false

    function executeAction() {
        if (!root.targetScreen)
            return;

        const scale = root.targetScreen.scale ?? 1;
        const x = Math.round(selector.selectionX * scale);
        const y = Math.round(selector.selectionY * scale);
        const w = Math.round(selector.selectionWidth * scale);
        const h = Math.round(selector.selectionHeight * scale);

        if (w < 10 || h < 10)
            return;

        root.visible = false;
        doCleanup = false;
        doQuit = false;
        doDelayedCleanup = false;

        const crop = buildCrop(w, h, x, y);

        if (root.currentMode === "ocr") {
            const cmd = [
                `${crop} -colorspace gray -sharpen 0x1 -level 50%,100% png:-`,
                `tesseract - - -l eng+chi_sim`,
                `awk 'BEGIN{RS=""; FS="\\n"; ORS="\\n\\n"} {for(i=1;i<=NF;i++){printf "%s ",$i} printf "\\n"}'`,
                `wl-copy`,
                `notify-send 'OCR Complete' 'Text copied to clipboard'`
            ].join(" | ");
            proc.command = ["sh", "-c", cmd];
            doCleanup = true;
            doQuit = true;
            proc.running = true;

        } else if (root.currentMode === "lens") {
            const tmpJpg = Quickshell.cachePath(`snip-crop-${Date.now()}.jpg`);
            const tmpHtml = Quickshell.cachePath(`snip-lens-${Date.now()}.html`);

            const cmd = [
                `${crop} -resize '1000x1000>' -strip -quality 85 ${shellEscape(tmpJpg)}`,
                `B64=$(base64 -w0 ${shellEscape(tmpJpg)})`,
                `echo "<html><head><meta charset='utf-8'></head><body style='margin:0;display:flex;justify-content:center;align-items:center;height:100vh;background:#111;color:#fff;font-family:system-ui;font-size:24px'><div>Searching with Google Lens...</div><form id='f' method='POST' enctype='multipart/form-data' action='https://lens.google.com/v3/upload'></form><script>var b=atob('\"'\"'$B64'\"'\"');var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);var d=new DataTransfer();d.items.add(new File([a],'i.jpg',{type:'image/jpeg'}));var inp=document.createElement('input');inp.type='file';inp.name='encoded_image';inp.files=d.files;document.getElementById('f').appendChild(inp);document.getElementById('f').submit();</script></body></html>" > ${shellEscape(tmpHtml)}`,
                `sleep 0.2 && xdg-open ${shellEscape(tmpHtml)} &`
            ].join(" && ");
            proc.command = ["sh", "-c", cmd];
            doCleanup = true;
            doQuit = true;
            doDelayedCleanup = true;
            proc.running = true;

        } else if (root.currentMode === "copy") {
            const cmd = `${crop} png:- | wl-copy -t image/png && notify-send 'Copied' 'Screenshot copied to clipboard'`;
            proc.command = ["sh", "-c", cmd];
            doCleanup = true;
            doQuit = true;
            proc.running = true;

        } else if (root.currentMode === "save") {
            const saveDir = Quickshell.env("HOME") + "/Pictures/Screenshots";
            root.savedFile = `${saveDir}/Screenshot_${formatTimestamp()}.png`;
            const cmd = [
                `mkdir -p ${shellEscape(saveDir)}`,
                `${crop} ${shellEscape(root.savedFile)}`,
                `wl-copy -t image/png < ${shellEscape(root.savedFile)}`,
                `notify-send 'Saved' "Screenshot saved to ${root.savedFile}"`
            ].join(" && ");
            proc.command = ["sh", "-c", cmd];
            doCleanup = true;
            doQuit = true;
            proc.running = true;

        } else if (root.currentMode === "annotate") {
            const outFile = Quickshell.cachePath(`snip-annotate-${Date.now()}.png`);
            const cmd = [
                `${crop} ${shellEscape(outFile)}`,
                `satty --filename ${shellEscape(outFile)} --fullscreen --output-filename ${shellEscape(outFile + ".png")} --early-exit`,
                `wl-copy < ${shellEscape(outFile + ".png")}`,
                `notify-send 'Annotated' 'Screenshot saved and copied'`
            ].join(" && ");
            proc.command = ["sh", "-c", cmd];
            doCleanup = true;
            doQuit = true;
            proc.running = true;
        }
    }

    function finishInit() {
        if (!root.targetScreen) {
            console.error("Cannot init: targetScreen is null");
            return;
        }
        root.fullScreenshot = Quickshell.cachePath(`snip-${Date.now()}.png`);
        grimProc.running = true;
    }

    function tryInit() {
        let found = null;
        for (const screen of Quickshell.screens) {
            if (screen.cursorPosition) {
                found = screen;
                break;
            }
        }

        if (!found && Quickshell.screens.length > 0) {
            found = Quickshell.screens[0];
        }

        root.targetScreen = found;

        if (root.targetScreen) {
            initTimer.stop();
            finishInit();
            return true;
        }
        return false;
    }

    screen: targetScreen
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    visible: false

    Component.onCompleted: {
        Qt.callLater(tryInit);
    }

    Timer {
        id: initTimer
        interval: 100
        repeat: true
        running: true
        onTriggered: tryInit()
    }

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    ScreencopyView {
        id: screenCopy
        captureSource: root.targetScreen
        anchors.fill: parent
        z: -1
    }

    Process {
        id: grimProc
        command: root.targetScreen ? ["grim", "-o", root.targetScreen.name, root.fullScreenshot] : ["true"]
        onExited: (code) => {
            if (code === 0 && root.targetScreen) {
                root.visible = true;
            } else {
                console.error("grim failed:", code);
                if (!root.visible)
                    retryTimer.start();
                else
                    Qt.quit();
            }
        }
    }

    Timer {
        id: retryTimer
        interval: 200
        onTriggered: {
            if (root.targetScreen)
                grimProc.running = true;
        }
    }

    Process {
        id: proc
        onExited: (code) => {
            if (code !== 0)
                console.error("Action failed:", code);

            if (root.doCleanup)
                cleanupFiles();

            if (root.doDelayedCleanup) {
                // Delayed cleanup for lens (wait for browser to finish)
                cleanupTimer.interval = 10000;
                cleanupTimer.running = true;
            }

            if (root.doQuit)
                Qt.quit();
        }
    }

    Timer {
        id: cleanupTimer
        running: false
        repeat: false
        onTriggered: cleanupFiles()
    }

    Item {
        id: selector

        property real selectionX: 0
        property real selectionY: 0
        property real selectionWidth: 0
        property real selectionHeight: 0
        property point startPos
        property real mouseX: 0
        property real mouseY: 0

        anchors.fill: parent
        z: 1

        ShaderEffect {
            property vector4d selectionRect: Qt.vector4d(selector.selectionX, selector.selectionY, selector.selectionWidth, selector.selectionHeight)
            property real dimOpacity: 0.5
            property vector2d screenSize: Qt.vector2d(selector.width, selector.height)
            property real borderRadius: 4
            property real outlineThickness: 1

            anchors.fill: parent
            fragmentShader: Qt.resolvedUrl("./shader/dimming.frag.qsb")
        }

        // Crosshair guides using dashed lines
        Canvas {
            id: guides
            anchors.fill: parent
            z: 2

            onPaint: {
                if (mouseArea.pressed) return;

                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.strokeStyle = "rgba(255, 255, 255, 0.5)";
                ctx.lineWidth = 1;
                ctx.setLineDash([5, 5]);

                // Vertical
                ctx.beginPath();
                ctx.moveTo(selector.mouseX, 0);
                ctx.lineTo(selector.mouseX, height);
                ctx.stroke();

                // Horizontal
                ctx.beginPath();
                ctx.moveTo(0, selector.mouseY);
                ctx.lineTo(width, selector.mouseY);
                ctx.stroke();
            }

            Connections {
                target: selector
                function onMouseXChanged() { guides.requestPaint(); }
                function onMouseYChanged() { guides.requestPaint(); }
            }
        }

        // Border around selection
        Rectangle {
            x: selector.selectionX
            y: selector.selectionY
            width: selector.selectionWidth
            height: selector.selectionHeight
            color: "transparent"
            border.color: "white"
            border.width: 1
            visible: mouseArea.pressed && selector.selectionWidth > 0
            z: 2
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.CrossCursor
            onPressed: (mouse) => {
                if (mouse.button === Qt.RightButton)
                    return;
                selector.startPos = Qt.point(mouse.x, mouse.y);
                selector.selectionX = mouse.x;
                selector.selectionY = mouse.y;
                selector.selectionWidth = 0;
                selector.selectionHeight = 0;
            }
            onPositionChanged: (mouse) => {
                selector.mouseX = mouse.x;
                selector.mouseY = mouse.y;
                if (pressed && mouse.buttons & Qt.LeftButton) {
                    selector.selectionX = Math.min(selector.startPos.x, mouse.x);
                    selector.selectionY = Math.min(selector.startPos.y, mouse.y);
                    selector.selectionWidth = Math.abs(mouse.x - selector.startPos.x);
                    selector.selectionHeight = Math.abs(mouse.y - selector.startPos.y);
                }
            }
            onReleased: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    selector.selectionX = 0;
                    selector.selectionY = 0;
                    selector.selectionWidth = 0;
                    selector.selectionHeight = 0;
                    return;
                }
                if (selector.selectionWidth > 10 && selector.selectionHeight > 10)
                    root.executeAction();
            }
        }

        // Size label
        Rectangle {
            visible: mouseArea.pressed && selector.selectionWidth > 20
            x: selector.selectionX + selector.selectionWidth / 2 - width / 2
            y: selector.selectionY - 35
            width: sizeLabel.implicitWidth + 16
            height: sizeLabel.implicitHeight + 8
            radius: 6
            color: Qt.rgba(0, 0, 0, 0.7)
            z: 100

            Text {
                id: sizeLabel
                anchors.centerIn: parent
                text: `${Math.round(selector.selectionWidth)} × ${Math.round(selector.selectionHeight)}`
                color: "white"
                font.pixelSize: 12
                font.family: "monospace"
            }
        }
    }

    // Mode selection bar
    Rectangle {
        id: controlBar
        z: 10
        width: 500
        height: 50
        radius: height / 2
        color: Qt.rgba(0.15, 0.15, 0.15, 0.4)
        border.color: Qt.rgba(1, 1, 1, 0.15)
        border.width: 1
        layer.enabled: true

        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
            bottomMargin: 60
        }

        Rectangle {
            id: highlight
            height: parent.height - 8
            width: (parent.width - 8) / root.modes.length
            y: 4
            radius: height / 2
            color: "#cba6f7"
            x: 4 + (root.modes.indexOf(root.currentMode) * width)

            Behavior on x {
                SpringAnimation {
                    spring: 4
                    damping: 0.25
                    mass: 1
                }
            }
        }

        Row {
            anchors.fill: parent
            anchors.margins: 4

            Repeater {
                model: root.modes

                Item {
                    width: (controlBar.width - 8) / root.modes.length
                    height: controlBar.height - 8

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.currentMode = modelData
                    }

                    Text {
                        anchors.centerIn: parent
                        text: root.modeLabels[modelData]
                        color: root.currentMode === modelData ? "#11111b" : "#AAFFFFFF"
                        font.weight: root.currentMode === modelData ? Font.Bold : Font.Medium
                        font.pixelSize: 13
                        font.family: "Symbols Nerd Font"
                    }
                }
            }
        }

        layer.effect: DropShadow {
            transparentBorder: true
            radius: 8
            samples: 16
            color: "#80000000"
        }
    }

    // Tab/Shift+Tab to cycle modes
    Shortcut {
        sequences: ["Tab", "Shift+Tab"]
        onActivated: {
            const i = root.modes.indexOf(root.currentMode);
            const delta = (sequence === "Tab") ? 1 : -1;
            root.currentMode = root.modes[(i + delta + root.modes.length) % root.modes.length];
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: {
            cleanupFiles();
            Qt.quit();
        }
    }

    Item {
        anchors.fill: parent
        z: 999

        HoverHandler {
            target: null
            onPointChanged: {
                if (!mouseArea.pressed) {
                    selector.mouseX = point.position.x;
                    selector.mouseY = point.position.y;
                }
            }
        }
    }
}
