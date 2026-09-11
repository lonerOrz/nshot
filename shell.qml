import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
  id: root

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  visible: false

  anchors {
    left: true
    right: true
    top: true
    bottom: true
  }

  onVisibleChanged: {
    if (visible) {
      mouseArea.forceActiveFocus();
      dockEntranceAnim.start();
    }
  }

  readonly property var modes: ["save", "copy", "satty", "ocr", "lens"]
  property string currentMode: "save"
  property string fullScreenshot: ""
  property var tempFiles: []
  property bool doQuit: false

  readonly property var modeMeta: ({
                                     "save": {
                                       name: "Save",
                                       icon: "󰋮"
                                     },
                                     "copy": {
                                       name: "Copy",
                                       icon: "󰆏"
                                     },
                                     "satty": {
                                       name: "Annotate",
                                       icon: "󰈊"
                                     },
                                     "ocr": {
                                       name: "OCR",
                                       icon: "󰈙"
                                     },
                                     "lens": {
                                       name: "Visual",
                                       icon: "󰍉"
                                     }
                                   })

  function cycleMode(delta) {
    let idx = root.modes.indexOf(root.currentMode);
    let nextIdx = (idx + delta + root.modes.length) % root.modes.length;
    root.currentMode = root.modes[nextIdx];
  }

  function shellEscape(str) {
    return "'" + String(str).replace(/'/g, "'\\''") + "'";
  }

  function formatTimestamp() {
    const d = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  }

  function getTempPath(prefix, ext) {
    return `/dev/shm/${prefix}-${Date.now()}.${ext}`;
  }

  function cleanupFiles() {
    const files = root.tempFiles.filter(f => !!f);
    if (files.length > 0) {
      Quickshell.execDetached(["rm", "-f", ...files]);
    }
    root.tempFiles = [];
    root.fullScreenshot = "";
  }

  function buildCrop(w, h, x, y) {
    return `magick ${shellEscape(root.fullScreenshot)} -crop ${w}x${h}+${x}+${y} +repage +dither`;
  }

  // 写入 /dev/shm 内存盘并使用 -l 0 无压缩输出，消减磁盘 I/O 阻塞加速响应
  function initCapture() {
    if (root.fullScreenshot === "" && !grimProc.running) {
      cursorFetcher.running = true;
      root.fullScreenshot = getTempPath("nshot-raw", "png");
      root.tempFiles.push(root.fullScreenshot);

      const cmd = ["grim", "-l", "0"];
      if (root.screen && root.screen.name) {
        cmd.push("-o", root.screen.name);
      }
      cmd.push(root.fullScreenshot);

      grimProc.command = cmd;
      grimProc.running = true;
    }
  }

  function executeAction() {
    if (!root.fullScreenshot)
      return;

    const scaleFactor = (bgImage.sourceSize.width > 0 && root.width > 0) ? (bgImage.sourceSize.width / root.width) : (root.screen ? root.screen.scale : 1);
    const x = Math.round(selector.selectionX * scaleFactor);
    const y = Math.round(selector.selectionY * scaleFactor);
    const w = Math.round(selector.selectionWidth * scaleFactor);
    const h = Math.round(selector.selectionHeight * scaleFactor);

    if (w < 8 || h < 8)
      return;

    root.visible = false;
    root.doQuit = true;

    const crop = buildCrop(w, h, x, y);
    const homeDir = Quickshell.env("HOME") || "";
    const saveDir = homeDir ? `${homeDir}/Pictures/Screenshots` : "/tmp";

    if (root.currentMode === "save") {
      const savedFile = `${saveDir}/Screenshot_${formatTimestamp()}.png`;
      const cmd = [`mkdir -p ${shellEscape(saveDir)}`, `${crop} ${shellEscape(savedFile)}`, `wl-copy -t image/png < ${shellEscape(savedFile)}`, `notify-send -i ${shellEscape(savedFile)} 'Saved' ${shellEscape(savedFile)}`].join(" && ");
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "copy") {
      const cmd = `${crop} png:- | wl-copy -t image/png && notify-send 'Copied' 'Image copied to clipboard'`;
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "satty") {
      const outFile = getTempPath("snip-satty", "png");
      const targetFile = `${saveDir}/Screenshot_${formatTimestamp()}.png`;
      root.tempFiles.push(outFile);

      const cmd = [`mkdir -p ${shellEscape(saveDir)}`, `${crop} ${shellEscape(outFile)}`, `satty -f ${shellEscape(outFile)} -o ${shellEscape(targetFile)} --fullscreen --early-exit`, `[ -f ${shellEscape(targetFile)} ] && wl-copy -t image/png < ${shellEscape(targetFile)} && notify-send 'Satty' 'Saved to disk'`].join(" && ");
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "ocr") {
      const ocrFilter = `${crop} -colorspace gray -filter Lanczos -resize 200% -density 300 -resample 300 -contrast-stretch 1%x1% png:-`;
      const cmd = [ocrFilter, `tesseract - - -l eng+chi_sim --psm 6`, `awk 'BEGIN{RS=""; FS="\\n"; ORS="\\n\\n"} {for(i=1;i<=NF;i++){printf "%s ",$i} printf "\\n"}'`, `wl-copy`].join(" | ") + ` && notify-send 'OCR Finished' 'Text copied to clipboard'`;
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "lens") {
      const rawScreenshot = root.fullScreenshot;
      const tmpJpg = getTempPath("snip-lens", "jpg");
      const tmpHtml = getTempPath("snip-lens", "html");

      root.tempFiles = [];
      root.fullScreenshot = "";

      const buildHtml
            = [`echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Lens</title></head><body style="margin:0;display:flex;justify-content:center;align-items:center;height:100vh;background:#141218;color:#e6e1e5;font-family:system-ui"><p>Searching visual...</p><form id="f" method="POST" enctype="multipart/form-data"><input type="hidden" name="processed_image_dimensions" value="'"$DIM"'"></form><script>'`,
               `echo 'var b=atob("'"$B64"'");'`,
               `echo 'var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);var d=new DataTransfer();d.items.add(new File([a],"image.jpg",{type:"image/jpeg"}));var inp=document.createElement("input");inp.type="file";inp.name="encoded_image";inp.files=d.files;var f=document.getElementById("f");f.appendChild(inp);f.action="https://lens.google.com/v3/upload?ep=ccm&s=&st="+Date.now();f.submit();'`,
               `echo '</script></body></html>'`].join(" ; ");

      const cmd = [`${crop} -resize '1200x1200>' -strip -quality 92 ${shellEscape(tmpJpg)}`, `DIM=$(magick identify -format "%w,%h" ${shellEscape(tmpJpg)} 2>/dev/null || echo "1200,1200")`, `B64=$(base64 -w0 ${shellEscape(tmpJpg)} 2>/dev/null || base64 -b0 ${shellEscape(tmpJpg)})`, `[ -n "$B64" ]`, `{ ${buildHtml} ; } > ${shellEscape(tmpHtml)}`, `xdg-open 
${shellEscape(tmpHtml)}`].join(" && ") + ` ; (sleep 15 && rm -f ${shellEscape(rawScreenshot)} ${shellEscape(tmpJpg)} ${shellEscape(tmpHtml)}) &`;

      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    }
  }

  onScreenChanged: initCapture()
  Component.onCompleted: initCapture()

  Process {
    id: cursorFetcher
    command: ["hyprctl", "cursorpos"]
    stdout: SplitParser {
      onRead: data => {
        const parts = data.trim().split(",");
        if (parts.length === 2) {
          const cx = parseFloat(parts[0]);
          const cy = parseFloat(parts[1]);
          if (!isNaN(cx) && !isNaN(cy) && !selector.mouseMoved) {
            const screenX = root.screen ? root.screen.x : 0;
            const screenY = root.screen ? root.screen.y : 0;
            selector.mouseX = cx - screenX;
            selector.mouseY = cy - screenY;
            selector.hasPointer = true;
          }
        }
      }
    }
  }

  Process {
    id: grimProc
    onExited: code => {
      if (code === 0) {
        bgImage.source = "file://" + root.fullScreenshot;
        root.visible = true;
      } else {
        cleanupFiles();
        Qt.quit();
      }
    }
  }

  Process {
    id: proc
    onExited: code => {
      cleanupFiles();
      if (root.doQuit)
        Qt.quit();
    }
  }

  Image {
    id: bgImage
    anchors.fill: parent
    asynchronous: false
    cache: false
    smooth: false
    mipmap: false
    z: 0
  }

  Item {
    id: selector
    anchors.fill: parent
    z: 1

    property real selectionX: 0
    property real selectionY: 0
    property real selectionWidth: 0
    property real selectionHeight: 0
    property point startPos
    property real mouseX: 0
    property real mouseY: 0
    property bool mouseMoved: false
    property bool hasPointer: false

    Item {
      id: dimMask
      anchors.fill: parent
      property bool active: selector.selectionWidth > 0 && selector.selectionHeight > 0

      Rectangle {
        x: 0
        y: 0
        width: parent.width
        height: dimMask.active ? selector.selectionY : parent.height
        color: Qt.rgba(0.04, 0.04, 0.06, 0.48)
      }
      Rectangle {
        x: 0
        y: selector.selectionY + selector.selectionHeight
        width: parent.width
        height: Math.max(0, parent.height - y)
        color: Qt.rgba(0.04, 0.04, 0.06, 0.48)
        visible: dimMask.active
      }
      Rectangle {
        x: 0
        y: selector.selectionY
        width: selector.selectionX
        height: selector.selectionHeight
        color: Qt.rgba(0.04, 0.04, 0.06, 0.48)
        visible: dimMask.active
      }
      Rectangle {
        x: selector.selectionX + selector.selectionWidth
        y: selector.selectionY
        width: Math.max(0, parent.width - x)
        height: selector.selectionHeight
        color: Qt.rgba(0.04, 0.04, 0.06, 0.48)
        visible: dimMask.active
      }
    }

    Shape {
      anchors.fill: parent
      visible: !mouseArea.pressed && (selector.hasPointer || mouseArea.containsMouse || selector.mouseMoved)
      z: 2

      ShapePath {
        strokeColor: Qt.rgba(1, 1, 1, 0.28)
        strokeWidth: 1
        fillColor: "transparent"
        strokeStyle: ShapePath.DashLine
        dashPattern: [3, 4]
        startX: selector.mouseX
        startY: 0
        PathLine {
          x: selector.mouseX
          y: selector.height
        }
      }
      ShapePath {
        strokeColor: Qt.rgba(1, 1, 1, 0.28)
        strokeWidth: 1
        fillColor: "transparent"
        strokeStyle: ShapePath.DashLine
        dashPattern: [3, 4]
        startX: 0
        startY: selector.mouseY
        PathLine {
          x: selector.width
          y: selector.mouseY
        }
      }
    }

    Rectangle {
      x: selector.selectionX
      y: selector.selectionY
      width: selector.selectionWidth
      height: selector.selectionHeight
      color: "transparent"
      border.color: "#A8C7FA"
      border.width: 1.5
      visible: mouseArea.pressed && selector.selectionWidth > 0
      z: 3

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.66, 0.78, 0.98, 0.05)
      }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      focus: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.CrossCursor

      Keys.onEscapePressed: {
        cleanupFiles();
        Qt.quit();
      }
      Keys.onTabPressed: event => {
        root.cycleMode(event.modifiers & Qt.ShiftModifier ? -1 : 1);
        event.accepted = true;
      }
      Keys.onBacktabPressed: root.cycleMode(-1)

      onEntered: selector.hasPointer = true

      onPressed: mouse => {
        if (mouse.button === Qt.RightButton) {
          cleanupFiles();
          Qt.quit();
          return;
        }
        selector.startPos = Qt.point(mouse.x, mouse.y);
        selector.selectionX = mouse.x;
        selector.selectionY = mouse.y;
        selector.selectionWidth = 0;
        selector.selectionHeight = 0;
      }

      onPositionChanged: mouse => {
        selector.hasPointer = true;
        selector.mouseMoved = true;
        selector.mouseX = mouse.x;
        selector.mouseY = mouse.y;
        if (pressed && (mouse.buttons & Qt.LeftButton)) {
          selector.selectionX = Math.min(selector.startPos.x, mouse.x);
          selector.selectionY = Math.min(selector.startPos.y, mouse.y);
          selector.selectionWidth = Math.abs(mouse.x - selector.startPos.x);
          selector.selectionHeight = Math.abs(mouse.y - selector.startPos.y);
        }
      }

      onReleased: mouse => {
        if (mouse.button === Qt.RightButton) {
          cleanupFiles();
          Qt.quit();
          return;
        }
        if (selector.selectionWidth > 8 && selector.selectionHeight > 8) {
          root.executeAction();
        }
      }
    }

    Rectangle {
      visible: mouseArea.pressed && selector.selectionWidth > 20
      x: Math.max(12, Math.min(parent.width - width - 12, selector.selectionX + selector.selectionWidth / 2 - width / 2))
      y: (selector.selectionY > 40) ? selector.selectionY - 32 : selector.selectionY + selector.selectionHeight + 10
      width: sizeContent.implicitWidth + 18
      height: 24
      radius: 6
      color: "#1E1F24"
      border.color: Qt.rgba(1, 1, 1, 0.15)
      border.width: 1
      z: 10

      Row {
        id: sizeContent
        anchors.centerIn: parent
        spacing: 4
        Text {
          text: `${Math.round(selector.selectionWidth)} × ${Math.round(selector.selectionHeight)}`
          color: "#E2E2E9"
          font.pixelSize: 11
          font.weight: Font.DemiBold
          font.family: "JetBrains Mono, monospace"
        }
      }
    }
  }

  // MD3 适中紧凑型底栏（Squircle 现代圆角 + 物理弹簧位移动效）
  Item {
    id: dock
    z: 20
    anchors {
      bottom: parent.bottom
      horizontalCenter: parent.horizontalCenter
      bottomMargin: 32
    }
    width: m3Bar.width
    height: m3Bar.height + m3Hints.height + 10

    ParallelAnimation {
      id: dockEntranceAnim
      NumberAnimation {
        target: dock
        property: "opacity"
        from: 0.0
        to: 1.0
        duration: 220
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: dock
        property: "anchors.bottomMargin"
        from: 16
        to: 32
        duration: 260
        easing.type: Easing.OutBack
      }
    }

    readonly property int itemWidth: 88
    readonly property int itemHeight: 38

    Rectangle {
      id: m3Bar
      width: (dock.itemWidth * root.modes.length) + 8
      height: 46
      radius: 12
      color: Qt.rgba(0.09, 0.10, 0.12, 0.90)
      border.color: Qt.rgba(1, 1, 1, 0.12)
      border.width: 1

      // 独立的 MD3 动态指示滑块
      Rectangle {
        id: activePill
        y: 4
        height: dock.itemHeight
        width: dock.itemWidth
        radius: 8
        color: "#A8C7FA"

        readonly property int currentIndex: Math.max(0, root.modes.indexOf(root.currentMode))
        x: 4 + (currentIndex * dock.itemWidth)

        Behavior on x {
          NumberAnimation {
            duration: 280
            easing.type: Easing.OutBack
            easing.overshoot: 1.15
          }
        }
      }

      Row {
        id: modeFlow
        anchors.centerIn: parent

        Repeater {
          model: root.modes

          Item {
            id: tabBtn
            readonly property string mId: modelData
            readonly property var mMeta: root.modeMeta[mId]
            readonly property bool active: root.currentMode === mId

            width: dock.itemWidth
            height: dock.itemHeight

            Rectangle {
              anchors.fill: parent
              radius: 8
              color: Qt.rgba(1, 1, 1, 0.06)
              visible: tabMouse.containsMouse && !tabBtn.active
            }

            Row {
              anchors.centerIn: parent
              spacing: 6

              Text {
                text: tabBtn.mMeta.icon
                font.family: "Symbols Nerd Font, monospace"
                font.pixelSize: 15
                anchors.verticalCenter: parent.verticalCenter
                color: tabBtn.active ? "#062E6F" : "#C4C6D0"
                Behavior on color {
                  ColorAnimation {
                    duration: 160
                  }
                }
              }

              Text {
                text: tabBtn.mMeta.name
                font.family: "Inter, Roboto, system-ui, sans-serif"
                font.pixelSize: 12
                font.weight: tabBtn.active ? Font.Bold : Font.Medium
                anchors.verticalCenter: parent.verticalCenter
                color: tabBtn.active ? "#062E6F" : "#E2E2E9"
                Behavior on color {
                  ColorAnimation {
                    duration: 160
                  }
                }
              }
            }

            MouseArea {
              id: tabMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.currentMode = tabBtn.mId
            }
          }
        }
      }
    }

    Row {
      id: m3Hints
      anchors.top: m3Bar.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: m3Bar.horizontalCenter
      spacing: 14

      Repeater {
        model: [
          {
            k: "Tab",
            l: "Switch"
          },
          {
            k: "Esc",
            l: "Quit"
          },
          {
            k: "R-Click",
            l: "Cancel"
          }
        ]

        Row {
          spacing: 6
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            width: hintKeyText.implicitWidth + 8
            height: 18
            radius: 4
            color: "#22242A"
            border.color: Qt.rgba(1, 1, 1, 0.22)
            border.width: 1

            Text {
              id: hintKeyText
              anchors.centerIn: parent
              text: modelData.k
              font.pixelSize: 10
              font.weight: Font.Bold
              font.family: "JetBrains Mono, monospace"
              color: "#E2E2E9"
            }
          }

          Text {
            text: modelData.l
            font.family: "Inter, system-ui, sans-serif"
            font.pixelSize: 11
            font.weight: Font.Medium
            color: "#C4C6D0"
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }

  Shortcut {
    sequence: "Tab"
    onActivated: root.cycleMode(1)
  }
  Shortcut {
    sequence: "Shift+Tab"
    onActivated: root.cycleMode(-1)
  }
  Shortcut {
    sequence: "Escape"
    onActivated: {
      cleanupFiles();
      Qt.quit();
    }
  }
}
