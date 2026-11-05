// Metrics.swift — PerfDock 指标采集内核
// 全部走系统原生接口：Mach / IOKit / libproc，无第三方依赖，无子进程轮询。

import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - 数据结构

public struct CPUStats {
    public var usage: Double = 0          // 总负载 0-100
    public var user: Double = 0
    public var system: Double = 0
    public var idle: Double = 100
    public var cores: [Double] = []       // 每核心 0-100
}

public struct MemStats {
    public var total: UInt64 = 0
    public var used: UInt64 = 0           // 活跃 + 联动 + 压缩
    public var active: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var free: UInt64 = 0
    public var reclaimable: UInt64 = 0    // 非活跃 + 可清理，可被回收
    public var swapTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var percent: Double = 0
}

public struct ProcStat {
    public var pid: Int32 = 0
    public var name: String = ""
    public var cpuShare: Double = 0       // 占整机 CPU 容量百分比
    public var cpuSingle: Double = 0      // 按单核 100% 计（同活动监视器）
    public var gpu: Double = 0            // 占 GPU 百分比（已按设备利用率归因）
    public var mem: UInt64 = 0            // 常驻内存
}

public struct BatStats {
    public var available: Bool = false
    public var percent: Int = -1
    public var charging: Bool = false
    public var onAC: Bool = false
    public var cycles: Int = -1
    public var minutesLeft: Int = -1
    public var health: Double = -1        // 最大容量 / 设计容量
}

// 网络吞吐：按采样间隔对「累计收发字节」求差得到速率
public struct NetStats {
    public var down: Double = 0     // 下行字节/秒
    public var up: Double = 0       // 上行字节/秒
}

// 磁盘吞吐：按采样间隔对「累计分页读写计数」求差 × 页大小得到速率（估算）
public struct DiskStats {
    public var read: Double = 0      // 读取字节/秒
    public var write: Double = 0     // 写入字节/秒
}

/// 真实块设备累计读写字节（IOBlockStorageDriver 统计，自本次开机起）。
/// 分页计数（pageins/pageouts）只是内存换页的估算，不能代表真实写盘量，
/// 评估 SSD 写入寿命必须用这里的块设备计数。
public struct DiskIOCounters {
    public var read: UInt64 = 0
    public var write: UInt64 = 0
    public var devices: Int = 0
    public var valid: Bool { devices > 0 }
}

// MARK: - 采集引擎

/// JSONSerialization 不接受 Optional，nil 一律转 NSNull
func gpuJSON(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 } ?? NSNull() }

public final class MetricsEngine {

    private var lastCoreTicks: [UInt32] = []
    private var lastProcCPU: [Int32: UInt64] = [:]   // pid -> 累计 cpu 时间(ns)
    private var lastProcWall: UInt64 = 0

    public private(set) var cpuHistory: [Double] = []
    public private(set) var gpuHistory: [Double] = []
    public private(set) var memHistory: [Double] = []
    private let historyLimit = 48

    private var timebase = mach_timebase_info_data_t()

    // 网络 / 磁盘速率：保存上一次累计值与采样时刻，按间隔求差
    private var lastNetIn: UInt64 = 0
    private var lastNetOut: UInt64 = 0
    private var lastPageIn: UInt64 = 0
    private var lastPageOut: UInt64 = 0
    private var lastDiskR: UInt64 = 0
    private var lastDiskW: UInt64 = 0
    private var lastFlowTime: TimeInterval = 0
    /// 最近一次采样读到的真实块设备累计值（供磁盘历史记录复用，避免重复遍历 IORegistry）
    public private(set) var ioCounters = DiskIOCounters()

    public init() {
        mach_timebase_info(&timebase)
    }

    /// mach tick → 秒（proc_taskinfo 的时间与 mach_absolute_time 同单位）
    private func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    // MARK: CPU

    /// 返回 [user, system, idle, nice] 的累计 tick，按核心展开
    private func coreTicks() -> [UInt32] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let buf = UnsafeRawPointer(info).assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: buf, count: Int(infoCount)))
    }

    public func cpu() -> CPUStats {
        var s = CPUStats()
        let ticks = coreTicks()
        guard ticks.count >= 4 else { return s }
        let cores = ticks.count / 4
        var coresOut: [Double] = []
        var sumUser: Double = 0, sumSys: Double = 0, sumIdle: Double = 0, sumNice: Double = 0

        if lastCoreTicks.count == ticks.count {
            for c in 0..<cores {
                let i = c * 4
                let du = Double(ticks[i] &- lastCoreTicks[i])
                let ds = Double(ticks[i+1] &- lastCoreTicks[i+1])
                let di = Double(ticks[i+2] &- lastCoreTicks[i+2])
                let dn = Double(ticks[i+3] &- lastCoreTicks[i+3])
                let total = du + ds + di + dn
                coresOut.append(total > 0 ? (du + ds + dn) / total * 100 : 0)
                sumUser += du; sumSys += ds; sumIdle += di; sumNice += dn
            }
            let all = sumUser + sumSys + sumIdle + sumNice
            if all > 0 {
                s.user = (sumUser + sumNice) / all * 100
                s.system = sumSys / all * 100
                s.idle = sumIdle / all * 100
                s.usage = 100 - s.idle
            }
        }
        lastCoreTicks = ticks
        s.cores = coresOut
        return s
    }

    // MARK: 内存

    public func memory() -> MemStats {
        var m = MemStats()
        m.total = ProcessInfo.processInfo.physicalMemory
        let pageSize = UInt64(vm_kernel_page_size)

        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            m.active = UInt64(vm.active_count) * pageSize
            m.wired = UInt64(vm.wire_count) * pageSize
            m.compressed = UInt64(vm.compressor_page_count) * pageSize
            m.free = UInt64(vm.free_count) * pageSize
            m.reclaimable = (UInt64(vm.inactive_count) + UInt64(vm.speculative_count)) * pageSize
            // 与「活动监视器」的已用内存口径一致：活跃 + 联动 + 压缩
            m.used = m.active + m.wired + m.compressed
            if m.total > 0 { m.percent = Double(m.used) / Double(m.total) * 100 }
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapTotal = swap.xsu_total
            m.swapUsed = swap.xsu_used
        }
        return m
    }

    // MARK: GPU

    public func gpu() -> Double? {
        var iter: io_iterator_t = 0
        guard let match = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var best: Double?
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let prop = IORegistryEntryCreateCFProperty(
                    svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            if let v = prop["Device Utilization %"] as? Int {
                let d = Double(v)
                if best == nil || d > (best ?? -1) { best = d }
            }
        }
        return best
    }

    public func gpuName() -> String? {
        var iter: io_iterator_t = 0
        guard let match = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let m = IORegistryEntryCreateCFProperty(svc, "model" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                return m
            }
        }
        return nil
    }

    // MARK: 进程

    private static let PROC_ALL_PIDS: UInt32 = 1
    private static let PROC_PIDTASKINFO: Int32 = 4
    private static let TASKINFO_SIZE = 96

    private func procName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    /// 分进程 GPU 占用（原始口径：该进程每秒占用的 GPU 时间秒数）。
    /// 数据来自 IOKit `AGXDeviceUserClient` 的 `AppUsage[].accumulatedGPUTime`，
    /// 单位为纳秒（已实测标定：WindowServer 2 秒 ≈ 0.31 秒 GPU 时间）。免授权可读。
    /// 注意多个命令队列可重叠执行，原始比例之和可能高于设备利用率，展示前需归因（见 sample）。
    private var lastGPUTime: [Int32: UInt64] = [:]
    private var lastGPUWall: UInt64 = 0

    private func gpuClientUsage() -> (byPid: [Int32: Double], names: [Int32: String]) {
        let now = mach_absolute_time()
        let wallSec = lastGPUWall == 0 ? 0 : seconds(now &- lastGPUWall)
        var cur: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]

        var iter: io_iterator_t = 0
        if let match = IOServiceMatching("IOAccelerator"),
           IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            while case let acc = IOIteratorNext(iter), acc != 0 {
                defer { IOObjectRelease(acc) }
                var childIter: io_iterator_t = 0
                guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &childIter) == KERN_SUCCESS
                else { continue }
                defer { IOObjectRelease(childIter) }
                while case let c = IOIteratorNext(childIter), c != 0 {
                    defer { IOObjectRelease(c) }
                    var ref: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(c, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                          let d = ref?.takeRetainedValue() as? [String: Any],
                          let creator = d["IOUserClientCreator"] as? String else { continue }
                    // 形如 "pid 434, WindowServer"
                    let parts = creator.split(separator: ",")
                    guard let head = parts.first else { continue }
                    let pidStr = head.replacingOccurrences(of: "pid ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    guard let pid = Int32(pidStr) else { continue }
                    var total: UInt64 = 0
                    if let usage = d["AppUsage"] as? [[String: Any]] {
                        for u in usage {
                            if let t = u["accumulatedGPUTime"] as? UInt64 { total = total &+ t }
                            else if let n = u["accumulatedGPUTime"] as? NSNumber { total = total &+ n.uint64Value }
                        }
                    }
                    if names[pid] == nil {
                        names[pid] = parts.count > 1
                            ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    }
                    cur[pid] = (cur[pid] ?? 0) &+ total
                }
            }
        }

        var out: [Int32: Double] = [:]
        if wallSec > 0 {
            for (pid, t) in cur {
                guard let prev = lastGPUTime[pid], t > prev else { continue }
                let pct = Double(t - prev) / 1e9 / wallSec * 100
                if pct > 0.02 { out[pid] = pct }
            }
        }
        lastGPUTime = cur
        lastGPUWall = now
        return (out, names)
    }

    private func taskInfo(_ pid: Int32, _ out: inout [UInt8]) -> Bool {
        var raw = [UInt8](repeating: 0, count: Self.TASKINFO_SIZE)
        let n = raw.withUnsafeMutableBytes { buf -> Int32 in
            proc_pidinfo(pid, Self.PROC_PIDTASKINFO, 0, buf.baseAddress, Int32(Self.TASKINFO_SIZE))
        }
        guard n == Int32(Self.TASKINFO_SIZE) else { return false }
        out = raw
        return true
    }

    public func processes(collectGPU: Bool = false) -> [ProcStat] {
        let bytesNeeded = proc_listpids(Self.PROC_ALL_PIDS, 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<Int32>.stride + 64)
        let written = pids.withUnsafeMutableBytes { buf -> Int32 in
            proc_listpids(Self.PROC_ALL_PIDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard written > 0 else { return [] }
        let pidCount = Int(written) / MemoryLayout<Int32>.stride

        let ncpu = Double(ProcessInfo.processInfo.processorCount)
        // 注意：proc_taskinfo 的 pti_total_user / pti_total_system 单位是 mach 绝对时间
        // （Apple Silicon 上是 24MHz），不是纳秒。时间窗口也用 mach_absolute_time()，两边同单位。
        let now = mach_absolute_time()
        let wallSec = lastProcWall == 0 ? 0 : seconds(now &- lastProcWall)

        var byName: [String: ProcStat] = [:]
        var newTimes: [Int32: UInt64] = [:]

        for i in 0..<pidCount {
            let pid = pids[i]
            if pid <= 0 { continue }
            var raw: [UInt8] = []
            guard taskInfo(pid, &raw) else { continue }
            let resident = raw.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
            let userT = raw.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
            let sysT = raw.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
            let cpuTime = userT + sysT
            newTimes[pid] = cpuTime

            let name = procName(pid) ?? "pid \(pid)"

            var share = 0.0, single = 0.0
            if wallSec > 0, let prev = lastProcCPU[pid], cpuTime > prev {
                let deltaSec = seconds(cpuTime - prev)
                single = deltaSec / wallSec * 100            // 单核 100% 口径
                share = single / ncpu                        // 占整机容量
            }
            // 同名进程（如多个 Helper）合并，才是「程序占用比例」
            if var existing = byName[name] {
                existing.cpuShare += share
                existing.cpuSingle += single
                existing.mem += resident
                if existing.pid == 0 { existing.pid = pid }
                byName[name] = existing
            } else {
                byName[name] = ProcStat(pid: pid, name: name,
                                        cpuShare: share, cpuSingle: single, mem: resident)
            }
        }
        lastProcCPU = newTimes
        lastProcWall = now

        // 分进程 GPU（仅在需要时采集，省掉一次 IORegistry 遍历）
        if collectGPU {
            let gpuData = gpuClientUsage()
            for (pid, gpct) in gpuData.byPid {
                let nm = procName(pid) ?? gpuData.names[pid] ?? "pid \(pid)"
                if var e = byName[nm] {
                    e.gpu += gpct
                    byName[nm] = e
                } else {
                    byName[nm] = ProcStat(pid: pid, name: nm, gpu: gpct)
                }
            }
        }
        return Array(byName.values)
    }

    // MARK: 电池

    public func battery() -> BatStats {
        var b = BatStats()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      let type = d["Type"] as? String, type == "InternalBattery" else { continue }
                b.available = true
                if let cur = d["Current Capacity"] as? Int { b.percent = cur }
                if let ch = d["Is Charging"] as? Bool { b.charging = ch }
                if let st = d["Power Source State"] as? String { b.onAC = (st == "AC Power") }
                if let left = d["Time to Empty"] as? Int, left > 0 { b.minutesLeft = left }
                break
            }
        }
        // 循环次数 / 健康度走 AppleSmartBattery
        var iter: io_iterator_t = 0
        if let match = IOServiceMatching("AppleSmartBattery"),
           IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            while case let svc = IOIteratorNext(iter), svc != 0 {
                defer { IOObjectRelease(svc) }
                func prop(_ k: String) -> Int? {
                    IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Int
                }
                if let c = prop("CycleCount") { b.cycles = c }
                // M 系列上容量信息在嵌套的 BatteryData 里，顶层没有 AppleRawMaxCapacity
                if let data = IORegistryEntryCreateCFProperty(svc, "BatteryData" as CFString,
                                                              kCFAllocatorDefault, 0)?
                                .takeRetainedValue() as? [String: Any] {
                    let full = (data["FullChargeCapacity"] as? Int) ?? -1
                    let design = (data["DesignCapacity"] as? Int) ?? -1
                    if full > 0, design > 0 { b.health = Double(full) / Double(design) * 100 }
                    if b.minutesLeft < 0, let m = data["AvgTimeToEmpty"] as? Int, m > 0 { b.minutesLeft = m }
                }
                break
            }
        }
        return b
    }

    // MARK: 网络吞吐

    /// 累计收发字节（排除回环口与未启用口）。免授权，直接读内核 ifnet 计数。
    public func networkTotals() -> (inBytes: UInt64, outBytes: UInt64) {
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let start = ifa else { return (0, 0) }
        defer { freeifaddrs(start) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            let i = cur.pointee
            let flags = i.ifa_flags
            if (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0,
               i.ifa_data != nil {
                let d = i.ifa_data!.assumingMemoryBound(to: if_data.self)
                inB += UInt64(d.pointee.ifi_ibytes)
                outB += UInt64(d.pointee.ifi_obytes)
            }
            p = i.ifa_next
        }
        return (inB, outB)
    }

    // MARK: 磁盘吞吐

    /// 真实块设备累计读写字节：遍历 IOBlockStorageDriver，累加 Statistics 里的
    /// `Bytes (Read)` / `Bytes (Write)`（旧系统键名为 `Bytes (Written)`）。
    /// 计数自本次开机起累计；无需特权。
    public func diskIOCounters() -> DiskIOCounters {
        var out = DiskIOCounters()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any],
                  let st = d["Statistics"] as? [String: Any] else { continue }
            let r = (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = ((st["Bytes (Write)"] as? NSNumber) ?? (st["Bytes (Written)"] as? NSNumber))?.uint64Value ?? 0
            out.read &+= r
            out.write &+= w
            out.devices += 1
        }
        return out
    }

    /// 累计分页读写次数（pageins = 读，pageouts = 写，含交换）。免授权，读 vm_statistics64。
    /// 仅作为块设备统计不可用时的回退。
    public func diskCounters() -> (pagesIn: UInt64, pagesOut: UInt64) {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        // pageins / pageouts 为有符号累计量，转 UInt64 后做无符号回绕减法
        return (UInt64(bitPattern: Int64(vm.pageins)), UInt64(bitPattern: Int64(vm.pageouts)))
    }

    public func flowRates() -> (net: NetStats, disk: DiskStats) {
        let now = Date().timeIntervalSince1970
        let dt = lastFlowTime > 0 ? now - lastFlowTime : 0
        lastFlowTime = now
        let page = UInt64(vm_kernel_page_size)

        let n = networkTotals()
        let io = diskIOCounters()
        ioCounters = io

        var net = NetStats(), disk = DiskStats()
        if dt > 0.05 {
            if lastNetIn > 0, n.inBytes >= lastNetIn {
                net.down = Double(n.inBytes &- lastNetIn) / dt
            }
            if lastNetOut > 0, n.outBytes >= lastNetOut {
                net.up = Double(n.outBytes &- lastNetOut) / dt
            }
            if io.valid {
                // 首选真实块设备字节速率（与磁盘历史同源，数字一致）
                if lastDiskR > 0, io.read >= lastDiskR {
                    disk.read = Double(io.read &- lastDiskR) / dt
                }
                if lastDiskW > 0, io.write >= lastDiskW {
                    disk.write = Double(io.write &- lastDiskW) / dt
                }
            } else {
                // 回退：块设备统计不可用时，用分页计数估算
                let dc = diskCounters()
                if lastPageIn > 0, dc.pagesIn >= lastPageIn {
                    disk.read = Double(dc.pagesIn &- lastPageIn) * Double(page) / dt
                }
                if lastPageOut > 0, dc.pagesOut >= lastPageOut {
                    disk.write = Double(dc.pagesOut &- lastPageOut) * Double(page) / dt
                }
                lastPageIn = dc.pagesIn; lastPageOut = dc.pagesOut
            }
        }
        lastNetIn = n.inBytes; lastNetOut = n.outBytes
        lastDiskR = io.read; lastDiskW = io.write
        return (net, disk)
    }

    // MARK: 热压力 / 负载 / 开机时长

    public func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "normal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    // MARK: 汇总采样

    public func sample(topN: Int = 3, metric: String = "cpu") -> [String: Any] {
        let c = cpu()
        let m = memory()
        let g = gpu()
        let p = processes(collectGPU: metric == "gpu")

        cpuHistory.append(c.usage); if cpuHistory.count > historyLimit { cpuHistory.removeFirst() }
        memHistory.append(m.percent); if memHistory.count > historyLimit { memHistory.removeFirst() }
        if let g { gpuHistory.append(g); if gpuHistory.count > historyLimit { gpuHistory.removeFirst() } }

        // GPU 归因：各进程的原始 GPU 时间比例因多队列重叠可能高于设备利用率，
        // 按比例把设备利用率分配到进程，让列表合计与上方 GPU 条一致。
        let gpuSum = p.reduce(0.0) { $0 + $1.gpu }
        let gpuScale = (g != nil && gpuSum > 0) ? max(0, min(1, g! / gpuSum)) : 1.0

        let sorted = p.sorted { a, b in
            switch metric {
            case "mem": return a.mem > b.mem
            case "gpu": return a.gpu > b.gpu
            default:    return a.cpuShare > b.cpuShare
            }
        }
        let top = sorted.prefix(topN).map { proc -> [String: Any] in
            ["pid": Int(proc.pid), "name": proc.name,
             "cpuShare": (proc.cpuShare * 10).rounded() / 10,
             "cpuSingle": (proc.cpuSingle * 10).rounded() / 10,
             "gpu": (proc.gpu * gpuScale * 10).rounded() / 10,
             "mem": proc.mem]
        }
        let b = battery()
        let la = loadAverage()
        let (net, disk) = flowRates()

        var out: [String: Any] = [:]
        out["ts"] = Date().timeIntervalSince1970
        out["cpu"] = ["usage": (c.usage * 10).rounded() / 10,
                      "user": (c.user * 10).rounded() / 10,
                      "system": (c.system * 10).rounded() / 10,
                      "cores": c.cores.map { ($0 * 10).rounded() / 10 },
                      "history": cpuHistory.map { ($0 * 10).rounded() / 10 }]
        out["gpu"] = ["util": gpuJSON(g),
                      "name": gpuName().map { $0 as Any } ?? NSNull(),
                      "history": gpuHistory.map { ($0 * 10).rounded() / 10 }]
        out["mem"] = ["total": m.total, "used": m.used, "active": m.active, "wired": m.wired,
                      "compressed": m.compressed, "free": m.free, "reclaimable": m.reclaimable,
                      "swapTotal": m.swapTotal, "swapUsed": m.swapUsed,
                      "percent": (m.percent * 10).rounded() / 10,
                      "history": memHistory.map { ($0 * 10).rounded() / 10 }]
        out["battery"] = ["available": b.available, "percent": b.percent,
                          "charging": b.charging, "onAC": b.onAC,
                          "cycles": b.cycles, "minutesLeft": b.minutesLeft,
                          "health": (b.health * 10).rounded() / 10]
        out["procs"] = top
        out["procMetric"] = metric
        out["procCount"] = p.count
        // 系统内核进程（kernel_task 等）对普通进程不可见。把差额作为「系统内核（推算）」展示，
        // 避免出现「总负载 76% 但 Top3 都是 0.1%」这种看起来像坏掉的状态。
        let visibleShare = p.reduce(0.0) { $0 + $1.cpuShare }
        out["visibleCpuShare"] = (visibleShare * 10).rounded() / 10
        out["thermal"] = thermalState()
        out["load"] = [(la.0 * 100).rounded() / 100, (la.1 * 100).rounded() / 100, (la.2 * 100).rounded() / 100]
        out["uptime"] = ProcessInfo.processInfo.systemUptime
        out["cores"] = ProcessInfo.processInfo.processorCount
        out["net"] = ["down": (net.down * 10).rounded() / 10, "up": (net.up * 10).rounded() / 10]
        out["disk"] = ["read": (disk.read * 10).rounded() / 10, "write": (disk.write * 10).rounded() / 10]
        return out
    }
}
