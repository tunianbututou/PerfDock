// main.swift — PerfDock：随 WorkBuddy 启动的桌面性能悬浮窗
import AppKit
import Foundation

private let WB_BUNDLE = "com.tencent.workbuddy.mac"
private let AGENT_LABEL = "com.perfdock.agent"

final class AppDelegate: NSObject, NSApplicationDelegate, PanelBridge, NSMenuDelegate {

    private var panel: PanelController!
    private var statusItem: NSStatusItem!

    private let engine = MetricsEngine()
    private let temps = TempReader()
    private let diskHistory = DiskHistory()
    private let queue = DispatchQueue(label: "perfdock.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 磁盘累计读写的独立采样定时器：固定 1s，不受「采样间隔」设置影响。
    /// 主采样间隔拉到 5s/10s 时，磁盘历史仍按 1s 粒度记账（跨整点也不会把增量错记到新小时）。
    private var diskTimer: DispatchSourceTimer?
    private let diskQueue = DispatchQueue(label: "perfdock.diskio", qos: .utility)
    private var temp: TempReader.TempSummary?
    private var lastTempAt = Date.distantPast
    // 菜单栏内联 / 温度历史所需的「最近一次采样」缓存
    private var lastCpu: Double = 0
    private var lastMem: Double = 0
    private var lastTempCpu: Double = 0
    private var tempHistory: [Double] = []
    // 全局快捷键监听句柄（用于卸载重装）
    private var hotkeyMonitors: [Any] = []

    /// 由登录项（LaunchAgent）拉起时为 true：此时不主动弹窗，等 WorkBuddy 启动
    private var silent = false
    private var selftest = false

    // MARK: 生命周期

    func applicationWillFinishLaunching(_ n: Notification) {
        silent = CommandLine.arguments.contains("--silent")
        selftest = CommandLine.arguments.contains("--selftest")
        // 单实例：登录项与手动启动可能同时拉起
        if let bid = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.shared.migratePresetsIfNeeded()   // 预设默认值换代时替换掉旧预设

        panel = PanelController()
        panel.bridge = self
        panel.setBlur(Prefs.shared.blur)
        panel.setAlwaysOnTop(Prefs.shared.alwaysOnTop)
        // 启动即按当前有效主题铺底（落盘后前端就绪还会再同步一次，幂等）
        let resolvedTheme = Prefs.shared.theme == "auto" ? Prefs.shared.appearance : Prefs.shared.theme
        panel.setTheme(light: resolvedTheme == "light")

        setupStatusItem()
        installHotkeyIfNeeded()
        observeAppearance()
        observeWorkBuddy()
        if selftest { runSelfTest(); return }
        if Prefs.shared.launchAtLogin { installAgent(true) }
        // 诊断开关：PD_DEBUG_WINDOWS=1 时每 3s 打印进程内所有窗口（排查多余浮层）
        if ProcessInfo.processInfo.environment["PD_DEBUG_WINDOWS"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                for w in NSApp.windows {
                    print("WINDOW  \(type(of: w)) \(w.frame) vis=\(w.isVisible) " +
                          "lvl=\(w.level.rawValue) title=[\(w.title)] alpha=\(w.alphaValue)")
                }
            }
        }

        // 等前端就绪后再同步偏好，避免丢消息
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.panel.syncPrefs(Prefs.shared)
            if self.workBuddyRunning() || !self.silent {
                self.panel.show()
                self.startSampling()
            }
        }
    }

    // MARK: 自检（--selftest）：走完整链路并导出真实渲染结果

    private func runSelfTest() {
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/shots"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        Prefs.shared.clearGeometry()          // 从确定状态开始，避免上次运行的窗口状态干扰断言
        panel.syncPrefs(Prefs.shared)
        panel.show()
        self.startSampling()                  // 让 tick() 驱动真实采样，填充 tempHistory 等历史序列（自检需验证趋势温度线）
        print("SELFTEST   窗口已创建")
        print("OPACITY    \(panel.debugOpacityState())")
        // 诊断：列出进程内所有窗口（排查多出来的悬浮文本框）
        for w in NSApp.windows {
            print("WIN        \(type(of: w)) frame=\(w.frame) visible=\(w.isVisible) " +
                  "level=\(w.level.rawValue) title=[\(w.title)] class=\(w.className)")
        }

        after(2.2) {
            self.queue.async {
                _ = self.engine.sample()                       // 建立基线
                Thread.sleep(forTimeInterval: 1.2)
                var d = self.engine.sample(topN: Prefs.shared.topN,
                                           metric: Prefs.shared.procMetric)
                let t = self.temps.summary()
                d["temp"] = ["cpu": jn(t.cpu), "gpu": jn(t.gpu), "battery": jn(t.battery),
                             "skin": jn(t.skin),
                             "sensors": t.sensors.map { ["key": $0.key, "group": $0.group, "value": $0.value] }]
                if let data = try? JSONSerialization.data(withJSONObject: d),
                   let s = String(data: data, encoding: .utf8) {
                    print("SELFTEST   JSON 序列化成功，长度 \(s.count) 字节")
                    print("SELFTEST   WorkBuddy 进程检测 = \(self.workBuddyRunning() ? "是" : "否")")
                    print("SELFTEST   可见核心=\(ProcessInfo.processInfo.processorCount)  可见进程合计=\(d["visibleCpuShare"] ?? "?")%  总负载=\((d["cpu"] as? [String: Any])?["usage"] ?? "?")%")
                    if let ps = d["procs"] as? [[String: Any]], let p0 = ps.first {
                        print("SELFTEST   Top1 \(p0["name"] ?? "?")  占整机=\(p0["cpuShare"] ?? "?")%  单核=\(p0["cpuSingle"] ?? "?")%")
                    }
                } else {
                    print("SELFTEST   ✗ JSON 序列化失败")
                }
                DispatchQueue.main.async {
                    self.panel.pushJSON(d)
                    self.after(1.2) {
                        self.report("全尺寸")
                        self.panel.snapshot(to: "\(out)/native-01-全尺寸.png")
                        self.after(1.4) {
                            self.panel.minimizeToSidebar()
                            self.after(1.6) {
                                self.report("侧边栏折叠")
                                self.panel.snapshot(to: "\(out)/native-02-侧边栏.png")
                                self.after(1.4) {
                                    self.panel.expandFromSidebar()
                                    self.after(1.6) {
                                        self.report("重新展开")
                                        self.panel.applyPreset(w: 480, h: 300)
                                        self.after(1.6) {
                                            self.report("宽屏横向")
                                            self.panel.snapshot(to: "\(out)/native-03-宽屏横向.png")
                                            self.after(1.4) {
                                                self.panel.applyPreset(w: 282, h: 344)
                                                self.after(1.4) {
                                                    self.report("恢复标准")
                                                    self.testVerticalSnap()
                                                    self.testHorizontalMini(out) {
                                                        self.testSizeMemory {
                                                            self.testPresetUI {
                                                        self.testDiskHistory {
                                                            self.testDiskCadence {
                                                                self.testDiskPanelRow(out) {
                                                                self.testDiskUI(out) {
                                                                    self.testDocShots(out) {
                                                                        self.testExtra(out) {
                                                                            self.dumpWindows("end")
                                                                            print("SELFTEST   DONE")
                                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                                                NSApp.terminate(nil)
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    }
    }
    }

    /// 诊断：打印非主面板/非状态栏的窗口（排查多余浮层）
    private func dumpWindows(_ tag: String) {
        for w in NSApp.windows where !(w is NSPanel) && w.className != "NSStatusBarWindow" {
            print("WINDOW     [\(tag)] \(type(of: w)) \(w.frame) vis=\(w.isVisible) " +
                  "lvl=\(w.level.rawValue) title=[\(w.title)] alpha=\(w.alphaValue)")
        }
    }

    private func after(_ s: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block)
    }

    private func report(_ tag: String) {
        let f = panel.panel.frame
        let vf = (panel.panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let snap = ["left": abs(f.minX - vf.minX) < 1, "right": abs(f.maxX - vf.maxX) < 1,
                    "top": abs(f.maxY - vf.maxY) < 1, "bottom": abs(f.minY - vf.minY) < 1]
        let edges = snap.filter { $0.value }.keys.sorted().joined(separator: "/")
        let form = panel.isMini ? (panel.miniHorizontal ? "横" : "竖") : "-"
        print(String(format: "STATE      [%@] %.0fx%.0f @ (%.0f,%.0f)  可见=%@  迷你=%@  形态=%@  标题栏高=%.0f  贴边=%@",
                     tag, f.width, f.height, f.minX, f.minY,
                     panel.isVisible ? "是" : "否", panel.isMini ? "是" : "否", form,
                     panel.topInset, edges.isEmpty ? "无" : edges))
    }

    /// 自检：把窗口上沿/下沿故意推过可见区边缘（模拟拖到菜单栏 / Dock 后面），
    /// 贴边逻辑应把它拉回并贴住。左右贴边同理。
    private func testVerticalSnap() {
        guard let screen = panel.panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = panel.panel.frame
        // 上沿越过可见区顶部 40pt
        f.origin.y = vf.maxY - f.height + 40
        panel.panel.setFrame(f, display: false)
        panel.snapToEdges()
        report("上贴边(越界40pt)")
        // 下沿越过可见区底部 40pt
        f = panel.panel.frame
        f.origin.y = vf.minY - 40
        panel.panel.setFrame(f, display: false)
        panel.snapToEdges()
        report("下贴边(越界40pt)")
        // 别把测试产生的窗口位置写进偏好，下一次真实启动回到默认贴右
        Prefs.shared.clearGeometry()
    }

    /// 自检：贴到上边后收纳，应变成横向细带（宽 > 高），展开后回到完整窗口
    private func testHorizontalMini(_ out: String, done: @escaping () -> Void) {
        guard let screen = panel.panel.screen ?? NSScreen.main else { done(); return }
        let vf = screen.visibleFrame
        var f = panel.panel.frame
        f.origin.y = vf.maxY - f.height
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        panel.panel.setFrame(f, display: false)
        panel.snapToEdges()
        report("贴上边")
        let anchoredX = panel.panel.frame.minX   // 收起前小窗左缘，应等于收起后 mini 左缘
        panel.minimizeToSidebar()
        after(1.8) {
            self.report("横向收纳(贴上边)")
            let miniX = self.panel.panel.frame.minX
            print(String(format: "ANCHOR    横向(贴上边) 收起前小窗minX=%.0f  收起后mini.minX=%.0f  Δ=%.0f  (应≈0)", anchoredX, miniX, miniX - anchoredX))
            self.panel.snapshot(to: "\(out)/native-04-横向收纳.png")
            self.after(1.4) {
                self.panel.expandFromSidebar()
                self.after(1.4) {
                    self.report("从横向展开")
                    Prefs.shared.clearGeometry()
                    done()
                }
            }
        }
    }

    /// 自检：把小小窗拖到别的贴边 / 位置后再展开，
    /// 验证小窗「在小小窗当前位置按锚点展开」，而不是弹回收纳前的小窗老位置。
    private func testExpandFromMovedMini(_ out: String, done: @escaping () -> Void) {
        guard let screen = panel.panel.screen ?? NSScreen.main else { done(); return }
        let vf = screen.visibleFrame
        // 先把小窗放到一个明确位置并贴顶，再收纳
        var f = panel.panel.frame
        f = NSRect(x: vf.minX + 200, y: vf.maxY - f.height, width: f.width, height: f.height)
        panel.panel.setFrame(f, display: false)
        panel.snapToEdges()
        panel.minimizeToSidebar()
        after(1.6) {
            // 把小小窗拖到「底边 + 偏右」位置（模拟用户换边 / 换横向位置）
            var m = self.panel.panel.frame
            m.origin.x = vf.maxX - m.width - 60
            m.origin.y = vf.minY
            self.panel.panel.setFrame(m, display: false)
            self.panel.snapMiniToEdge()
            self.after(1.2) {
                self.report("小小窗拖到右下")
                let mini = self.panel.panel.frame
                let aX = mini.minX                       // 锚角：横向贴底 → 左下角（左缘 + 底缘）
                let aBottom = mini.minY
                self.panel.expandFromSidebar()
                self.after(1.4) {
                    let ef = self.panel.panel.frame
                    print(String(format: "EXPAND    拖后展开: mini.minX=%.0f  小窗.minX=%.0f  Δx=%.0f  (应≈0，横向跟随小小窗)", aX, ef.minX, ef.minX - aX))
                    print(String(format: "EXPAND    底缘对齐: mini.bottom=%.0f  小窗.bottom=%.0f  Δ=%.0f  (应≈0)", aBottom, ef.minY, ef.minY - aBottom))
                    self.report("拖后展开结果")
                    Prefs.shared.clearGeometry()
                    done()
                }
            }
        }
    }

    /// 自检：跨边拖动时横条 / 竖条应自动互换（如左右边拖到上下边 → 竖条变横条）。
    private func testMiniCrossEdge(_ out: String, done: @escaping () -> Void) {
        guard let screen = self.panel.panel.screen ?? NSScreen.main else { done(); return }
        let vf = screen.visibleFrame
        // 先收纳到顶边（横向）
        var f = self.panel.panel.frame
        f = NSRect(x: vf.minX + 200, y: vf.maxY - f.height, width: f.width, height: f.height)
        self.panel.panel.setFrame(f, display: false)
        self.panel.snapToEdges()
        self.panel.minimizeToSidebar()
        after(1.6) {
            // 拖到左边 → 应变成竖条、贴左边
            var m = self.panel.panel.frame
            m.origin.x = vf.minX
            m.origin.y = vf.midY - m.height / 2
            self.panel.panel.setFrame(m, display: false)
            self.panel.snapMiniToEdge()
            self.after(1.2) {
                let v = self.panel.panel.frame
                let isVert = self.panel.miniHorizontal == false
                let atLeft = abs(v.minX - vf.minX) < 2
                print(String(format: "CROSS     横→左: 形态=%@ 贴左=%@", isVert ? "竖" : "横", atLeft ? "是" : "否"))
                // 再拖到底边 → 应变成横条、贴底边
                var m2 = self.panel.panel.frame
                m2.origin.x = vf.midX - m2.width / 2
                m2.origin.y = vf.minY
                self.panel.panel.setFrame(m2, display: false)
                self.panel.snapMiniToEdge()
                self.after(1.2) {
                    let h = self.panel.panel.frame
                    let isHorz = self.panel.miniHorizontal == true
                    let atBottom = abs(h.minY - vf.minY) < 2
                    print(String(format: "CROSS     竖→底: 形态=%@ 贴底=%@", isHorz ? "横" : "竖", atBottom ? "是" : "否"))
                    self.report("跨边互换")
                    Prefs.shared.clearGeometry()
                    done()
                }
            }
        }
    }

    /// 自检：窗口尺寸是否真的被保存（拖拽缩放 + 套用预设两条路径）
    private func testSizeMemory(_ done: @escaping () -> Void) {
        var f = panel.panel.frame
        f.size = NSSize(width: 400, height: 300)
        panel.panel.setFrame(f, display: false)      // 模拟拖拽缩放 → windowDidResize → saveFrame
        after(0.35) {
            print("MEM       拖拽缩放后保存的尺寸 = \(String(describing: Prefs.shared.fullFrame))")
            self.panel.applyPreset(w: 380, h: 420)    // 走预设路径
            self.after(0.6) {
                print("MEM       套用预设后保存的尺寸 = \(String(describing: Prefs.shared.fullFrame))")
                self.report("尺寸保存/预设")
                Prefs.shared.clearGeometry()
                done()
            }
        }
    }

    /// 自检：预设弹层点选 → 前端 send("preset") → 原生套用尺寸（覆盖整条 UI→原生 链路）
    private func testPresetUI(_ done: @escaping () -> Void) {
        print("UI        点选预设前的尺寸 = \(panel.panel.frame.size)")
        panel.evalJS("applyPresetFromList(1)") { _ in     // 预设[1] = 宽松 360x440
            self.after(0.9) {
                print("UI        点选预设后的尺寸 = \(self.panel.panel.frame.size)")
                self.report("预设UI链路")
                done()
            }
        }
    }

    /// 自检：磁盘累计记账——真实计数器可读、增量/分桶/聚合数学正确、持久化可回读
    private func testDiskHistory(_ done: @escaping () -> Void) {
        let io = engine.diskIOCounters()
        print(String(format: "DISK      块设备累计 读=%.1fGB 写=%.1fGB 设备=%d",
                     Double(io.read) / 1e9, Double(io.write) / 1e9, io.devices))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perfdock-disk-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let h = DiskHistory(directory: dir)
        let now = Date()
        h.add(read: 4000, write: 2000, at: now)                              // 今天
        h.add(read: 1000, write: 1000, at: now.addingTimeInterval(-86400))   // 昨天
        h.record(read: 100, write: 100, at: now)                             // 基线
        h.record(read: 600, write: 400, at: now)                             // 增量 500 / 300
        let s = h.snapshot(now: now)
        let total = s["total"] as? [String: Int] ?? [:]
        let today = s["today"] as? [String: Int] ?? [:]
        let days = s["days"] as? [String: Any] ?? [:]
        let hours = s["hours"] as? [String: Any] ?? [:]
        let dr = days["r"] as? [Int] ?? [], dw = days["w"] as? [Int] ?? []
        let hr = hours["r"] as? [Int] ?? [], hw = hours["w"] as? [Int] ?? []
        let ok = total["r"] == 5500 && total["w"] == 3300
            && today["r"] == 4500 && today["w"] == 2300
            && dr.count == 30 && dw.count == 30 && hr.count == 24 && hw.count == 24
            && dr.reduce(0, +) == 5500 && dw.reduce(0, +) == 3300
        print("DISK      记账自检 total=\(total["r"] ?? -1)/\(total["w"] ?? -1) " +
              "today=\(today["r"] ?? -1)/\(today["w"] ?? -1) " +
              "days=\(dr.count) hours=\(hr.count) → \(ok ? "OK" : "FAIL")")
        h.flush()
        after(0.5) {
            let re = DiskHistory(directory: dir)
            let t2 = re.snapshot(now: now)["total"] as? [String: Int] ?? [:]
            print("DISK      持久化回读 total=\(t2["r"] ?? -1)/\(t2["w"] ?? -1) → " +
                  ((t2["r"] == 5500 && t2["w"] == 3300) ? "OK" : "FAIL"))
            done()
        }
    }

    /// 自检：磁盘记账节奏独立于「采样间隔」——主采样拉到 5s，磁盘仍应 1s 记账
    private func testDiskCadence(_ done: @escaping () -> Void) {
        let before = (diskHistory.snapshot()["total"] as? [String: Int])?["w"] ?? 0
        Prefs.shared.interval = 5000
        startSampling()                       // 主采样 5s；磁盘定时器仍是 1s
        // 制造真实写入，避免空转导致增量不可观测
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-disk-cadence.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.write(Data(repeating: 0x5A, count: 16 * 1024 * 1024))
            try? fh.synchronize()
            try? fh.close()
        }
        try? FileManager.default.removeItem(at: url)
        after(2.5) {
            let after = (self.diskHistory.snapshot()["total"] as? [String: Int])?["w"] ?? 0
            print("DISK      独立记账 采样间隔=5s  2.5s 内写入增量=\(after - before) 字节 → \(after > before ? "OK" : "FAIL")")
            Prefs.shared.interval = 1000
            self.startSampling()
            done()
        }
    }

    /// 自检：主面板「今日累计」行（磁盘模块开启时显示真实累计读/写）
    private func testDiskPanelRow(_ out: String, _ done: @escaping () -> Void) {
        panel.evalJS("PREF.modules.disk=true; if(window.LAST) render(LAST); requestFit(); 'ok'") { _ in
            self.after(0.8) {
                self.panel.snapshot(to: "\(out)/native-10-主面板-今日累计.png")
                self.panel.evalJS("""
                (function(){
                  var e = document.querySelector('.flow-wrap .row .lb.wide');
                  var rows = document.querySelectorAll('.flow-wrap .row');
                  return (e ? e.textContent : 'none') + '/' + rows.length;
                })()
                """) { r in
                    print("DISK      主面板今日累计行 = \(r ?? "?")  (应 今日累计/2)")
                    done()
                }
            }
        }
    }

    /// 自检：文档配图补拍——窄窗 / 设置面板 / 预设弹层（实机渲染，替代离屏 snap 的壁纸合成图）
    private func testDocShots(_ out: String, _ done: @escaping () -> Void) {
        // 1) 窄窗自适应
        if let vf = panel.panel.screen?.visibleFrame {
            var f = panel.panel.frame
            f.size = NSSize(width: 208, height: 440)
            f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
            panel.panel.setFrame(f, display: false)
        }
        after(0.8) {
            self.panel.snapshot(to: "\(out)/native-11-窄窗.png")
            // 2) 设置面板（恢复常规宽度并加高，展示更多设置项）
            self.panel.evalJS("document.getElementById('sizePop').classList.remove('open'); 'ok'") { _ in
                if let vf = self.panel.panel.screen?.visibleFrame {
                    var f = self.panel.panel.frame
                    f.size = NSSize(width: 282, height: 560)
                    f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
                    f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
                    self.panel.panel.setFrame(f, display: false)
                }
                self.panel.evalJS("document.getElementById('panel').classList.add('open'); 'ok'") { _ in
                    self.after(0.6) {
                        self.panel.snapshot(to: "\(out)/native-12-设置面板.png")
                        // 诊断：聚焦预设名称输入框，观察 TextInputUI 浮层是否被唤起
                        self.panel.evalJS("var i=document.querySelector('.pname'); if(i){i.focus();} 'ok'") { _ in
                            self.after(0.8) { self.dumpWindows("focus-pname") }
                        }
                        // 3) 预设弹层
                        self.panel.evalJS("document.getElementById('panel').classList.remove('open'); document.getElementById('sizePop').classList.add('open'); 'ok'") { _ in
                            self.after(0.6) {
                                self.panel.snapshot(to: "\(out)/native-13-预设弹层.png")
                                self.panel.evalJS("document.getElementById('sizePop').classList.remove('open'); 'ok'") { _ in
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 自检：磁盘读写页 UI 链路（页签切换 → 原生下发 → 图表数据到位）
    private func testDiskUI(_ out: String, _ done: @escaping () -> Void) {
        panel.evalJS("toggleTrend(); document.getElementById('tab-disk').click(); 'ok'") { _ in
            self.after(0.8) {
                self.panel.evalJS("""
                (function(){
                  var v = document.getElementById('view-disk');
                  var on = !!(v && v.classList.contains('on'));
                  var n = (window.DISK && DISK.days && DISK.days.r) ? DISK.days.r.length : 0;
                  var hn = (window.DISK && DISK.hours && DISK.hours.r) ? DISK.hours.r.length : 0;
                  return on + ',' + n + ',' + hn;
                })()
                """) { r in
                    print("DISK      UI 链路 view-disk/天数/小时数 = \(r ?? "?")   (应 1,30,24)")
                    // 捏合缩放等价链路：改变窗口跨度后本地聚合的桶数应随之变化（含上下限夹取）
                    self.panel.evalJS("""
                    (function(){
                      var a = diskBuckets().labels.length;
                      zoomDisk(0.5); var b = diskBuckets().labels.length;
                      zoomDisk(200); var c = diskBuckets().labels.length;
                      setDiskMode('hour');
                      var h0 = diskBuckets().labels.length;
                      zoomDisk(0.2); var h1 = diskBuckets().labels.length;
                      DISK_MODE = 'day'; DISK_VIEW.day.span = 7*86400000;
                      updateDiskRange(); drawDisk();
                      // 合成一次 ctrl+wheel（触控板捏合在 WebKit 里的表现形式），验证事件接线
                      var cv = document.getElementById('disk-canvas');
                      var before = DISK_VIEW.day.span;
                      cv.dispatchEvent(new WheelEvent('wheel', {ctrlKey:true, deltaY:-120, bubbles:true, cancelable:true}));
                      var wheel = (DISK_VIEW.day.span < before) ? 'Y' : 'N';
                      // 原生捏合桥（window.pd.zoomDisk）同样应生效
                      DISK_VIEW.day.span = 7*86400000;
                      var b2 = DISK_VIEW.day.span;
                      if (window.pd && window.pd.zoomDisk) window.pd.zoomDisk(0.5);
                      var native = (DISK_VIEW.day.span < b2) ? 'Y' : 'N';
                      DISK_VIEW.day.span = 7*86400000; updateDiskRange(); drawDisk();
                      return a+','+b+','+c+','+h0+','+h1+','+wheel+','+native;
                    })()
                    """) { z in
                        print("DISK      缩放 日桶数(默认/放大/缩到上限)=\(z ?? "?")  时桶数(默认/放大)=见后")
                        self.panel.snapshot(to: "\(out)/native-08-磁盘-按日.png")
                    self.panel.evalJS("document.getElementById('dk-hour').click(); 'ok'") { _ in
                        self.after(0.4) {
                            self.panel.snapshot(to: "\(out)/native-09-磁盘-按时.png")
                            self.panel.evalJS("document.getElementById('btn-trend-close').click(); 'ok'") { _ in
                                done()
                            }
                        }
                    }
                }
                }
            }
        }
    }

    /// 自检：验证新功能——趋势面板、网络/磁盘行、浅色主题
    private func testExtra(_ out: String, done: @escaping () -> Void) {
        // 趋势弹出层（磁盘页签可能在前序用例中处于激活态，显式切回实时趋势再截图）
        panel.evalJS("toggleTrend(); document.getElementById('tab-live').click(); document.getElementById('trend').classList.contains('open')") { r in
            print("TREND     open = \(r ?? "nil")")
            // 自检兜底：若本环境 SMC 不可读导致 tempHistory 仍为空，注入一条合成温度曲线，
            // 确保趋势面板的温度线 + 图例被真实渲染并截图验证（仅用于自检截图，不影响真实运行）
            self.panel.evalJS("""
            (function(){
              if (window.LAST && Array.isArray(LAST.tempHistory) && LAST.tempHistory.length >= 2) return;
              var base = (LAST && LAST.temp && LAST.temp.cpu != null) ? LAST.temp.cpu : 62;
              var a = []; for (var i = 0; i < 20; i++) { a.push(Math.round((base + 3 * Math.sin(i / 3) + (i % 4)) * 10) / 10); }
              if (!window.LAST) LAST = {}; LAST.tempHistory = a; if (typeof TREND_OPEN !== 'undefined' && TREND_OPEN) drawTrend();
            })();
            """) { _ in
            self.after(1.0) {
                self.report("趋势面板")
                self.panel.snapshot(to: "\(out)/native-05-趋势.png")
                self.after(0.4) {
                    // 关闭趋势，开启网络 / 磁盘模块并就地重绘
                    self.panel.evalJS("toggleTrend(); PREF.modules.net=true; PREF.modules.disk=true; render(LAST);") { _ in
                        self.after(0.5) {
                            self.report("网络磁盘")
                            self.panel.snapshot(to: "\(out)/native-06-网络磁盘.png")
                            self.after(0.4) {
                                // 浅色主题
                                self.panel.evalJS("PREF.theme='light'; applyTheme(); render(LAST);") { _ in
                                    self.after(0.5) {
                                        self.report("浅色主题")
                                        self.panel.snapshot(to: "\(out)/native-07-浅色.png")
                                        self.panel.snapshotWindow(to: "\(out)/native-14-浅色-整窗.png")
                                        // 关键回归：浅色主题下底座必须是浅色（低背景透明度也不会发灰）
                                        let rgb = self.panel.debugBackdropRGB()
                                        let isLight = (rgb?.0 ?? 0) > 200 && (rgb?.1 ?? 0) > 200
                                        print("THEME     浅色底座 RGB = \(rgb.map { "\($0),\($1),\($2)" } ?? "nil") → \(isLight ? "OK" : "FAIL")")
                                        // 低不透明度场景：底座不随透明度变化，仍是浅色
                                        self.panel.evalJS("PREF.bgOpacity=0.08; applyLook(); render(LAST);") { _ in
                                            self.after(0.4) {
                                                let rgb2 = self.panel.debugBackdropRGB()
                                                print("THEME     浅色+8%背景 底座 RGB = \(rgb2.map { "\($0),\($1),\($2)" } ?? "nil")")
                                                self.panel.evalJS("PREF.bgOpacity=0.42; applyLook(); render(LAST);") { _ in }
                                            }
                                        }
                                        // 浅色迷你条：文字应随主题变深（回归用户反馈）
                                        self.panel.minimizeToSidebar()
                                        self.after(0.8) {
                                            self.panel.snapshot(to: "\(out)/native-16-浅色-迷你.png")
                                            self.panel.expandFromSidebar()
                                            self.after(0.9) {
                                                self.after(0.4) { self.testExpandFromMovedMini(out) { self.testMiniCrossEdge(out) { done() } } }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        stopSampling()
        diskHistory.flush()      // 退出前落盘，避免丢最后一分钟的增量
        panel?.destroy()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: 采样

    private func startSampling() {
        stopSampling()
        startDiskMonitor()
        let ms = Int(max(250, Prefs.shared.interval))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(ms), leeway: .milliseconds(60))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopSampling() {
        timer?.cancel()
        timer = nil
        stopDiskMonitor()
    }

    /// 磁盘监控独立于主采样：固定 1s 读取真实块设备累计值并记账
    private func startDiskMonitor() {
        stopDiskMonitor()
        let t = DispatchSource.makeTimerSource(queue: diskQueue)
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let io = self.engine.diskIOCounters()   // 纯函数，独立于主采样
            self.diskHistory.record(io)
        }
        t.resume()
        diskTimer = t
    }

    private func stopDiskMonitor() {
        diskTimer?.cancel()
        diskTimer = nil
    }

    private func tick() {
        let mods = Prefs.shared.modules()
        // SMC 读取约 1ms，按时间节流：最短 1.5s 刷新一次，采样间隔更长时则每次都刷
        let needTemp = mods["temp"] ?? true
        if needTemp {
            let elapsed = Date().timeIntervalSince(lastTempAt)
            if temp == nil || elapsed >= 1.5 {
                temp = temps.summary()
                lastTempAt = Date()
            }
        }
        var d = engine.sample(topN: Prefs.shared.topN,
                              metric: Prefs.shared.procMetric)
        if let t = temp {
            d["temp"] = [
                "cpu": jn(t.cpu), "gpu": jn(t.gpu), "battery": jn(t.battery), "skin": jn(t.skin),
                "sensors": t.sensors.map { ["key": $0.key, "group": $0.group, "value": $0.value] },
            ]
            // 温度历史（用于趋势面板）：以 CPU 温度为代表，限长 48
            if let tc = t.cpu {
                lastTempCpu = tc
                tempHistory.append(tc)
                if tempHistory.count > 48 { tempHistory.removeFirst() }
                d["tempHistory"] = tempHistory.map { ($0 * 10).rounded() / 10 }
            }
        }
        // 磁盘累计读写由独立的 1s 定时器记账（不受采样间隔影响）；这里只把「今日累计」带给前端
        let dt = diskHistory.todayTotals()
        d["diskToday"] = ["r": dt.read > UInt64(Int.max) ? Int.max : Int(dt.read),
                          "w": dt.write > UInt64(Int.max) ? Int.max : Int(dt.write)]
        // 缓存最近一次采样，供菜单栏内联读数使用
        if let c = d["cpu"] as? [String: Any], let u = c["usage"] as? Double { lastCpu = u }
        if let m = d["mem"] as? [String: Any], let p = m["percent"] as? Double { lastMem = p }
        panel.pushJSON(d)
        updateStatusItem()
    }

    // MARK: WorkBuddy 联动

    private func workBuddyRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: WB_BUNDLE)
            .contains { !$0.isTerminated }
    }

    private func observeWorkBuddy() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func appLaunched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == WB_BUNDLE else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.show()
            self.startSampling()
        }
    }

    @objc private func appTerminated(_ n: Notification) {
        guard Prefs.shared.hideOnWorkBuddyQuit else { return }
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == WB_BUNDLE else { return }
        DispatchQueue.main.async { [weak self] in
            self?.panel.hide()
            self?.stopSampling()
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = nil                       // 改用文字读数，去掉静态图标
            b.toolTip = "PerfDock 性能监视"
        }
        updateStatusItem()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 菜单栏内联实时读数：CPU% · 内存% · 温度°。采样停止时冻结在最后一次数值。
    private func updateStatusItem() {
        guard let b = statusItem.button else { return }
        let cpu = Int(round(lastCpu))
        let mem = Int(round(lastMem))
        let tStr = lastTempCpu.isFinite && lastTempCpu > 0 ? String(format: "%.0f°", lastTempCpu) : "—"
        let text = "  CPU \(cpu)%   内存 \(mem)%   \(tStr)  "
        let fs = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: fs,
            .foregroundColor: NSColor.controlTextColor,
        ])
        b.attributedTitle = attr
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let vis = panel.isVisible
        add(menu, vis ? "隐藏悬浮窗" : "显示悬浮窗", #selector(toggleVisible), key: "h")
        add(menu, "折叠到侧边栏", #selector(doMinimize), key: "m", enabled: vis)
        menu.addItem(.separator())
        add(menu, "始终置顶", #selector(toggleTop), check: Prefs.shared.alwaysOnTop)
        add(menu, "WorkBuddy 退出时隐藏", #selector(toggleHideOnQuit), check: Prefs.shared.hideOnWorkBuddyQuit)
        add(menu, "登录时自动启动", #selector(toggleAgent), check: Prefs.shared.launchAtLogin)
        let iv = NSMenuItem(title: "采样间隔", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [1000, 3000, 5000, 10000, 30000] {
            let it = NSMenuItem(title: "\(v / 1000)s",
                                action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = Int(Prefs.shared.interval) == v ? .on : .off
            sub.addItem(it)
        }
        iv.submenu = sub
        menu.addItem(iv)
        menu.addItem(.separator())
        add(menu, "打开设置面板", #selector(openSettings), key: ",")
        add(menu, "退出 PerfDock", #selector(quit), key: "q")
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector,
                     key: String? = nil, check: Bool? = nil, enabled: Bool = true) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key ?? "")
        it.target = self
        it.isEnabled = enabled
        if let c = check { it.state = c ? .on : .off }
        m.addItem(it)
    }

    @objc private func toggleVisible() {
        if panel.isVisible {
            panel.hide(); stopSampling()
        } else {
            NSApp.activate(ignoringOtherApps: true)   // 呼出时激活，确保面板与监听可用
            panel.show(); panel.syncPrefs(Prefs.shared); startSampling()
        }
    }

    @objc private func doMinimize() { panel.minimizeToSidebar() }

    @objc private func toggleTop() {
        Prefs.shared.alwaysOnTop.toggle()
        panel.setAlwaysOnTop(Prefs.shared.alwaysOnTop)
        panel.syncPrefs(Prefs.shared)
    }

    @objc private func toggleHideOnQuit() {
        Prefs.shared.hideOnWorkBuddyQuit.toggle()
        panel.syncPrefs(Prefs.shared)
    }

    @objc private func toggleAgent() {
        Prefs.shared.launchAtLogin.toggle()
        installAgent(Prefs.shared.launchAtLogin)
        panel.syncPrefs(Prefs.shared)
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        Prefs.shared.interval = Double(v)
        panel.syncPrefs(Prefs.shared)
        if panel.isVisible { startSampling() }
    }

    @objc private func openSettings() {
        if !panel.isVisible { panel.show(); startSampling() }
        panel.openSettingsPanel()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 系统外观跟随

    private func observeAppearance() {
        // 系统深色/浅色切换时主动通知前端，让「跟随系统」主题即时生效
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged(_:)),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func appearanceChanged(_ n: Notification) {
        let a = Prefs.shared.appearance
        panel.evalJS("window.pd && window.pd.appearance('\(a)');")
    }

    // MARK: 全局快捷键

    private var lastHotkeyAt: Date = .distantPast

    /// 默认 ⌥⇧P 切换悬浮窗显隐。本地监听覆盖 App 自身在前台的情况，全局监听覆盖后台。
    private func installHotkeyIfNeeded() {
        removeHotkey()
        guard Prefs.shared.hotkeyEnabled else { return }
        let mask: NSEvent.ModifierFlags = [.option, .shift]
        let keyCode: UInt16 = 35   // 'P'
        let handler: (NSEvent) -> Bool = { [weak self] e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .intersection([.option, .shift, .command, .control]) == mask,
                  e.keyCode == keyCode else { return false }
            // 过滤长按自动重复：避免一次按键被系统连续触发导致反复切换
            guard Date().timeIntervalSince(self?.lastHotkeyAt ?? .distantPast) > 0.3 else { return true }
            self?.lastHotkeyAt = Date()
            self?.toggleVisible()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            _ = handler(e)
        }) { hotkeyMonitors.append(g) }
        let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            return handler(e) ? nil : e   // 仅命中快捷键时消费，其余按键照常放行（修复吞掉输入框按键）
        }
        if let l { hotkeyMonitors.append(l) }
    }

    private func removeHotkey() {
        for m in hotkeyMonitors { NSEvent.removeMonitor(m) }
        hotkeyMonitors.removeAll()
    }

    // MARK: 前端指令

    func panelCommand(_ cmd: String, payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch cmd {
            case "minimize":
                self.panel.minimizeToSidebar()
            case "expand":
                self.panel.expandFromSidebar()
            case "hide":
                self.panel.hide()
                self.stopSampling()
            case "preset":
                // 前端窗口预设弹层点选 → 一键套用尺寸
                if let w = (payload["w"] as? NSNumber)?.doubleValue,
                   let h = (payload["h"] as? NSNumber)?.doubleValue {
                    self.panel.applyPreset(w: CGFloat(w), h: CGFloat(h))
                }
            case "fit":
                // 前端按内容自然高度请求重设窗口高度（开关显示项 / 横竖形态变化时自动适配）
                if let h = (payload["h"] as? NSNumber)?.doubleValue {
                    self.panel.fitToContentHeight(CGFloat(h))
                }
            case "quit":
                NSApp.terminate(nil)
            case "ready":
                // 页面脚本就绪：此时同步偏好才不会丢（比定时兜底可靠）
                self.panel.syncPrefs(Prefs.shared)
            case "diskHistory":
                // 磁盘读写页打开 / 定时刷新时按需拉取聚合数据（含近 30 天 + 近 24 小时）
                self.panel.pushDiskHistory(self.diskHistory.snapshot())
            case "theme":
                // 前端解析后的有效主题（含 auto 跟随系统）→ 原生底座同步换色
                if let m = payload["mode"] as? String {
                    self.panel.setTheme(light: m == "light")
                }
            case "resetPrefs":
                Prefs.shared.reset()
                self.panel.setBlur(Prefs.shared.blur)
                self.panel.setAlwaysOnTop(Prefs.shared.alwaysOnTop)
                self.installAgent(Prefs.shared.launchAtLogin)
                self.panel.syncPrefs(Prefs.shared)
                if self.panel.isVisible { self.startSampling() }
            case "pref":
                guard let key = payload["key"] as? String else { return }
                Prefs.shared.apply(key, payload["value"] as Any)
                switch key {
                case "bgOpacity":     self.panel.setBackgroundOpacity(Prefs.shared.bgOpacity)
                case "blur":          self.panel.setBlur(Prefs.shared.blur)
                case "alwaysOnTop":   self.panel.setAlwaysOnTop(Prefs.shared.alwaysOnTop)
                case "launchAtLogin": self.installAgent(Prefs.shared.launchAtLogin)
                case "hotkeyEnabled": self.installHotkeyIfNeeded()
                case "interval":      if self.panel.isVisible { self.startSampling() }
                default: break
                }
            default:
                break
            }
        }
    }

    // MARK: 登录项

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AGENT_LABEL).plist")
    }

    private func installAgent(_ on: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: agentURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(AGENT_LABEL)</string>
              <key>ProgramArguments</key>
              <array><string>\(exe)</string><string>--silent</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><false/>
              <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? plist.write(to: agentURL, atomically: true, encoding: .utf8)
            // 只写 plist：~/Library/LaunchAgents 由 launchd 在下次登录时自动加载。
            // 这里不主动 bootstrap，避免当前正在运行的本体被 launchd 再拉起一个实例。
        } else {
            launchctl(["bootout", "gui/\(getuid())/\(AGENT_LABEL)"])
            try? fm.removeItem(at: agentURL)
        }
    }

    private func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// nil 安全的 JSON 值（避免 JSONSerialization 因 Optional 抛错）
func jn(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
