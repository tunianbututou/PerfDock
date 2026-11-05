// SMCTemp.swift — 温度传感器采集
// 免授权优先（SMC 直读 / 电池温度），失败时降级为「一次授权 + 后台常驻采样」。

import Foundation
import IOKit
import Darwin

public struct TempSensor {
    public var key: String
    public var group: String
    public var value: Double
}

public final class TempReader {

    // MARK: - SMC 直读

    private static let KERNEL_INDEX_SMC: UInt32 = 2
    private static let CMD_READ_BYTES: UInt8 = 5
    private static let CMD_READ_KEYINFO: UInt8 = 9
    private static let SMC_STRUCT_SIZE = 80

    private var conn: io_connect_t = 0
    private var smcOpened = false

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8.prefix(4) { r = (r << 8) | UInt32(ch) }
        return r
    }

    private func openSMC() -> Bool {
        if smcOpened { return conn != 0 }
        smcOpened = true
        guard let match = IOServiceMatching("AppleSMC"),
              let device = IOServiceGetMatchingService(kIOMainPortDefault, match) as io_service_t?,
              device != 0 else { conn = 0; return false }
        defer { IOObjectRelease(device) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(device, mach_task_self_, 0, &c)
        if kr == KERN_SUCCESS { conn = c; return true }
        conn = 0
        return false
    }

    /// 用固定偏移的原始缓冲区调用 AppleSMC，规避 Swift 结构体布局差异
    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.SMC_STRUCT_SIZE)
        var outSize = size_t(Self.SMC_STRUCT_SIZE)
        let kr = input.withUnsafeMutableBytes { inBuf -> kern_return_t in
            output.withUnsafeMutableBytes { outBuf -> kern_return_t in
                IOConnectCallStructMethod(conn, Self.KERNEL_INDEX_SMC,
                                          inBuf.baseAddress, Self.SMC_STRUCT_SIZE,
                                          outBuf.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    private func readKey(_ key: String) -> (data: [UInt8], type: String)? {
        guard openSMC() else { return nil }
        let keyCode = fourCC(key)

        // 1) 取 keyInfo（数据类型 + 长度）
        var input = [UInt8](repeating: 0, count: Self.SMC_STRUCT_SIZE)
        input.withUnsafeMutableBytes { $0.storeBytes(of: keyCode, toByteOffset: 0, as: UInt32.self) }
        input[42] = Self.CMD_READ_KEYINFO
        guard let kiOut = call(&input), kiOut[40] == 0 else { return nil }
        let dataSize = kiOut.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let dataTypeRaw = kiOut.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        guard dataSize > 0, dataSize <= 32 else { return nil }

        // 2) 读数据字节
        var input2 = [UInt8](repeating: 0, count: Self.SMC_STRUCT_SIZE)
        input2.withUnsafeMutableBytes { $0.storeBytes(of: keyCode, toByteOffset: 0, as: UInt32.self) }
        input2.withUnsafeMutableBytes { $0.storeBytes(of: dataSize, toByteOffset: 28, as: UInt32.self) }
        input2.withUnsafeMutableBytes { $0.storeBytes(of: dataTypeRaw, toByteOffset: 32, as: UInt32.self) }
        input2[42] = Self.CMD_READ_BYTES
        guard let out = call(&input2), out[40] == 0 else { return nil }

        var typeStr = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            if let scalar = UnicodeScalar((dataTypeRaw >> UInt32(shift)) & 0xFF) {
                typeStr.append(Character(scalar))
            }
        }
        return (Array(out[48..<48 + Int(dataSize)]), typeStr)
    }

    private func decode(_ bytes: [UInt8], type: String) -> Double? {
        // SMC 在不同芯片/键上的字节序不一致：Apple Silicon 的 flt 为小端，
        // sp78 历史上为大端。这里两种都试，并用「是否落在合理 SoC 温度区间」做判据，
        // 避免把全零/异常读数当成温度展示。
        func plausible(_ v: Double) -> Double? {
            (v.isFinite && v >= 10 && v <= 135) ? v : nil
        }
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let le = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let be = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            if let v = plausible(Double(Float(bitPattern: le))) { return v }
            if let v = plausible(Double(Float(bitPattern: be))) { return v }
            return nil
        case "sp78", "sp87", "sp5a", "sp5b", "sp69", "sp6e", "sp6f", "sp70", "sp7a":
            guard bytes.count >= 2 else { return nil }
            let be = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
            let le = Double(Int16(bitPattern: UInt16(bytes[1]) << 8 | UInt16(bytes[0]))) / 256.0
            return plausible(be) ?? plausible(le)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return plausible(Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "ui8":
            return bytes.first.flatMap { plausible(Double($0)) }
        default:
            return nil
        }
    }

    /// 已知的 Apple Silicon 温度传感器键；读不到就跳过，不编造
    private static let candidates: [(String, String)] = [
        ("Tp01", "CPU"), ("Tp05", "CPU"), ("Tp09", "CPU"), ("Tp0b", "CPU"),
        ("Tp0D", "CPU"), ("Tp0T", "CPU"), ("Tp0f", "CPU"), ("Tp0j", "CPU"),
        ("Tp0n", "CPU"), ("Tp0r", "CPU"), ("Tp0v", "CPU"), ("Tp0H", "CPU"),
        ("Tg0D", "GPU"), ("Tg0P", "GPU"), ("Tg0j", "GPU"), ("Tg0L", "GPU"),
        ("Tg0T", "GPU"), ("Tg0f", "GPU"), ("Tg0b", "GPU"),
        ("TB0T", "电池"), ("TB1T", "电池"), ("TB2T", "电池"), ("TB0t", "电池"),
        ("Ts0P", "机身"), ("Ts1P", "机身"), ("Ts0S", "机身"),
        ("TC0P", "CPU"), ("TA0P", "环境"),
    ]

    /// 调试用：dump 指定 key 的原始返回，判断传感器是否对非特权进程可用
    public func debugKeys(_ keys: [String]) -> [(String, Int, String, String)] {
        var out: [(String, Int, String, String)] = []
        for k in keys {
            guard let (bytes, type) = readKey(k) else {
                out.append((k, -1, "读取失败", ""))
                continue
            }
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let decoded = decode(bytes, type: type).map { String(format: "%.3f", $0) } ?? "无法解码"
            out.append((k, bytes.count, type, "\(hex)  → \(decoded)"))
        }
        return out
    }

    /// 汇总出用于展示的几个关键读数
    public struct TempSummary {
        public var cpu: Double?
        public var gpu: Double?
        public var battery: Double?
        public var skin: Double?
        public var sensors: [TempSensor]
    }

    /// 同组传感器的稳健取值：取中位数。
    /// 实测同一组里混着不同物理位置的传感器 —— Tp* 中 5 个核心传感器稳定在 54–56 °C，
    /// 而 Tp0f 属于热点类传感器，会在 55–104 °C 之间剧烈摆动。取最大值会让读数被它带跑、
    /// 数字乱跳；取中位数才能稳定反映该组器件的真实温度。
    /// 所有原始传感器读数不做隐藏，悬停即可查看。
    private func robustCentral(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
                                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public func summary() -> TempSummary {
        let s = readViaSMC()
        func peak(_ group: String) -> Double? {
            robustCentral(s.filter { $0.group == group }.map(\.value))
        }
        return TempSummary(cpu: peak("CPU"), gpu: peak("GPU"),
                           battery: peak("电池"), skin: peak("机身"),
                           sensors: s)
    }

    /// 免授权的 SMC 直读：成功返回真实传感器列表
    public func readViaSMC() -> [TempSensor] {
        var out: [TempSensor] = []
        for (key, group) in Self.candidates {
            guard let (bytes, type) = readKey(key), let v = decode(bytes, type: type) else { continue }
            guard v >= 15, v <= 125 else { continue }   // 只接受物理上合理的 SoC 温度，滤掉全零/异常读数
            out.append(TempSensor(key: key, group: group, value: (v * 10).rounded() / 10))
        }
        return out
    }

    // MARK: - 电池温度（免授权，AppleSmartBattery）

    public func batteryTemperature() -> Double? {
        var iter: io_iterator_t = 0
        guard let match = IOServiceMatching("AppleSmartBattery"),
              IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let t = IORegistryEntryCreateCFProperty(svc, "Temperature" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                let c = Double(t) / 100.0
                if c > -20, c < 130 { return (c * 10).rounded() / 10 }
            }
        }
        return nil
    }

    // MARK: - 授权路径：后台常驻 powermetrics

    private var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerfDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sensors.log")
    }

    private var markerURL: URL { logURL.deletingLastPathComponent().appendingPathComponent(".priv") }

    public var privilegedRunning: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// 用一次系统原生授权弹窗，启动后台 root 采样。输出文件由 App 预先创建（归属当前用户），
    /// 因此 App 可以随时截断它，避免日志无限增长。
    @discardableResult
    public func startPrivileged(intervalMs: Int = 2000) -> Bool {
        let log = logURL.path
        // 预创建 log 文件（属主为当前用户），root 以 >> 追加时不会改变属主
        if !FileManager.default.fileExists(atPath: log) {
            FileManager.default.createFile(atPath: log, contents: Data())
        }
        try? Data().write(to: logURL, options: .atomic)   // 清空，且保证文件属主为当前用户
        try? Data("1".utf8).write(to: markerURL)

        let inner = "/usr/bin/powermetrics --samplers smc -i \(intervalMs) -n -1 -f text >> '\(log)' 2>&1 </dev/null &"
        let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func stopPrivileged() {
        try? FileManager.default.removeItem(at: markerURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "powermetrics --samplers smc"]
        try? p.run()
        p.waitUntilExit()
    }

    /// 读取后台采样文件，解析出「名: 值 C」形式的传感器读数
    public func readPrivilegedSensors() -> [TempSensor] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > 3_000_000 {                    // 超过 3MB 主动截断（文件属当前用户）
            try? handle.truncate(atOffset: 0)
            return []
        }
        let readFrom = size > 64_000 ? size - 64_000 : 0
        try? handle.seek(toOffset: readFrom)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }

        var found: [String: (String, Double)] = [:]   // name -> (group, value)
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.contains(":"), let colon = s.firstIndex(of: ":") else { continue }
            let name = String(s[s.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard name.lowercased().contains("temperature"),
                  let numStr = rest.split(separator: " ").first,
                  let v = Double(numStr), v > -20, v < 130 else { continue }
            let group: String
            if name.lowercased().contains("gpu") { group = "GPU" }
            else if name.lowercased().contains("cpu") { group = "CPU" }
            else { group = "其他" }
            let pretty = name.replacingOccurrences(of: " temperature", with: "")
            found[pretty] = (group, (v * 10).rounded() / 10)
        }
        return found.map { TempSensor(key: $0.key, group: $0.value.0, value: $0.value.1) }
                    .sorted { $0.key < $1.key }
    }
}
