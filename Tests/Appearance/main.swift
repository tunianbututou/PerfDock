import AppKit
import WebKit

// 独立可执行文件使用自己的 UserDefaults 域，不启动 AppDelegate 或磁盘采样。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PanelController()
let prefs = Prefs.shared
let fx = controller.panel.contentView!.subviews.compactMap { $0 as? NSVisualEffectView }.first!
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
for light in [false, true] {
    controller.setTheme(light: light)
    for blur in [false, true] {
        controller.setBlur(blur)
        for opacity in [0.08, 0.42, 1.0] {
            prefs.bgOpacity = opacity
            controller.syncPrefs(prefs)
            check(abs(fx.alphaValue - opacity) < 0.001,
                  "light=\(light) blur=\(blur) opacity=\(opacity) native=\(fx.alphaValue)")
            check(fx.isHidden == !blur, "blur switch preserved")
            check(controller.panel.alphaValue == 1, "text/window opacity independent")
        }
    }
}

func pump(_ seconds: Double = 0.3) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}
func js(_ script: String) -> Any? {
    var result: Any?; var completed = false
    controller.evalJS(script) { result = $0; completed = true }
    let end = Date(timeIntervalSinceNow: 5)
    while !completed && Date() < end { pump(0.02) }
    return result
}
controller.panel.orderFrontRegardless()
pump(1)
check(js("typeof window.pd") as? String == "object", "real WKWebView loaded")
controller.syncPrefs(prefs)
pump()
for theme in ["dark", "light"] {
    _ = js("PREF.theme='\(theme)'; applyTheme(); renderPanel(); document.getElementById('panel').classList.add('open');")
    pump()
    check(js("getComputedStyle(document.getElementById('panel')).backgroundColor") as? String == "rgba(0, 0, 0, 0)", "\(theme) settings reuse transparent background")
    check(js("getComputedStyle(document.querySelector('main')).visibility") as? String == "hidden", "settings hide underlying content")
    for value in [8, 42, 100] {
        _ = js("var slider=document.querySelector('[data-sl=bgOpacity]'); slider.value=\(value); slider.dispatchEvent(new Event('input',{bubbles:true}));")
        check(js("document.documentElement.style.getPropertyValue('--bg-a')") as? String == String(format: "%.3f", Double(value)/100), "\(theme) slider input updates tint \(value)%")
    }
    _ = js("document.getElementById('panel').classList.remove('open')")
    pump()
    check(js("!document.getElementById('root').classList.contains('settings-open') && getComputedStyle(document.querySelector('main')).pointerEvents !== 'none'") as? Bool == true, "closing settings restores content")
}
controller.setBlur(true)
controller.setBackgroundOpacity(0.42)
controller.snapshotWindow(to: "work/appearance-settings.png")
controller.panel.orderOut(nil)
exit(failures == 0 ? 0 : 1)

