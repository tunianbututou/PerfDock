// snap/main.swift — 用离屏 WKWebView 渲染 UI 并导出 PNG，用于视觉校验
import AppKit
import WebKit

let htmlPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "UI/index.html"
let outDir   = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/shots"
let htmlURL  = URL(fileURLWithPath: htmlPath).standardizedFileURL
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

final class Snapper: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var steps: [(String, NSSize, String?)] = []
    var idx = 0

    /// 临时测量用：强制套用 wide 类并回报「放得下所需的最小窗口高度」
    static let MJ = "(function(){var w=window.innerWidth,h=window.innerHeight;"
        + "document.body.classList.toggle('wide', w>=380||(w>=340&&h<300));"
        + "var m=document.getElementById('content');var cols=m.querySelector('.cols');"
        + "var content=cols?cols.getBoundingClientRect().height:0;"
        + "var content2=m.getBoundingClientRect().height;"
        + "var chrome=h-m.clientHeight;"
        + "return w+'x'+h+' body='+document.body.className+' cols='+Math.round(content)"
        + "+' need='+Math.round(content+2+chrome)+' chrome='+chrome;})()"

    override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 276, height: 432), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 276, height: 432),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web
        window.alphaValue = 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.orderFrontRegardless()

        steps = [
            ("01-标准形态", NSSize(width: 280, height: 460), nil),
            ("02-窄窗自适应", NSSize(width: 208, height: 440), nil),
            ("03-侧边栏迷你", NSSize(width: 26, height: 320), "window.pd.mode('mini')"),
            ("04-设置面板", NSSize(width: 280, height: 460),
             "window.pd.mode('full');document.getElementById('panel').classList.add('open')"),
            ("05-背景更透·文字更清", NSSize(width: 280, height: 460),
             "document.getElementById('panel').classList.remove('open');window.pd.init({prefs:{bgOpacity:0.10,textOpacity:1.0}})"),
            ("06-背景更实·文字略淡", NSSize(width: 280, height: 460),
             "window.pd.init({prefs:{bgOpacity:0.88,textOpacity:0.62}})"),
            ("07-宽屏双栏", NSSize(width: 460, height: 380), nil),
            ("08-预设弹层", NSSize(width: 282, height: 344), "document.getElementById('sizePop').classList.add('open')"),
            ("09-设置预设", NSSize(width: 282, height: 344),
             "document.getElementById('panel').classList.add('open');document.getElementById('panel-body').scrollTop=document.getElementById('panel-body').scrollHeight"),
            ("10-横向收纳", NSSize(width: 300, height: 32),
             "window.pd.mode('mini','h');setMiniBar('mb-cpu',46);setMiniBar('mb-gpu',58);setMiniBar('mb-mem',72)"),
            ("11-宽窗双栏(矮)", NSSize(width: 440, height: 290),
             "window.pd.mode('full');document.getElementById('sizePop').classList.remove('open');document.getElementById('panel').classList.remove('open');setTimeout(function(){var w=window.innerWidth,h=window.innerHeight;document.body.classList.toggle('wide',w>=380||(w>=340&&h<300));},80)"),

            ("12-竖屏最小 282x348", NSSize(width: 282, height: 348), nil),
            ("13-横屏最小 380x247", NSSize(width: 380, height: 247),
             "setTimeout(function(){var w=window.innerWidth,h=window.innerHeight;document.body.classList.toggle('wide',w>=380||(w>=340&&h<300));},80)"),
        ]
    }

    func start() {
        web.navigationDelegate = self
        web.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { self.next() }
    }

    func next() {
        guard idx < steps.count else { NSApp.terminate(nil); return }
        let (name, size, js) = steps[idx]
        idx += 1
        if name.hasPrefix("PROBE ") {
            web.evaluateJavaScript(js ?? "1") { v, e in
                print("探针 \(name): \(String(describing: v)) \(e.map { "错误 \($0)" } ?? "")")
                self.next()
            }
            return
        }
        window.setContentSize(size)
        web.setFrameSize(size)
        let shoot = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.shoot(name: name, size: size) }
        }
        if let js { web.evaluateJavaScript(js) { _, _ in shoot() } } else { shoot() }
    }

    func shoot(name: String, size: NSSize) {
        let c = WKSnapshotConfiguration()
        c.rect = NSRect(origin: .zero, size: size)
        web.takeSnapshot(with: c) { img, err in
            guard let img else {
                print("截图失败 \(name): \(String(describing: err))")
                self.next(); return
            }
            // 合成到一张模拟桌面背景上，便于判断透明玻璃效果
            let pad: CGFloat = 22
            let canvas = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
            let composed = NSImage(size: canvas)
            composed.lockFocus()
            let grad = NSGradient(colors: [
                NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.34, alpha: 1),
                NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)])
            grad?.draw(in: NSRect(origin: .zero, size: canvas), angle: 300)
            // 一段模拟的“桌面内容”，用来检验模糊是否真的透过去
            NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
            NSRect(x: 0, y: canvas.height * 0.30, width: canvas.width, height: 26).fill()
            NSColor(calibratedRed: 1, green: 0.55, blue: 0.25, alpha: 0.30).setFill()
            NSRect(x: canvas.width * 0.6, y: 0, width: canvas.width * 0.25, height: canvas.height).fill()
            img.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
            composed.unlockFocus()

            if let tiff = composed.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let out = (outDir as NSString).appendingPathComponent("\(name).png")
                try? png.write(to: URL(fileURLWithPath: out))
                print("已导出 \(out)")
            }
            // 采样几个关键点的实际像素值，用数值而不是肉眼判断透明度是否符合预期
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                let w = rep.pixelsWide, h = rep.pixelsHigh
                func sample(_ fx: Double, _ fy: Double) -> String {
                    let px = min(w-1, max(0, Int(Double(w) * fx)))
                    let py = min(h-1, max(0, Int(Double(h) * fy)))
                    guard let c = rep.colorAt(x: px, y: py) else { return "—" }
                    let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255),
                        b = Int(c.blueComponent * 255), a = Int(c.alphaComponent * 255)
                    return "(\(r),\(g),\(b),\(a))"
                }
                print("  采样 中点\(sample(0.5,0.5))  左上\(sample(0.25,0.20))  文字区\(sample(0.62,0.92))")
            }
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let snapper = Snapper()
app.delegate = nil
DispatchQueue.main.async { snapper.start() }
app.run()
