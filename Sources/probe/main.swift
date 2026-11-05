// probe/main.swift — 命令行探针：验证每个指标在本机是否真的读得到
import Foundation

let engine = MetricsEngine()
let temp = TempReader()

func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824.0) }
func f(_ d: Double?, _ unit: String = "") -> String { d.map { String(format: "%.1f%@", $0, unit) } ?? "—" }

_ = engine.cpu(); _ = engine.processes()
Thread.sleep(forTimeInterval: 1.5)

print("=== CPU / GPU ===")
let c = engine.cpu()
print("总负载 \(f(c.usage, "%"))  用户 \(f(c.user, "%"))  系统 \(f(c.system, "%"))  核心 \(c.cores.count)")
print("每核: " + c.cores.map { String(format: "%.0f", $0) }.joined(separator: " "))
print("GPU \(engine.gpuName() ?? "?")  利用率 \(f(engine.gpu(), "%"))")

print("\n=== 内存 ===")
let m = engine.memory()
print("总量 \(gb(m.total))  已用 \(gb(m.used)) (\(f(m.percent, "%")))  压缩 \(gb(m.compressed))  可回收 \(gb(m.reclaimable))")
print("交换 \(gb(m.swapUsed)) / \(gb(m.swapTotal))")

print("\n=== 进程 Top5（0.8 秒窗口）===")
_ = engine.processes()
Thread.sleep(forTimeInterval: 0.8)
let procs = engine.processes()
let visible = procs.reduce(0.0) { $0 + $1.cpuShare }
for p in procs.sorted(by: { $0.cpuShare > $1.cpuShare }).prefix(5) {
    print(String(format: "  %-26@ 占总容量 %5.2f%%  单核 %6.2f%%  常驻 %@",
                 p.name as NSString, p.cpuShare, p.cpuSingle, gb(p.mem)))
}
print(String(format: "  可见进程合计 %.2f%%  接口总负载 %.1f%%  内核推算 %.1f%%",
             visible, c.usage, max(0, c.usage - visible)))

print("\n=== 进程 GPU Top5（1.5 秒窗口，免授权）===")
_ = engine.processes(collectGPU: true)
Thread.sleep(forTimeInterval: 1.5)
let gp = engine.processes(collectGPU: true)
for p in gp.sorted(by: { $0.gpu > $1.gpu }).prefix(5) {
    print(String(format: "  %-28@ GPU %6.2f%%  常驻 %@",
                 p.name as NSString, p.gpu, gb(p.mem)))
}
let dev = engine.gpu() ?? 0
let gsum = gp.reduce(0.0) { $0 + $1.gpu }
print(String(format: "  设备利用率 %.1f%%  原始比例合计 %.1f%%  归因系数 %.2f",
             dev, gsum, gsum > 0 ? dev / gsum : 1))

print("\n=== 温度（免授权 SMC 直读）===")
let s = temp.summary()
print("CPU \(f(s.cpu, " °C"))   GPU \(f(s.gpu, " °C"))   电池 \(f(s.battery, " °C"))   机身 \(f(s.skin, " °C"))")
print("传感器明细（\(s.sensors.count) 个）:")
for x in s.sensors { print("  [\(x.group)] \(x.key) = \(x.value) °C") }
Thread.sleep(forTimeInterval: 2.0)
let s2 = temp.summary()
print("2 秒后复测 → CPU \(f(s2.cpu, " °C"))  （数值有变化说明是实时读数，不是常量）")

print("\n=== 电池 ===")
let b = engine.battery()
print("电量 \(b.percent)%  充电 \(b.charging)  接电源 \(b.onAC)  循环 \(b.cycles) 次  健康 \(f(b.health, "%"))  剩余 \(b.minutesLeft) 分钟")

print("\n=== 其他 ===")
let la = engine.loadAverage()
print(String(format: "load %.2f %.2f %.2f  热压力 %@  已运行 %.1f 小时",
             la.0, la.1, la.2, engine.thermalState(), ProcessInfo.processInfo.systemUptime / 3600))

#if false
#endif
