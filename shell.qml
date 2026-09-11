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

  onVisibleChanged: {
    if (visible) {
      mouseArea.forceActiveFocus();
    }
  }

  // 模式与状态
  property var modes: ["save", "copy", "satty", "ocr", "lens"]
  property string currentMode: "save"
  property string fullScreenshot: ""
  property string savedFile: ""
  property var tempFiles: []
  property bool doQuit: false

  // 依赖检测表
  property var installedTools: ({
                                  "grim": true,
                                  "magick": true,
                                  "wl-copy": true,
                                  "satty": false,
                                  "tesseract": false,
                                  "xdg-open": false
                                })

  readonly property var modeIcons: ({
                                      "save": "󰋮",
                                      "copy": "󰆏",
                                      "satty": "󰈊",
                                      "ocr": "󰈙",
                                      "lens": "󰍉"
                                    })

  readonly property var modeNames: ({
                                      "save": "Save",
                                      "copy": "Copy",
                                      "satty": "Satty",
                                      "ocr": "OCR",
                                      "lens": "Lens"
                                    })

  readonly property var featureDeps: ({
                                        "satty": "satty",
                                        "ocr": "tesseract",
                                        "lens": "xdg-open"
                                      })

  function isModeAvailable(mode) {
    if (mode === "satty")
      return !!root.installedTools["satty"];
    if (mode === "ocr")
      return !!root.installedTools["tesseract"];
    if (mode === "lens")
      return !!root.installedTools["xdg-open"];
    return true;
  }

  function cycleMode(delta) {
    let idx = root.modes.indexOf(root.currentMode);
    for (let step = 1; step <= root.modes.length; step++) {
      const nextIdx = (idx + delta * step + root.modes.length * 10) % root.modes.length;
      const candidate = root.modes[nextIdx];
      if (isModeAvailable(candidate)) {
        root.currentMode = candidate;
        return;
      }
    }
  }

  function shellEscape(str) {
    return "'" + String(str).replace(/'/g, "'\\''") + "'";
  }

  function formatTimestamp() {
    const d = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  }

  function buildCrop(w, h, x, y) {
    return `magick ${shellEscape(root.fullScreenshot)} -crop ${w}x${h}+${x}+${y} +repage`;
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

  // 初始截屏
  function initCapture() {
    if (root.fullScreenshot === "" && !grimProc.running) {
      cursorFetcher.running = true;
      root.fullScreenshot = getTempPath("nshot-raw", "png");
      root.tempFiles.push(root.fullScreenshot);

      const cmd = ["grim", "-l", "1"];
      if (root.screen && root.screen.name) {
        cmd.push("-o", root.screen.name);
      }
      cmd.push(root.fullScreenshot);

      grimProc.command = cmd;
      grimProc.running = true;
    }
  }

  onScreenChanged: initCapture()

  Component.onCompleted: {
    depChecker.running = true;
    initCapture();
  }

  // 执行动作
  function executeAction() {
    if (!root.fullScreenshot)
      return;

    if (!isModeAvailable(root.currentMode)) {
      const dep = root.featureDeps[root.currentMode];
      Quickshell.execDetached(["notify-send", "-u", "critical", "nshot", `Feature unavailable: [${dep}] is not installed.`]);
      cleanupFiles();
      Qt.quit();
      return;
    }

    // 动态换算缩放比例
    const scaleX = (bgImage.sourceSize.width > 0 && root.width > 0) ? (bgImage.sourceSize.width / root.width) : 1;
    const scaleY = (bgImage.sourceSize.height > 0 && root.height > 0) ? (bgImage.sourceSize.height / root.height) : 1;

    const x = Math.round(selector.selectionX * scaleX);
    const y = Math.round(selector.selectionY * scaleY);
    const w = Math.round(selector.selectionWidth * scaleX);
    const h = Math.round(selector.selectionHeight * scaleY);

    if (w < 10 || h < 10)
      return;

    root.visible = false;
    root.doQuit = true;

    const crop = buildCrop(w, h, x, y);
    const homeDir = Quickshell.env("HOME") || "";
    const saveDir = homeDir ? `${homeDir}/Pictures/Screenshots` : "/tmp";

    if (root.currentMode === "save") {
      root.savedFile = `${saveDir}/Screenshot_${formatTimestamp()}.png`;
      const cmd = [`mkdir -p ${shellEscape(saveDir)}`, `${crop} ${shellEscape(root.savedFile)}`, `wl-copy -t image/png < ${shellEscape(root.savedFile)}`, `notify-send 'Saved' ${shellEscape("Screenshot saved to " + root.savedFile)}`].join(" && ");
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "copy") {
      const cmd = `${crop} png:- | wl-copy -t image/png && notify-send 'Copied' 'Screenshot copied to clipboard'`;
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "satty") {
      const outFile = getTempPath("snip-satty", "png");
      const targetFile = `${saveDir}/Screenshot_${formatTimestamp()}.png`;
      root.tempFiles.push(outFile);

      const cmd = [`mkdir -p ${shellEscape(saveDir)}`, `${crop} ${shellEscape(outFile)}`, `satty -f ${shellEscape(outFile)} -o ${shellEscape(targetFile)} --fullscreen --early-exit`, `[ -f ${shellEscape(targetFile)} ] && wl-copy -t image/png < ${shellEscape(targetFile)} && notify-send 'Satty' ${shellEscape("Annotated screenshot saved: " + targetFile)}`].join(
              " && ");
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "ocr") {
      const ocrFilter = `${crop} -colorspace gray -resize 200% -density 300 -resample 300 -contrast-stretch 1%x1% png:-`;
      const cmd = [ocrFilter, `tesseract - - -l eng+chi_sim --psm 6`, `awk 'BEGIN{RS=""; FS="\\n"; ORS="\\n\\n"} {for(i=1;i<=NF;i++){printf "%s ",$i} printf "\\n"}'`, `wl-copy`].join(" | ") + ` && notify-send 'OCR Complete' 'Text copied to clipboard'`;
      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    } else if (root.currentMode === "lens") {
      const rawScreenshot = root.fullScreenshot;
      const tmpJpg = getTempPath("snip-lens", "jpg");
      const tmpHtml = getTempPath("snip-lens", "html");

      // 转交后台异步清理，防止 proc.onExited 立即误删浏览器还没读取的临时文件
      root.tempFiles = [];
      root.fullScreenshot = "";

      const buildHtml
            = [`echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Google Lens</title></head><body style="margin:0;display:flex;justify-content:center;align-items:center;height:100vh;background:#111;color:#fff;font-family:system-ui"><p>Searching with Google Lens...</p><form id="f" method="POST" enctype="multipart/form-data"><input type="hidden" name="processed_image_dimensions" value="'"$DIM"'"></form><script>'`,
               `echo 'var b=atob("'"$B64"'");'`,
               `echo 'var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);var d=new DataTransfer();d.items.add(new File([a],"image.jpg",{type:"image/jpeg"}));var inp=document.createElement("input");inp.type="file";inp.name="encoded_image";inp.files=d.files;var f=document.getElementById("f");f.appendChild(inp);f.action="https://lens.google.com/v3/upload?ep=ccm&s=&st="+Date.now();f.submit();'`,
               `echo '</script></body></html>'`].join(" ; ");

      const cmd = [`${crop} -resize '1000x1000>' -strip -quality 85 ${shellEscape(tmpJpg)}`, `DIM=$(magick identify -format "%w,%h" ${shellEscape(tmpJpg)} 2>/dev/null || echo "1000,1000")`, `B64=$(base64 -w0 ${shellEscape(tmpJpg)} 2>/dev/null || base64 -b0 ${shellEscape(tmpJpg)})`, `[ -n "$B64" ]`, `{ ${buildHtml} ; } > ${shellEscape(tmpHtml)}`, `xdg-open
${shellEscape(tmpHtml)}`].join(" && ") + ` ; (sleep 15 && rm -f ${shellEscape(rawScreenshot)} ${shellEscape(tmpJpg)} ${shellEscape(tmpHtml)}) &`;

      proc.command = ["sh", "-c", cmd];
      proc.running = true;
    }
  }

  anchors {
    left: true
    right: true
    top: true
    bottom: true
  }

  Image {
    id: bgImage
    anchors.fill: parent
    asynchronous: false
    cache: false
    z: 0
  }

  // 光标初始位置获取
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

  // 依赖检测
  Process {
    id: depChecker
    command: ["sh", "-c", "for c in satty tesseract xdg-open; do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done"]
    stdout: SplitParser {
      onRead: data => {
        const tool = data.trim();
        if (tool.length > 0) {
          const updated = Object.assign({}, root.installedTools);
          updated[tool] = true;
          root.installedTools = updated;
        }
      }
    }
  }

  // 截屏抓取
  Process {
    id: grimProc
    onExited: code => {
      if (code === 0) {
        bgImage.source = "file://" + root.fullScreenshot;
        root.visible = true;
      } else {
        console.error("grim failed with code:", code);
        cleanupFiles();
        Qt.quit();
      }
    }
  }

  // 命令执行
  Process {
    id: proc
    onExited: code => {
      if (code !== 0) {
        console.error("Action failed with code:", code);
      }
      cleanupFiles();
      if (root.doQuit) {
        Qt.quit();
      }
    }
  }

  // 交互与选区
  Item {
    id: selector

    property real selectionX: 0
    property real selectionY: 0
    property real selectionWidth: 0
    property real selectionHeight: 0
    property point startPos
    property real mouseX: 0
    property real mouseY: 0
    property bool mouseMoved: false
    property bool hasPointer: false

    anchors.fill: parent
    z: 1

    // 四向遮罩
    Item {
      id: dimMask
      anchors.fill: parent
      z: 1

      property bool hasSelection: selector.selectionWidth > 0 && selector.selectionHeight > 0

      Rectangle {
        x: 0
        y: 0
        width: parent.width
        height: dimMask.hasSelection ? selector.selectionY : parent.height
        color: Qt.rgba(0, 0, 0, 0.5)
      }

      Rectangle {
        x: 0
        y: selector.selectionY + selector.selectionHeight
        width: parent.width
        height: Math.max(0, parent.height - y)
        color: Qt.rgba(0, 0, 0, 0.5)
        visible: dimMask.hasSelection
      }

      Rectangle {
        x: 0
        y: selector.selectionY
        width: selector.selectionX
        height: selector.selectionHeight
        color: Qt.rgba(0, 0, 0, 0.5)
        visible: dimMask.hasSelection
      }

      Rectangle {
        x: selector.selectionX + selector.selectionWidth
        y: selector.selectionY
        width: Math.max(0, parent.width - x)
        height: selector.selectionHeight
        color: Qt.rgba(0, 0, 0, 0.5)
        visible: dimMask.hasSelection
      }
    }

    // 十字准星
    Shape {
      id: dashedCrosshair
      anchors.fill: parent
      visible: !mouseArea.pressed && (selector.hasPointer || mouseArea.containsMouse || selector.mouseMoved)
      z: 2

      ShapePath {
        strokeColor: Qt.rgba(1, 1, 1, 0.45)
        strokeWidth: 1
        fillColor: "transparent"
        strokeStyle: ShapePath.DashLine
        dashPattern: [4, 4]
        startX: selector.mouseX
        startY: 0
        PathLine {
          x: selector.mouseX
          y: selector.height
        }
      }

      ShapePath {
        strokeColor: Qt.rgba(1, 1, 1, 0.45)
        strokeWidth: 1
        fillColor: "transparent"
        strokeStyle: ShapePath.DashLine
        dashPattern: [4, 4]
        startX: 0
        startY: selector.mouseY
        PathLine {
          x: selector.width
          y: selector.mouseY
        }
      }
    }

    // 选区边框
    Rectangle {
      x: selector.selectionX
      y: selector.selectionY
      width: selector.selectionWidth
      height: selector.selectionHeight
      color: "transparent"
      border.color: "#cba6f7"
      border.width: 1
      visible: mouseArea.pressed && selector.selectionWidth > 0
      z: 2
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
      Keys.onBacktabPressed: {
        root.cycleMode(-1);
      }

      onEntered: {
        selector.hasPointer = true;
      }

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
        if (selector.selectionWidth > 10 && selector.selectionHeight > 10) {
          root.executeAction();
        }
      }
    }

    // 选区尺寸指示
    Rectangle {
      visible: mouseArea.pressed && selector.selectionWidth > 20
      x: selector.selectionX + selector.selectionWidth / 2 - width / 2
      y: Math.max(12, selector.selectionY - 34)
      width: sizeLabel.implicitWidth + 16
      height: 24
      radius: 12
      color: Qt.rgba(0.08, 0.08, 0.12, 0.85)
      border.color: Qt.rgba(1, 1, 1, 0.15)
      border.width: 1
      z: 100

      Text {
        id: sizeLabel
        anchors.centerIn: parent
        text: `${Math.round(selector.selectionWidth)} × ${Math.round(selector.selectionHeight)}`
        color: "#cdd6f4"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.family: "monospace"
      }
    }
  }

  // 底部控制操作栏
  Item {
    id: controlContainer
    z: 10
    anchors {
      bottom: parent.bottom
      horizontalCenter: parent.horizontalCenter
      bottomMargin: 48
    }
    width: controlBar.width
    height: controlBar.height + hintRow.height + 12

    Rectangle {
      id: controlBar
      width: 566
      height: 48
      radius: 24
      color: Qt.rgba(0.07, 0.08, 0.11, 0.82)
      border.color: Qt.rgba(1, 1, 1, 0.12)
      border.width: 1

      // 指示滑块
      Rectangle {
        id: highlight
        height: parent.height - 10
        width: 108
        y: 5
        radius: height / 2
        x: 5 + (Math.max(0, root.modes.indexOf(root.currentMode)) * 110)

        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop {
            position: 0.0
            color: "#d9bbf9"
          }
          GradientStop {
            position: 1.0
            color: "#bfa1f6"
          }
        }

        border.color: Qt.rgba(1, 1, 1, 0.35)
        border.width: 1

        Behavior on x {
          NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
          }
        }
      }

      Row {
        anchors.fill: parent
        anchors.margins: 5
        spacing: 2

        Repeater {
          model: root.modes

          Item {
            id: tabBtn
            property bool available: root.isModeAvailable(modelData)
            property bool isActive: root.currentMode === modelData
            width: 108
            height: controlBar.height - 10

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(1, 1, 1, 0.05)
              visible: !tabBtn.isActive && tabMouse.containsMouse && tabBtn.available
            }

            MouseArea {
              id: tabMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: tabBtn.available ? Qt.PointingHandCursor : Qt.ForbiddenCursor
              onClicked: {
                if (tabBtn.available) {
                  root.currentMode = modelData;
                } else {
                  const dep = root.featureDeps[modelData];
                  Quickshell.execDetached(["notify-send", "-u", "normal", "nshot", `Feature unavailable: Please install [${dep}] to use ${modelData} mode.`]);
                }
              }
            }

            Row {
              anchors.centerIn: parent
              spacing: 6

              Text {
                text: root.modeIcons[modelData]
                anchors.verticalCenter: parent.verticalCenter
                font.family: "Symbols Nerd Font"
                font.pixelSize: 14
                color: tabBtn.isActive ? "#11111b" : (tabBtn.available ? (tabMouse.containsMouse ? "#ffffff" : "#cdd6f4") : "#585b70")
              }

              Text {
                text: root.modeNames[modelData]
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 12
                font.weight: tabBtn.isActive ? Font.Bold : Font.Medium
                color: tabBtn.isActive ? "#11111b" : (tabBtn.available ? (tabMouse.containsMouse ? "#ffffff" : "#a6adc8") : "#585b70")
              }

              Rectangle {
                visible: !tabBtn.available
                anchors.verticalCenter: parent.verticalCenter
                width: 5
                height: 5
                radius: 2.5
                color: "#f38ba8"
              }
            }
          }
        }
      }
    }

    // 快捷键提示
    Row {
      id: hintRow
      anchors.top: controlBar.bottom
      anchors.topMargin: 10
      anchors.horizontalCenter: controlBar.horizontalCenter
      spacing: 16

      Row {
        spacing: 6
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          width: tabKeyText.implicitWidth + 8
          height: 16
          radius: 4
          color: Qt.rgba(0.12, 0.13, 0.18, 0.75)
          border.color: Qt.rgba(1, 1, 1, 0.1)
          border.width: 1
          Text {
            id: tabKeyText
            anchors.centerIn: parent
            text: "Tab"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.family: "monospace"
            color: "#bac2de"
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Switch"
          font.pixelSize: 11
          color: "#6c7086"
        }
      }

      Row {
        spacing: 6
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          width: escKeyText.implicitWidth + 8
          height: 16
          radius: 4
          color: Qt.rgba(0.12, 0.13, 0.18, 0.75)
          border.color: Qt.rgba(1, 1, 1, 0.1)
          border.width: 1
          Text {
            id: escKeyText
            anchors.centerIn: parent
            text: "Esc"
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.family: "monospace"
            color: "#bac2de"
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Cancel"
          font.pixelSize: 11
          color: "#6c7086"
        }
      }
    }
  }

  // 全局快捷键
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
