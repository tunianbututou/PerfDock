// DiskHistory.swift — 磁盘累计读写记录
//
// 数据基础：IOBlockStorageDriver 的累计字节（自本次开机），PerfDock 每次采样取增量，
// 按「小时」分桶累加并持久化到 Application Support。日视图由小时桶聚合得到。
//
// 为什么要自己记账：macOS 不向非特权进程暴露 NVMe SMART 的「累计写入量」，
// 只能从本机首次运行起持续累加，用于评估写入强度与 SSD 寿命（对照标称 TBW）。
import Foundation

final class DiskHistory {

    struct IO {
        var read: UInt64
        var write: UInt64
    }

    private let storeURL: URL
    private let lock = NSLock()

    /// 小时起点 epoch 秒 → [累计读, 累计写]
    private var hours: [Int: [UInt64]] = [:]
    private var totalRead: UInt64 = 0
    private var totalWrite: UInt64 = 0
    /// 上一次采样到的绝对计数（用于求增量）；重启后计数回绕则按「开机以来全部」计入
    private var lastRead: UInt64?
    private var lastWrite: UInt64?
    private var since: Int
    private var dirty = false
    private var lastFlush = Date.distantPast
    /// 串行写盘队列：保证多次落盘按顺序生效，最后一次一定是最新数据
    private let writeQueue = DispatchQueue(label: "perfdock.diskhistory.write")

    /// 保留 120 天（2880 个小时桶，JSON 约 80–100KB）
    private let keepSeconds: TimeInterval = 120 * 24 * 3600

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PerfDock", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("disk-history.json")
        since = Int(Date().timeIntervalSince1970)
        load()
    }

    /// 自检用：可指定存储目录
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("disk-history.json")
        since = Int(Date().timeIntervalSince1970)
        load()
    }

    // MARK: 记录

    /// 采样入口（由 tick 调用）。计数器回绕（重启）时按当前值计入，
    /// 因为那段增量必然发生在两次采样之间。
    func record(_ io: DiskIOCounters) {
        guard io.valid else { return }
        record(read: io.read, write: io.write, at: Date())
    }

    func record(read: UInt64, write: UInt64, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let lr = lastRead, let lw = lastWrite else {
            lastRead = read; lastWrite = write      // 首次采样只建立基线
            return
        }
        let dr = read >= lr ? read - lr : read
        let dw = write >= lw ? write - lw : write
        lastRead = read; lastWrite = write
        guard dr > 0 || dw > 0 else { return }
        add(read: dr, write: dw, at: date)
    }

    /// 直接累加到指定时刻所在的小时桶（自检用）
    func add(read: UInt64, write: UInt64, at date: Date) {
        let key = hourKey(date)
        var b = hours[key] ?? [0, 0]
        b[0] &+= read
        b[1] &+= write
        hours[key] = b
        totalRead &+= read
        totalWrite &+= write
        dirty = true
        pruneIfNeeded(now: date)
        flushIfNeeded()
    }

    func flush() { flushIfNeeded(force: true) }

    // MARK: 聚合快照（前端图表用）

    /// 今日累计（轻量版，供主面板每帧采样推送）
    func todayTotals(now: Date = Date()) -> (read: UInt64, write: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let day = Calendar.current.dateInterval(of: .day, for: now) else { return (0, 0) }
        var r: UInt64 = 0, w: UInt64 = 0
        for (k, b) in hours where day.contains(Date(timeIntervalSince1970: TimeInterval(k))) {
            r &+= b[0]; w &+= b[1]
        }
        return (r, w)
    }

    func snapshot(now: Date = Date()) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let cal = Calendar.current

        // 近 24 小时（含当前小时），对齐整点
        let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let hourStarts: [Date] = (0..<24).reversed().compactMap {
            cal.date(byAdding: .hour, value: -$0, to: currentHour)
        }
        var hourLabels: [String] = [], hr: [UInt64] = [], hw: [UInt64] = []
        for d in hourStarts {
            let b = hours[hourKey(d)] ?? [0, 0]
            hourLabels.append(String(format: "%02d时", cal.component(.hour, from: d)))
            hr.append(b[0]); hw.append(b[1])
        }

        // 近 30 天（含今天）
        let today = cal.startOfDay(for: now)
        var dayLabels: [String] = [], dr: [UInt64] = [], dw: [UInt64] = []
        var todayR: UInt64 = 0, todayW: UInt64 = 0
        var last7W: UInt64 = 0
        for i in (0..<30).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            var r: UInt64 = 0, w: UInt64 = 0
            for (k, b) in hours where cal.isDate(Date(timeIntervalSince1970: TimeInterval(k)),
                                                  inSameDayAs: d) {
                r &+= b[0]; w &+= b[1]
            }
            let c = cal.dateComponents([.month, .day], from: d)
            dayLabels.append(String(format: "%d-%02d", c.month ?? 0, c.day ?? 0))
            dr.append(r); dw.append(w)
            if i == 0 { todayR = r; todayW = w }
            if i < 7 { last7W &+= w }
        }

        let avg7W = last7W / 7
        // 原始小时序列（前端缩放用）：[小时起点秒, 读, 写]，按时间升序；最多 120 天
        let series: [[Int]] = hours.keys.sorted().map { k in
            [k, clamp(hours[k]?[0] ?? 0), clamp(hours[k]?[1] ?? 0)]
        }
        return [
            "since": since,
            "valid": (totalRead + totalWrite) > 0,
            "total": ["r": clamp(totalRead), "w": clamp(totalWrite)],
            "today": ["r": clamp(todayR), "w": clamp(todayW)],
            "avg7Write": clamp(avg7W),
            "yearWrite": clamp(avg7W * 365),
            "days": ["labels": dayLabels, "r": dr.map(clamp), "w": dw.map(clamp)],
            "hours": ["labels": hourLabels, "r": hr.map(clamp), "w": hw.map(clamp)],
            "series": series,
            "trackedHours": hours.count,
        ]
    }

    // MARK: 工具

    private func clamp(_ v: UInt64) -> Int {
        v > UInt64(Int.max) ? Int.max : Int(v)
    }

    private func hourKey(_ d: Date) -> Int {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour], from: d)
        return Int((cal.date(from: c) ?? d).timeIntervalSince1970)
    }

    private func pruneIfNeeded(now: Date) {
        let cutoff = now.timeIntervalSince1970 - keepSeconds
        guard hours.count > 24 else { return }
        for k in hours.keys where Double(k) < cutoff { hours.removeValue(forKey: k) }
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        since = (obj["since"] as? NSNumber)?.intValue ?? since
        if let t = obj["total"] as? [NSNumber], t.count == 2 {
            totalRead = t[0].uint64Value; totalWrite = t[1].uint64Value
        }
        if let l = obj["last"] as? [NSNumber], l.count == 2 {
            lastRead = l[0].uint64Value; lastWrite = l[1].uint64Value
        }
        if let h = obj["hours"] as? [String: [NSNumber]] {
            for (k, v) in h where v.count == 2 {
                if let key = Int(k) { hours[key] = [v[0].uint64Value, v[1].uint64Value] }
            }
        }
    }

    private func flushIfNeeded(force: Bool = false) {
        guard dirty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) >= 60 else { return }
        lastFlush = now
        dirty = false
        let hoursJSON = Dictionary(uniqueKeysWithValues:
            hours.map { (String($0.key), [$0.value[0], $0.value[1]]) })
        let obj: [String: Any] = [
            "v": 1,
            "since": since,
            "total": [totalRead, totalWrite],
            "last": [lastRead ?? 0, lastWrite ?? 0],
            "hours": hoursJSON,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = storeURL
        writeQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
