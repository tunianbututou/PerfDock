// Panel.swift — 悬浮窗：无边框玻璃窗 + 原生拖移/缩放 + 贴边吸附 + 侧边栏折叠
import AppKit
import WebKit

protocol PanelBridge: AnyObject {
    func panelCommand(_ cmd: String, payload: [String: Any])
}

/// 覆盖在 WebView 之上的透明拖拽层，把鼠标拖动直接交给窗口（原生手感，无 JS 往返）
/// 手动拖拽循环（QuotaDock 同款思路）：返回是否发生了移动。
/// 不用 window.performDrag——它在「常驻置顶 + 非激活」面板上时灵时不灵（时而拖不动）；
/// 手动泵事件 + setFrameOrigin 在任何前后台状态下都稳定。
@discardableResult
fileprivate func runManualDragLoop(_ w: NSWindow, downTime: TimeInterval) -> Bool {
    let startFrame = w.frame
    let startMouse = NSEvent.mouseLocation
    var moved = false
    NSCursor.closedHand.push()
    defer { NSCursor.pop() }
    while true {
        guard let e = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: Date(timeIntervalSinceNow: 0.1),
            inMode: .eventTracking,
            dequeue: true
        ) else {
            // 超时：若鼠标按键其实已松开（事件被截走），按未拖动收场
            if NSEvent.pressedMouseButtons & 1 == 0 { break }
            continue
        }
        if e.timestamp < downTime { continue }   // 丢掉按下前排队的旧拖动事件
        if e.type == .leftMouseUp { break }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = p.y - startMouse.y
        if !moved, abs(dx) > 3 || abs(dy) > 3 { moved = true }
        if moved {
            w.setFrameOrigin(NSPoint(x: startFrame.origin.x + dx,
                                     y: startFrame.origin.y + dy))
        }
    }
    return moved
}

final class DragStrip: NSView {
    /// 常驻置顶面板在别的 App 前台时，第一下点击也要直接生效，
    /// 不能被「先激活窗口」吃掉（否则要连点两下才能拖）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onGrab: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onGrab?()                       // 用户接管窗口：立即终结在途切换动画
        guard let w = window else { return }
        _ = runManualDragLoop(w, downTime: event.timestamp)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// 收纳态的交互层：
///  - 球体（dragOnly=true）：拖动 = 移动悬浮窗；松手后由控制器吸附到最近的屏幕边缘
///  - 其余区域（dragOnly=false）：点击 = 展开；拖动 = 移动（两种手势都能用）
final class MiniHandleView: NSView {
    var dragOnly = true
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onGrab: (() -> Void)?

    /// 同上：非激活面板第一下点击必须直接落到手柄上，否则收纳条点不动也拖不动。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        onGrab?()                       // 用户接管窗口：立即终结在途切换动画
        let moved = runManualDragLoop(w, downTime: event.timestamp)
        if moved {
            // 延后到 mouseDown 调用栈之外：吸附动画绝不能嵌在事件跟踪循环里执行
            DispatchQueue.main.async { [weak self] in self?.onDragEnd?() }
        }
        else if !dragOnly { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragOnly ? .openHand : .pointingHand)
    }
}

final class PanelController: NSObject, NSWindowDelegate, WKScriptMessageHandler {

    let panel: NSPanel
    private let fx = NSVisualEffectView()
    /// 隐藏的主题配色基准；不能显示，否则会遮住桌面和毛玻璃。
    private let backdrop = NSView()
    /// 切换动画盖板：动画期间压在 WebView 之上（WebView 保持存活渲染）。
    /// 不能用 isHidden 藏 WebView——隐藏再显示会闪出「最后一帧旧画面被拉伸」
    /// （收纳态竖条内容铺满全窗一瞬间）；盖板挡住中间过程，撤盖时 web 已是新画面。
    private let cover = NSVisualEffectView()
    private let web: WKWebView
    private let dragStrip = DragStrip()
    private let miniBody = MiniHandleView()
    private let miniBall = MiniHandleView()
    private var root: NSView!

    weak var bridge: PanelBridge?
    private(set) var isMini = false
    /// 收纳形态：false = 竖条（贴左右边），true = 横条（贴上下边）
    private(set) var miniHorizontal = false
    private var suppressSnap = false
    private var animating = false
    /// 在途切换动画的令牌与目标帧：用户抓住窗口时用于立即终结动画
    private var animToken = 0
    private var animTarget: NSRect?
    /// 触控板捏合事件监听（App 级，WKWebView 无法吞掉）
    private var pinchMonitor: Any?

    /// 拖拽条的厚度与右侧留给按钮的宽度（与前端 #drag 区一致）
    private let stripH: CGFloat = 30
    private let stripRightGap: CGFloat = 100
    private let miniW: CGFloat = 26
    private let miniH: CGFloat = 32
    private let miniFooter: CGFloat = 26

    private enum DockedEdge { case top, bottom, left, right, none }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        web = WKWebView(frame: .zero, configuration: cfg)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 282, height: 344),
                        styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        buildWindow()
    }

    // MARK: 构建

    private func buildWindow() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 190, height: 170)
        panel.delegate = self
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }

        root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.autoresizingMask = [.width, .height]

        // 半透明毛玻璃：`.underWindowBackground` 比 `.hudWindow` 通透得多，
        // 否则底材本身接近不透明，背景不透明度滑块看起来完全没作用。
        fx.material = .underWindowBackground
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        fx.frame = root.bounds
        root.addSubview(fx)

        // 隐藏的主题色基准；不可盖在材质上，否则背景不透明度无法生效。
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1).cgColor
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = root.bounds
        backdrop.isHidden = true      // 仅作配色基准保留，不参与视觉（否则透明度滑块失效）
        root.addSubview(backdrop)

        web.frame = root.bounds
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        // 关掉 WebView 自带页面缩放：触控板捏合交给原生手势识别器转发给图表
        web.allowsMagnification = false
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        web.configuration.userContentController.add(self, name: "dock")
        root.addSubview(web)

        // 触控板双指捏合：WKWebView 不会把 magnification 传给 DOM，
        // 用 App 级事件监听接管（比视图手势识别器更可靠，WebView 吞不掉）
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] e in
            self?.applyPinch(e.magnification)
            return nil      // 消费掉，避免 WebView 自己缩放页面
        }

        // 切换动画盖板：需要「盖住」中间态，保持 hudWindow 的高遮蔽性；默认隐藏
        cover.material = .hudWindow
        cover.appearance = NSAppearance(named: .darkAqua)
        cover.blendingMode = .behindWindow
        cover.state = .active
        cover.autoresizingMask = [.width, .height]
        cover.frame = root.bounds
        cover.isHidden = true
        root.addSubview(cover)

        dragStrip.wantsLayer = true
        dragStrip.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(dragStrip)

        for v in [miniBody, miniBall] {
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            v.isHidden = true
            root.addSubview(v)
        }
        miniBody.dragOnly = false
        miniBody.onGrab = { [weak self] in self?.userGrabbedWindow() }
        miniBody.onClick = { [weak self] in self?.expandFromSidebar() }
        miniBody.onDragEnd = { [weak self] in self?.snapMiniToEdge() }
        miniBall.onGrab = { [weak self] in self?.userGrabbedWindow() }
        miniBall.onDragEnd = { [weak self] in self?.snapMiniToEdge() }
        dragStrip.onGrab = { [weak self] in self?.userGrabbedWindow() }

        panel.contentView = root
        layoutStrip()
        loadUI()
    }

    private func loadUI() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // 开发期：从可执行文件旁的 UI/ 目录加载，便于快速迭代
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let cand = exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("UI/index.html")
            if FileManager.default.fileExists(atPath: cand.path) {
                web.loadFileURL(cand, allowingReadAccessTo: cand.deletingLastPathComponent())
            }
        }
    }

    private func layoutStrip() {
        let b = root.bounds
        dragStrip.isHidden = isMini
        miniBody.isHidden = !isMini
        miniBall.isHidden = !isMini
        if isMini {
            if miniHorizontal {
                // 横向收纳：右侧 miniFooter 宽的区域是拖动球，左侧是「点击展开 / 拖动移动」的主体
                miniBall.frame = NSRect(x: max(0, b.width - miniFooter), y: 0,
                                        width: miniFooter, height: b.height)
                miniBody.frame = NSRect(x: 0, y: 0, width: max(0, b.width - miniFooter),
                                        height: b.height)
            } else {
                // 纵向收纳：底部 miniFooter 高的区域是拖动球，其余是主体
                miniBall.frame = NSRect(x: 0, y: 0, width: b.width, height: miniFooter)
                miniBody.frame = NSRect(x: 0, y: miniFooter, width: b.width,
                                        height: max(0, b.height - miniFooter))
            }
        } else {
            dragStrip.frame = NSRect(x: 0, y: b.height - stripH,
                                     width: max(0, b.width - stripRightGap), height: stripH)
        }
    }

    /// 当前窗口贴在哪条边上（用于决定收纳形态）
    private func dockedEdge() -> DockedEdge {
        guard let screen = panel.screen ?? NSScreen.main else { return .none }
        let vf = screen.visibleFrame, f = panel.frame, t: CGFloat = 2
        if abs(f.maxY - vf.maxY) < t { return .top }
        if abs(f.minY - vf.minY) < t { return .bottom }
        if abs(f.minX - vf.minX) < t { return .left }
        if abs(f.maxX - vf.maxX) < t { return .right }
        return .none
    }

    /// 收纳态拖动结束后：按「最近的边」吸附，并据此自动切换横条/竖条形态。
    /// 支持跨边互换——把横条（贴上下边）拖到左右边会自动变成竖条，反之亦然，
    /// 不必先展开成小窗再拖到别的边重新收纳。
    func snapMiniToEdge() {
        guard isMini, !animating,
              let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f0 = panel.frame
        // 以窗口中心到四条边的距离判定最近边：贴上下 → 横条；贴左右 → 竖条
        let cx = f0.midX, cy = f0.midY
        let dTop = vf.maxY - cy, dBot = cy - vf.minY
        let dLeft = cx - vf.minX, dRight = vf.maxX - cx
        let goHorizontal = min(dTop, dBot) <= min(dLeft, dRight)

        var f = f0
        if goHorizontal {
            // 横条：保留左角 x，贴到最近的上/下边
            let w = min(max(220, f0.width), max(140, vf.width - 40))
            var x = f0.minX
            x = min(max(x, vf.minX), vf.maxX - w)
            let y = (dTop <= dBot) ? vf.maxY - miniH : vf.minY
            f = NSRect(x: x, y: y, width: w, height: miniH)
            if !miniHorizontal { miniHorizontal = true }
        } else {
            // 竖条：保留上角 y，贴到最近的左/右边
            let h = min(max(240, f0.height), vf.height - 40)
            var y = f0.minY
            y = min(max(y, vf.minY), vf.maxY - h)
            let x = (dLeft <= dRight) ? vf.minX : vf.maxX - miniW
            f = NSRect(x: x, y: y, width: miniW, height: h)
            if miniHorizontal { miniHorizontal = false }
        }
        panel.minSize = goHorizontal
            ? NSSize(width: 140, height: miniH)
            : NSSize(width: miniW, height: 160)

        setMode(true)        // 推送新形态给前端（内部已 layoutStrip），再落定尺寸
        // 用 CA 驱动的统一动画（不泵嵌套事件循环）：
        // 绝不能在这里用 setFrame(animate:true)——它是同步动画且在 mouseDown 跟踪循环
        // 内被调用，贴底边时（Dock 进程抢事件）会事件重入 → 窗口假死（点不动拖不动）。
        animating = true
        animateFrame(to: f) {
            self.layoutStrip()
            Prefs.shared.miniFrame = self.panel.frame
            self.animating = false
        }
    }

    /// 系统标题栏实际高度，交给前端对齐顶部拖拽区
    var topInset: CGFloat {
        max(20, panel.frame.height - panel.contentLayoutRect.height)
    }

    /// 自检用：把 WebView 的真实渲染结果导出为 PNG
    func snapshot(to path: String) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        web.takeSnapshot(with: cfg) { img, err in
            guard let img, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("SNAPSHOT   FAIL  \(String(describing: err))")
                return
            }
            try? png.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT   OK    \(path)  \(Int(img.size.width))x\(Int(img.size.height))")
        }
    }

    // MARK: 与前端通信

    /// 触控板双指捏合 → 磁盘图表时间轴缩放。
    /// `.magnify` 事件本身是增量（每次只带本帧的变化量），直接换算成跨度系数。
    private func applyPinch(_ magnification: CGFloat) {
        guard !isMini, abs(magnification) > 0.0005 else { return }
        let factor = 1.0 / max(0.2, 1.0 + magnification)
        js("window.pd && window.pd.zoomDisk && window.pd.zoomDisk(\(factor));")
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { [weak self] in
            self?.web.evaluateJavaScript(code) { _, _ in }
        }
    }

    func pushJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              var s = String(data: data, encoding: .utf8) else { return }
        s = s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
             .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        js("window.pd && window.pd.data(\(s));")
    }

    /// 推送磁盘累计读写聚合数据（按需下发，不随每秒采样）
    func pushDiskHistory(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              var s = String(data: data, encoding: .utf8) else { return }
        s = s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
             .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        js("window.pd && window.pd.diskHistory(\(s));")
    }

    func syncPrefs(_ prefs: Prefs) {
        setBackgroundOpacity(prefs.bgOpacity)
        guard let data = try? JSONSerialization.data(withJSONObject: prefs.json()),
              let s = String(data: data, encoding: .utf8) else { return }
        js("window.pd && window.pd.init({prefs:\(s), topInset:\(Int(topInset))});")
    }

    func setMode(_ mini: Bool) {
        isMini = mini
        layoutStrip()
        let o = miniHorizontal ? "h" : "v"
        js("window.pd && window.pd.mode('\(mini ? "mini" : "full")', '\(o)');")
    }

    /// 只调背景材质，绝不改变整窗 alpha（否则文字也会变淡）。
    func setBackgroundOpacity(_ value: Double) {
        fx.alphaValue = CGFloat(value.isFinite ? min(1, max(0.08, value)) : 0.42)
    }

    func setBlur(_ on: Bool) {
        // 只控制「模糊 / 不模糊」：关掉时直接露出清晰桌面，仍受背景不透明度调节；
        // 不再切到不透明深底（那会让透明度滑块失效）。
        fx.isHidden = !on
        backdrop.isHidden = true
    }

    /// 主题联动原生底座：浅色主题必须把深底换成浅色、毛玻璃换 aqua 外观，
    /// 否则 42% 不透明的浅色界面压在深底上会整体发灰、主色被压成紫灰。
    func setTheme(light: Bool) {
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        fx.appearance = appearance
        cover.appearance = appearance
        backdrop.layer?.backgroundColor = (light
            ? NSColor(srgbRed: 0.949, green: 0.957, blue: 0.973, alpha: 1)    // #F2F4F8
            : NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)).cgColor   // #111318
    }

    func setAlwaysOnTop(_ on: Bool) {
        panel.level = on ? .floating : .normal
    }

    func openSettingsPanel() {
        js("document.getElementById('panel').classList.add('open');")
    }

    func notifyResize() {
        js("window.pd && window.pd.topInset(\(Int(topInset)));")
    }

    /// 自检用：整窗截图（含原生底座/毛玻璃层），用于验证主题底色
    func snapshotWindow(to path: String) {
        guard let v = panel.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT   OK    \(path)  \(rep.pixelsWide)x\(rep.pixelsHigh) (整窗)")
    }

    /// 自检用：透明度相关配置（材质 + 底座是否隐藏）
    func debugOpacityState() -> String {
        "fxMaterial=\(fx.material.rawValue) fxHidden=\(fx.isHidden) backdropHidden=\(backdrop.isHidden)"
    }

    /// 自检用：当前底座颜色（0–255），验证浅色主题下底座确实变浅
    func debugBackdropRGB() -> (Int, Int, Int)? {
        guard let cg = backdrop.layer?.backgroundColor,
              let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// 自检用：执行一段 JS 并回收结果（用于验证「前端 → 原生」指令链路）
    func evalJS(_ code: String, _ done: @escaping (Any?) -> Void = { _ in }) {
        web.evaluateJavaScript(code) { v, _ in done(v) }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "dock", let body = m.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        var payload = body
        payload.removeValue(forKey: "cmd")
        bridge?.panelCommand(cmd, payload: payload)
    }

    // MARK: 拖移 / 缩放 / 吸附

    func windowDidMove(_ n: Notification) {
        guard !suppressSnap, !animating else { return }
        snap()
        saveFrame()
        layoutStrip()
    }

    func windowDidResize(_ n: Notification) {
        // 动画期间完全静默：否则每帧 resize 都会触发 notifyResize()（JS 通信风暴）+ layoutStrip()，
        // 造成切换时「卡一会」；收尾统一在动画完成回调里做。
        guard !suppressSnap, !animating else { return }
        layoutStrip()
        notifyResize()
        saveFrame()
    }

    func windowDidChangeScreen(_ n: Notification) {
        keepOnScreen()
    }

    /// 贴近屏幕边缘（26pt 内）时吸附，并夹回可见区。
    /// 关键：用单侧判断而不是 abs 差值。macOS 允许窗口标题栏压到菜单栏、底边压到 Dock，
    /// 一旦越过可见区边缘，abs 差值就会大于阈值 → 上下吸不住。单侧判断同时覆盖「越界」与「接近」。
    private func snap() {
        guard !isMini else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = panel.frame
        let t: CGFloat = 26
        // 左右
        if f.minX < vf.minX + t { f.origin.x = vf.minX }
        else if f.maxX > vf.maxX - t { f.origin.x = vf.maxX - f.width }
        // 上下
        if f.maxY > vf.maxY - t { f.origin.y = vf.maxY - f.height }
        else if f.minY < vf.minY + t { f.origin.y = vf.minY }
        if f != panel.frame {
            suppressSnap = true
            panel.setFrame(f, display: true)
            suppressSnap = false
        }
    }

    /// 自检用：手动触发一次贴边判定
    func snapToEdges() { snap() }

    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = panel.frame
        if !vf.intersects(f) {
            f.origin.x = vf.maxX - f.width - 12
            f.origin.y = vf.maxY - f.height - 12
        } else {
            f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
            f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        }
        suppressSnap = true
        panel.setFrame(f, display: true)
        suppressSnap = false
    }

    // MARK: 位置记忆

    private func saveFrame() {
        guard !animating else { return }
        if isMini { Prefs.shared.miniFrame = panel.frame }
        else { Prefs.shared.fullFrame = panel.frame }
    }

    func restoreFrame() {
        if Prefs.shared.wasMini, let mf = Prefs.shared.miniFrame {
            suppressSnap = true
            panel.setFrame(mf, display: false)
            suppressSnap = false
            isMini = true
            miniHorizontal = mf.width > mf.height
        } else if let ff = Prefs.shared.fullFrame {
            suppressSnap = true
            panel.setFrame(ff, display: false)
            suppressSnap = false
            keepOnScreen()
        } else {
            placeAtRightEdge()
        }
        setMode(isMini)
        layoutStrip()
    }

    private func placeAtRightEdge() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let h: CGFloat = min(344, vf.height - 80)
        let f = NSRect(x: vf.maxX - 282, y: vf.maxY - h - 24, width: 282, height: h)
        suppressSnap = true
        panel.setFrame(f, display: false)
        suppressSnap = false
    }

    // MARK: 折叠 / 展开

    /// 动画期间盖住 / 撤掉 WebView 盖板（不隐藏 WebView 本身）
    private func showCover(_ on: Bool) {
        if on {
            cover.frame = root.bounds
            cover.isHidden = false
            root.addSubview(cover, positioned: .above, relativeTo: web)
        } else {
            cover.removeFromSuperview()
            cover.isHidden = true
        }
    }

    /// 统一的窗口尺寸动画：显式时长 + 缓动 + 真正的完成回调。
    /// 替代「animate:true + 固定 0.35s 猜测等待」——定时器与真实动画时长脱节
    /// 正是切换时布局裸奔（旧内容 × 中途尺寸）与二次跳变的根源。
    private func animateFrame(to f: NSRect, done: @escaping () -> Void) {
        animToken += 1
        let my = animToken
        animTarget = f
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(f, display: true)
        }, completionHandler: {
            guard my == self.animToken else { return }   // 已被用户操作终结，勿重复收场
            self.animTarget = nil
            done()
        })
    }

    /// 用户抓住窗口（拖拽条 / 小小窗手柄）时立即终结在途切换动画。
    /// 否则动画与收尾（setFrame / 吸附 / fit）会和系统拖拽争抢 frame——
    /// 表现为「小窗经常拖不动」。0 时长动画收掉在途帧，窗口完全交给用户。
    func userGrabbedWindow() {
        guard animTarget != nil else { return }
        animToken += 1                 // 作废在途动画的完成回调
        animTarget = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.panel.animator().setFrame(self.panel.frame, display: false)
        }
        animating = false
        showCover(false)
        layoutStrip()
    }

    /// 收纳：贴上下边 → 横向细带；否则 → 竖向左/右侧边栏
    /// 流程：藏 WebView → 切内容模式（趁隐藏期重排）→ 动画缩窗 → 就位后一次性亮出。
    /// WebView 全程不见「中途尺寸」，杜绝破布局；亮出即最终形态，无二次跳变。
    func minimizeToSidebar() {
        guard !isMini, !animating else { return }   // 动画期间忽略新手势，杜绝状态交错
        endTextInput()                              // 折叠前结束输入上下文，防系统浮层残留
        Prefs.shared.fullFrame = panel.frame
        animating = true
        isMini = true
        Prefs.shared.wasMini = true

        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let edge = dockedEdge()
        miniHorizontal = (edge == .top || edge == .bottom)

        showCover(true)
        setMode(true)          // 前端趁被盖住时先完成内容切换与重排

        var target = NSRect.zero
        if miniHorizontal {
            // 横向收纳（贴顶/底）：锚定「左角」—— x 取小窗左缘、保持横向位置不变；
            // 贴下边锚定左下角、贴上边锚定左上角（y 贴到屏幕边）。
            let w = min(max(220, panel.frame.width), max(140, vf.width - 40))
            var x = panel.frame.minX
            x = min(max(x, vf.minX), vf.maxX - w)   // 仅做不溢出夹取，尽量保住左角
            let y = (edge == .bottom) ? vf.minY : vf.maxY - miniH
            panel.minSize = NSSize(width: 140, height: miniH)
            target = NSRect(x: x, y: y, width: w, height: miniH)
        } else {
            // 纵向收纳（贴左/右）：锚定「上角」—— y 取小窗上缘、保持纵向位置不变；
            // 贴左边锚定左上角（x=屏幕左缘）、贴右边锚定右上角（x=屏幕右缘）。
            let goLeft = panel.frame.midX < vf.midX
            let h = min(max(240, panel.frame.height), vf.height - 40)
            var y = panel.frame.minY
            y = min(max(y, vf.minY), vf.maxY - h)   // 仅做不溢出夹取，尽量保住上角
            let x = goLeft ? vf.minX : vf.maxX - miniW
            panel.minSize = NSSize(width: miniW, height: 160)
            target = NSRect(x: x, y: y, width: miniW, height: h)
        }
        animateFrame(to: target) {
            self.layoutStrip()
            Prefs.shared.miniFrame = self.panel.frame
            self.animating = false
            self.showCover(false)    // 撤盖即最终形态，web 已在新尺寸上渲染就绪
        }
    }

    /// 从收纳态展开：以「小小窗当前的锚角」为不动点展开，而不是弹回收纳前的小窗位置。
    /// 这样即使把小小窗拖到了别的贴边 / 位置，展开后的小窗也跟随小小窗的角落，
    /// 横向 / 纵向位置不跳变（用户不希望记得小窗原来的悬停位置）。
    /// 流程与收纳对称：藏 WebView → 切内容模式 → 动画扩窗 → 高度适配落定 → 一次性亮出。
    func expandFromSidebar() {
        guard isMini, !animating else { return }    // 动画期间忽略新手势，杜绝状态交错
        // 先记住收纳形态与小小窗当前位置，再切换状态（形态判定要用收纳时的值）
        let wasHorizontal = miniHorizontal
        let mini = panel.frame
        animating = true
        isMini = false
        miniHorizontal = false
        Prefs.shared.wasMini = false
        panel.minSize = NSSize(width: 190, height: 170)

        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        // 展开尺寸沿用收纳前记忆的小窗尺寸（含内容自适应高度）；无记录则用默认
        let full = Prefs.shared.fullFrame ?? NSRect(x: 0, y: 0, width: 282, height: 344)
        let fw = full.width
        let fh = full.height

        var f = NSRect(x: 0, y: 0, width: fw, height: fh)
        if wasHorizontal {
            // 横向收纳（贴顶 / 底）：锚定左角 → 左缘对齐小小窗左缘，保持横向位置不变
            f.origin.x = mini.minX
            // 贴底 → 底缘贴屏幕下边；贴顶 → 顶缘贴屏幕上边
            f.origin.y = (abs(mini.minY - vf.minY) < 2) ? vf.minY : (vf.maxY - fh)
        } else {
            // 纵向收纳（贴左 / 右）：锚定上角 → 上缘对齐小小窗上缘，保持纵向位置不变
            f.origin.y = mini.minY
            // 贴左 → 左缘贴屏幕左边；贴右 → 右缘贴屏幕右边
            f.origin.x = (abs(mini.minX - vf.minX) < 2) ? vf.minX : (vf.maxX - fw)
        }
        // 夹回可见区（尺寸过大或极端位置时防止越界）
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)

        showCover(true)
        setMode(false)         // 前端趁被盖住时先切到完整内容并重排
        animateFrame(to: f) {
            self.layoutStrip()
            self.keepOnScreen()
            self.animating = false
            Prefs.shared.fullFrame = self.panel.frame     // 展开后的尺寸与位置都要记住
            // 先按内容适配高度、等高度落定后再撤盖：
            // 避免「撤盖 → 再跳一次高度」的二次跳变（fit 往返通常 <50ms，0.12s 足够）
            self.js("window.pd && window.pd.requestFit();")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.showCover(false)
            }
        }
    }

    // 一键套用预设窗口尺寸：锚定右下角，保持悬浮窗位置感
    func applyPreset(w: CGFloat, h: CGFloat) {
        let minW: CGFloat = 190, minH: CGFloat = 170
        let nw = max(minW, w), nh = max(minH, h)
        var f = panel.frame
        f.origin.x = f.maxX - nw
        f.origin.y = f.maxY - nh
        f.size = NSSize(width: nw, height: nh)
        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - nw)
            f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - nh)
        }
        animating = true
        suppressSnap = true
        panel.setFrame(f, display: true, animate: true)
        suppressSnap = false
        // 直接落盘：saveFrame() 在 animating 期间会被跳过，导致套用预设后尺寸不被记住
        Prefs.shared.fullFrame = f
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.animating = false
            self.saveFrame()
        }
    }

    // 按内容自然高度重设窗口高度：宽度不变（横竖形态稳定），保持当前贴边，夹回可视区
    func fitToContentHeight(_ contentH: CGFloat) {
        guard !isMini else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = panel.frame
        let tb = f.height - panel.contentLayoutRect.height   // 标题栏/非内容高度
        let minC: CGFloat = 150
        let maxC = vf.height - 40
        let nh = min(max(contentH, minC), maxC)
        let keepBottom = dockedEdge() == .bottom
        let topY = f.maxY
        f.size.height = nh + tb
        f.origin.y = keepBottom ? vf.minY : (topY - f.height)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        suppressSnap = true
        panel.setFrame(f, display: true)
        suppressSnap = false
        guard !animating else { return }
        Prefs.shared.fullFrame = f
    }

    // MARK: 显隐

    func show() {
        panel.orderFrontRegardless()
        if Prefs.shared.wasMini, let mf = Prefs.shared.miniFrame {
            miniHorizontal = mf.width > mf.height
        }
        if Prefs.shared.wasMini { setMode(true) } else { setMode(false) }
        restoreFrame()
    }

    func hide() {
        endTextInput()
        panel.orderOut(nil)
    }

    /// 主动结束文本输入上下文：面板不是 key window，输入法/自动填充的浮层可能残留在屏幕上，
    /// 收起窗口或折叠时调用，避免出现带用户名的系统文本框。
    func endTextInput() {
        js("if(document.activeElement && document.activeElement.blur) document.activeElement.blur();")
        panel.makeFirstResponder(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func destroy() {
        if let m = pinchMonitor { NSEvent.removeMonitor(m); pinchMonitor = nil }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "dock")
        panel.orderOut(nil)
    }
}
