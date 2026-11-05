// Prefs.swift — 偏好设置（Swift 与前端共享的单一数据源，持久化在 UserDefaults）
import Foundation
import AppKit

final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private let P = "pd."

    static let moduleKeys = ["cpu", "gpu", "mem", "temp", "procs", "battery", "net", "disk", "foot"]

    /// 两个预设：竖屏（宽度保持 282，高度刚好放下全部元素）、横屏（能放下全部元素的较小尺寸）
    static let defaultPresets: [[String: Any]] = [
        ["name": "竖屏", "w": 282, "h": 348],
        ["name": "横屏", "w": 380, "h": 247],
    ]
    /// 预设默认值的「代次」；改动默认预设时 +1，老用户存的旧预设会被替换为新默认
    private let presetsSchema = 2

    private func bool(_ k: String, _ def: Bool) -> Bool {
        d.object(forKey: P + k) == nil ? def : d.bool(forKey: P + k)
    }
    private func dbl(_ k: String, _ def: Double) -> Double {
        d.object(forKey: P + k) == nil ? def : d.double(forKey: P + k)
    }
    private func str(_ k: String, _ def: String) -> String {
        (d.string(forKey: P + k)) ?? def
    }

    var interval: Double { get { dbl("interval", 1000) } set { d.set(newValue, forKey: P + "interval") } }
    var procMetric: String { get { str("procMetric", "mem") } set { d.set(newValue, forKey: P + "procMetric") } }
    var basis: String { get { str("basis", "share") } set { d.set(newValue, forKey: P + "basis") } }
    var topN: Int { get { Int(dbl("topN", 3)) } set { d.set(Double(newValue), forKey: P + "topN") } }
    var presets: [[String: Any]] {
        get {
            if d.integer(forKey: P + "presetsSchema") == presetsSchema,
               let a = d.array(forKey: P + "presets") as? [[String: Any]], !a.isEmpty { return a }
            return Self.defaultPresets
        }
        set { d.set(newValue, forKey: P + "presets") }
    }

    /// 默认预设换代时，把老用户存的旧预设替换为新默认（否则看不到新预设）
    func migratePresetsIfNeeded() {
        guard d.integer(forKey: P + "presetsSchema") != presetsSchema else { return }
        presets = Self.defaultPresets
        d.set(presetsSchema, forKey: P + "presetsSchema")
    }
    var bgOpacity: Double { get { dbl("bgOpacity", 0.42) } set { d.set(newValue, forKey: P + "bgOpacity") } }
    var textOpacity: Double { get { dbl("textOpacity", 1.0) } set { d.set(newValue, forKey: P + "textOpacity") } }
    var blur: Bool { get { bool("blur", true) } set { d.set(newValue, forKey: P + "blur") } }
    var alwaysOnTop: Bool { get { bool("alwaysOnTop", true) } set { d.set(newValue, forKey: P + "alwaysOnTop") } }
    var hideOnWorkBuddyQuit: Bool { get { bool("hideOnWorkBuddyQuit", true) } set { d.set(newValue, forKey: P + "hideOnWorkBuddyQuit") } }
    var launchAtLogin: Bool { get { bool("launchAtLogin", true) } set { d.set(newValue, forKey: P + "launchAtLogin") } }

    // ── 外观：主题与主色 ──
    /// dark / light / auto（auto = 跟随系统，由原生层下发有效外观）
    var theme: String { get { str("theme", "dark") } set { d.set(newValue, forKey: P + "theme") } }
    /// 主色（十六进制），驱动 --brand
    var brand: String { get { str("brand", "#4582E6") } set { d.set(newValue, forKey: P + "brand") } }
    /// 当前系统有效外观（dark / light），由原生层写入，前端用于解析 auto 主题
    var appearance: String {
        let a = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return a == .darkAqua ? "dark" : "light"
    }

    // ── 全局快捷键 ──
    var hotkeyEnabled: Bool { get { bool("hotkeyEnabled", true) } set { d.set(newValue, forKey: P + "hotkeyEnabled") } }

    func modules() -> [String: Bool] {
        var out: [String: Bool] = [:]
        // 网络 / 磁盘默认关闭：避免破坏竖屏 348 的「完全显示所有元素」最小高度；需要时在设置里开启
        for k in Self.moduleKeys { out[k] = bool("mod." + k, k == "net" || k == "disk" ? false : true) }
        return out
    }
    func setModule(_ k: String, _ v: Bool) { d.set(v, forKey: P + "mod." + k) }

    // MARK: 与前端交换的数据

    func json() -> [String: Any] {
        [
            "modules": modules(),
            "interval": interval,
            "procMetric": procMetric,
            "basis": basis,
            "topN": topN,
            "presets": presets,
            "bgOpacity": bgOpacity,
            "textOpacity": textOpacity,
            "blur": blur,
            "alwaysOnTop": alwaysOnTop,
            "hideOnWorkBuddyQuit": hideOnWorkBuddyQuit,
            "launchAtLogin": launchAtLogin,
            "theme": theme,
            "brand": brand,
            "appearance": appearance,
            "hotkeyEnabled": hotkeyEnabled,
        ]
    }

    /// 前端回报的偏好变更
    func apply(_ key: String, _ value: Any) {
        switch key {
        case "interval":      if let v = value as? Double { interval = v }
        case "procMetric":    if let v = value as? String { procMetric = v }
        case "basis":         if let v = value as? String { basis = v }
        case "topN":          if let v = value as? Double { topN = Int(v) }
        case "presets":       if let v = value as? [[String: Any]] { presets = v }
        case "bgOpacity":     if let v = value as? Double { bgOpacity = v }
        case "textOpacity":   if let v = value as? Double { textOpacity = v }
        case "blur":          if let v = value as? Bool { blur = v }
        case "alwaysOnTop":   if let v = value as? Bool { alwaysOnTop = v }
        case "hideOnWorkBuddyQuit": if let v = value as? Bool { hideOnWorkBuddyQuit = v }
        case "launchAtLogin": if let v = value as? Bool { launchAtLogin = v }
        case "theme":         if let v = value as? String { theme = v }
        case "brand":         if let v = value as? String { brand = v }
        case "hotkeyEnabled": if let v = value as? Bool { hotkeyEnabled = v }
        case "modules":
            // 前端传来的是 JS 对象，值经 JSONSerialization 变成 NSNumber，需要显式取值
            if let m = value as? [String: Any] {
                for (k, v) in m {
                    if let n = v as? NSNumber { setModule(k, n.boolValue) }
                    else if let b = v as? Bool { setModule(k, b) }
                }
            }
        default: break
        }
    }

    func reset() {
        for k in ["interval","procMetric","basis","topN","presets","bgOpacity","textOpacity",
                  "blur","alwaysOnTop","hideOnWorkBuddyQuit","launchAtLogin","theme","brand","hotkeyEnabled"] {
            d.removeObject(forKey: P + k)
        }
        for k in Self.moduleKeys { d.removeObject(forKey: P + "mod." + k) }
    }

    // MARK: 窗口几何

    var fullFrame: NSRect? {
        get { let s = d.string(forKey: P + "fullFrame"); return s.flatMap(NSRectFromString) }
        set { if let v = newValue { d.set(NSStringFromRect(v), forKey: P + "fullFrame") } }
    }
    var miniFrame: NSRect? {
        get { let s = d.string(forKey: P + "miniFrame"); return s.flatMap(NSRectFromString) }
        set { if let v = newValue { d.set(NSStringFromRect(v), forKey: P + "miniFrame") } }
    }
    var wasMini: Bool { get { bool("wasMini", false) } set { d.set(newValue, forKey: P + "wasMini") } }

    /// 清空窗口几何（自检用，保证从确定状态开始）
    func clearGeometry() {
        d.removeObject(forKey: P + "fullFrame")
        d.removeObject(forKey: P + "miniFrame")
        d.removeObject(forKey: P + "wasMini")
    }
}
