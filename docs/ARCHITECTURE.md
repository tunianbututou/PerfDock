# PerfDock 架构说明

PerfDock 由一个原生 macOS 进程组成。Swift 采集系统指标、管理菜单栏和窗口；AppKit 承载浮动面板；WKWebView 加载单文件 UI；Swift 与 JavaScript 通过 WebKit 脚本消息交换 JSON 数据和命令。

## 数据路径

<pre><code>Mach / IOKit / libproc / AppleSMC
             │
             ▼
     MetricsEngine / TempReader
             │  周期采样，构建字典
             ├───────────────► 菜单栏即时读数
             ▼
       PanelController ─────► WKWebView ─────► UI/index.html
             ▲                      │
             └── WebKit 消息桥 ─────┘

IOBlockStorageDriver ─► 独立 1 秒计时器 ─► DiskHistory ─► JSON 小时桶</code></pre>

## 模块职责

### Sources/Metrics.swift

MetricsEngine 封装 Mach CPU/内存采集、IOKit GPU/块设备计数、libproc 进程读取、网络接口统计和电池状态。sample(topN:metric:) 返回供界面使用的指标字典，并维护有界长度的短时趋势数据。

CPU 利用率由两次 tick 计数器读数之间的差值计算。网络速率与磁盘实时速率来自累计字节计数器的相邻差值，而非定期运行 top、vm_stat 等外部命令。

### Sources/SMCTemp.swift

TempReader 通过 AppleSMC 用户客户端读取温度传感器；解码时根据数据类型处理格式和字节序。key 名称不能可靠地映射到所有设备上的具体物理位置，因此界面按读数/传感器组展示，不把未经确认的传感器标作机身表面温度。

### Sources/app/main.swift

AppDelegate 配置 accessory 应用、菜单栏状态项、启动/退出行为、全局快捷键、前端指令处理和 WorkBuddy 生命周期观察。主指标按用户采样间隔刷新；温度读取受到节流。磁盘记账使用独立定时器，不随主面板采样间隔改变。

### Sources/app/Panel.swift

PanelController 负责透明浮动窗口、AppKit 毛玻璃层、缩放、移动、边缘吸附、完整窗与迷你条切换、系统外观和 WKWebView 脚本桥。背景不透明度调节原生材质层；窗口整体 alpha 不用于伪造文字透明度。

### Sources/app/Prefs.swift 和 UI/index.html

Prefs 是本地偏好的持久化层。初始化时 Swift 将偏好序列化为 JSON，供 HTML 页面渲染。用户交互通过 WebKit dock 消息回到原生层；index.html 包含样式、面板、设置、趋势、磁盘历史视图和演示数据模式。

### Sources/app/DiskHistory.swift

记账器把 IOBlockStorageDriver 的累计读写计数器转成相邻采样间的字节增量，按小时保存，并从小时桶聚合得到日视图。文件保存在用户 Application Support 目录；历史小时桶最多保留 120 天。累计总量和小时图历史含义不同：总量不会因小时桶过期而重置。关机、应用关闭或未采样的时段不补记。

## 本地持久化

| 内容 | 本机位置 |
|---|---|
| 设置、主题、模块开关、窗口大小与位置 | UserDefaults，Bundle ID com.perfdock.app |
| 磁盘小时桶和累计读写 | ~/Library/Application Support/PerfDock/disk-history.json |
| 登录启动代理 | ~/Library/LaunchAgents/com.perfdock.agent.plist |

这些文件不会被项目提交或构建脚本打包。偏好键使用 pd. 前缀；更换 App 包并保留 Bundle ID 与 Application Support 路径即可沿用现有数据。

## 构建链

build.sh 从六个 Swift 源文件编译单个可执行文件，链接 Apple 系统框架，再把 UI/index.html 放入 App Bundle 并进行本地 ad-hoc 签名。构建目标使用本机架构；项目没有第三方运行时依赖。

## 已知接口边界

- IOKit 的 GPU 与块设备统计会因机型和系统版本而异。
- 系统限制普通进程查看某些受保护或内核进程；可见进程排行不能解释所有总负载。
- 分进程 GPU 使用率依赖可见的 GPU 客户端累计数据，属于资源归因估算。
- SMC 传感器命名和物理位置并未在所有机型上公开保证。
- 磁盘历史是应用运行期间的相对记账，不是 SMART 寿命写入统计。
