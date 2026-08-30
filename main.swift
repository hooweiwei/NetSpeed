import AppKit
import Darwin

// MARK: - 网速采样：sysctl(NET_RT_IFLIST2) 读取物理网卡的 64 位累计收发字节数
//
// 路由消息按 msglen 紧凑排列（非 8 字节对齐），Swift 里不能直接 load 结构体（未对齐 UB），
// 必须按字节拷贝读取。偏移经 C 程序 offsetof 实测，并与 netstat -ib 数值比对一致：
//   if_msghdr2 共 160B：msglen=u16@+0, type=u8@+3, ibytes=u64@+96, obytes=u64@+104
//   sockaddr_dl 紧跟在 +160：nlen=u8@+165, 接口名字符在 +168 起 nlen 个字节

func currentBytes() -> (rx: Int64, tx: Int64) {
    var rx: Int64 = 0
    var tx: Int64 = 0

    @inline(__always)
    func readLE<T: FixedWidthInteger>(_ base: UnsafeMutableRawPointer, _ offset: Int, _ type: T.Type) -> T {
        var result = T.zero
        withUnsafeMutableBytes(of: &result) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(
                start: base.advanced(by: offset), count: MemoryLayout<T>.size))
        }
        return result
    }

    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }

    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: length, alignment: MemoryLayout<Int64>.alignment)
    defer { buffer.deallocate() }
    guard sysctl(&mib, 6, buffer, &length, nil, 0) == 0 else { return (0, 0) }

    var offset = 0
    while offset + 4 <= length {
        let msglen = Int(readLE(buffer, offset, UInt16.self))
        let type = readLE(buffer, offset + 3, UInt8.self)
        guard msglen > 0, offset + msglen <= length else { break }

        if type == RTM_IFINFO2 {
            let nlen = Int(readLE(buffer, offset + 165, UInt8.self))
            let name = nlen > 0 && nlen < 32
                ? String(decoding: Data(bytes: buffer.advanced(by: offset + 168), count: nlen), as: UTF8.self)
                : ""
            // 只统计物理网卡 en*：排除 lo0/utun/awdl 等，避免 VPN(ClashX TUN) 双重计数
            if name.hasPrefix("en"), name.dropFirst(2).allSatisfy(\.isNumber) {
                rx += Int64(bitPattern: readLE(buffer, offset + 96, UInt64.self))
                tx += Int64(bitPattern: readLE(buffer, offset + 104, UInt64.self))
            }
        }
        offset += msglen
    }
    return (rx, tx)
}

// MARK: - 速度格式化：KB/s 与 ≥10MB/s 整数；1MB~9.9MB 保留 1 位小数
// 0~999 KB/s 显示整数 KB/s；1000KB/s~9.9MB/s 显示 1 位小数 MB/s；≥10MB/s 整数 MB/s；≥1000MB/s 再换整数 GB/s
// 例：0KB/s  5KB/s  999KB/s  1.0MB/s  9.9MB/s  10MB/s  200MB/s  1GB/s

func formatSpeed(_ bytesPerSec: Double) -> String {
    let kb = max(0, bytesPerSec) / 1024.0
    if kb < 1000 {
        return "\(Int(kb.rounded()))KB/s"
    }
    let mb = kb / 1024.0
    // 1MB~9.9MB 保留 1 位小数（粒度有意义）；≥10MB 用整数即可；不足 1MB(≈1000-1023KB)也走小数，四舍五入显示。
    if mb < 9.95 {
        return String(format: "%.1fMB/s", mb)
    }
    // 整数上限 999，以 999.5 为界避免四舍五入出 "1000MB/s" 撑破状态栏预留宽度
    if mb < 999.5 {
        return "\(Int(mb.rounded()))MB/s"
    }
    let gb = mb / 1024.0
    return "\(Int(gb.rounded()))GB/s"
}

// MARK: - 等宽对齐工具：菜单是比例字体环境，按「真实渲染宽度」补空格对齐
// 不按字符数估算（CJK 宽度随回退字体浮动），空格数由 NSAttributedString 实测像素宽换算

// 菜单字体：菜单里数字/表格排布用等宽 JetBrains Mono，右对齐像素级精确。
// 进程区文字 11pt；底部功能项用系统 13pt（"打开活动监视器"字号）。
let menuFont = NSFont(name: "JetBrains Mono", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
let menuFooterFont = NSFont.menuFont(ofSize: 13)         // 底部功能项：系统标准字体 13pt
// 底部功能项前导空格数：把"打开活动监视器/退出 NetSpeed"首字推到与进程名首列(padW)对齐。
// 实测：系统项原生左内边距 K 使"退"落在进程列左缘左侧约 8 物理px(4 逻辑pt)，1 个 13pt 空格≈7.3 物理px即补上。
let footerLeadingSpaces = 1

private func measuredWidth(_ s: String) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: menuFont]).size().width
}

private func padTo(_ s: String, targetWidth: CGFloat, alignRight: Bool) -> String {
    let spaceW = measuredWidth(" ")
    let padCount = max(0, Int(round((targetWidth - measuredWidth(s)) / spaceW)))
    let pad = String(repeating: " ", count: padCount)
    return alignRight ? pad + s : s + pad
}

// MARK: - 状态栏渲染：把两行文字画成 NSImage 交给状态栏按钮
//
// 按钮对「图片内容」使用系统原生的毛玻璃高亮与标准左右留白（和 WiFi/电池一致）。
// 字体真实行高（8.5pt ≈ 11pt），系统自动垂直居中；箭头在文字右侧，两行右对齐。

enum StatusRenderer {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    static let horizontalPad: CGFloat = 0.0             // 两侧留白=0；剩余空隙来自"为三位数预留的固定宽"(防跳动)
    static let lineHeight: CGFloat = 11                 // 固定行高
    static let textGap: CGFloat = 3                     // 文字与箭头之间固定间隔

    // 预留最宽字符串：MB/s 整数上限 999 → 最宽为 999MB/s（GB/s 位数相同）。
    private static let maxTextWidth: CGFloat = ceil(("999MB/s" as NSString).size(withAttributes: [.font: font]).width)
    private static let arrowWidth: CGFloat = ceil(max(
        ("↑" as NSString).size(withAttributes: [.font: font]).width,
        ("↓" as NSString).size(withAttributes: [.font: font]).width))

    // 固定内容宽度 = 最宽文字 + 间隔 + 箭头；图片宽度恒定 → 左侧图标不跳动。
    // 文字块右对齐（右缘固定在间隔左侧），三位数时向左扩展，箭头始终贴右缘不动
    static let fixedContentWidth: CGFloat = maxTextWidth + textGap + arrowWidth

    private static func attributedText(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    static func image(up: String, down: String) -> NSImage {
        let width = fixedContentWidth + horizontalPad * 2
        let height = ceil(lineHeight * 2)
        let y0 = (height - lineHeight * 2) / 2
        let arrowRightX = width - horizontalPad - arrowWidth   // 箭头右缘固定
        let valueRightX = arrowRightX - textGap                // 文字右缘固定

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            drawRow(value: up, arrow: "↑", color: .systemRed,
                    y: y0, valueRightX: valueRightX, arrowRightX: arrowRightX)
            drawRow(value: down, arrow: "↓", color: .systemBlue,
                    y: y0 + lineHeight, valueRightX: valueRightX, arrowRightX: arrowRightX)
            return true
        }
    }

    private static func drawRow(value: String, arrow: String, color: NSColor,
                                y: CGFloat, valueRightX: CGFloat, arrowRightX: CGFloat) {
        let valueAttr = attributedText(value, color: .labelColor)
        let arrowAttr = attributedText(arrow, color: color)
        // 文字右对齐：从右缘向左画（三位数时向左扩展），箭头贴右缘固定
        valueAttr.draw(at: NSPoint(x: valueRightX - valueAttr.size().width, y: y))
        arrowAttr.draw(at: NSPoint(x: arrowRightX, y: y))
    }
}

// MARK: - 单个进程的实时速度

struct ProcSpeed {
    let name: String
    let down: Double   // B/s
    let up: Double     // B/s
    var total: Double { down + up }
}

// 菜单行的自定义绘制视图：手动画单行文字，文字从左缘 leftInset 处开始（垂直居中）。
// 不用 NSTextField，避免其 cell 内边距导致文字起点偏移，保证同列元素左缘像素级对齐。
final class RowView: NSView {
    private let text: String
    private let font: NSFont
    private let color: NSColor
    private let leftInset: CGFloat

    init(text: String, font: NSFont, color: NSColor, contentW: CGFloat, leftInset: CGFloat) {
        self.text = text
        self.font = font
        self.color = color
        self.leftInset = leftInset
        super.init(frame: NSRect(x: 0, y: 0, width: leftInset + contentW + leftInset, height: 22))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func draw(_ dirtyRect: NSRect) {
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let y = (bounds.height - size.height) / 2          // 垂直居中
        attr.draw(at: NSPoint(x: leftInset, y: y))
    }
}

// MARK: - 应用逻辑：状态栏 + 2 秒定时刷新 + Top10 进程流量菜单

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let refreshInterval: TimeInterval = 2
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastSample: (rx: Int64, tx: Int64)?

    // 进程流量：nettop 的 bytes 是进程启动以来的累计值，本地存上一次快照做差求速度
    private var procLast: [String: (inBytes: Int64, outBytes: Int64)] = [:]
    private var topProcesses: [ProcSpeed] = []
    private var isSamplingProcs = false
    private var lastProcSampleAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 防止 App Nap 拖慢 2 秒定时器（不会阻止系统睡眠）
        activityTokenLogic()

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        // 状态栏按钮对 image 有系统默认的横向内容边距（非我们渲染图 padding）。
        // 通过 NSImage.alignmentRectInsets 声明「对齐矩形=整个图」，消除按钮额外边距，
        // 让图标两侧贴近（配合 horizontalPad=0 后剩余空间来自此边距）。
        render(up: "0KB/s", down: "0KB/s")

        lastSample = currentBytes()
        refresh()   // 立即跑第一轮：状态栏 + 进程快照基线

        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval,
                                         repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private var activityToken: NSObjectProtocol?

    private func activityTokenLogic() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "NetSpeed 定时刷新网速")
    }

    // MARK: 菜单

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self   // 每次打开瞬间重填最新排名
        fillRows(into: menu)
        statusItem.menu = menu
    }

    /// 菜单 delegate：打开瞬间用缓存数据重排（顶部更新随 2 秒定时自动发生）
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fillRows(into: menu)
    }

    /// 自定义横线菜单项：宽度=内容区（左端 padW → 右端 padW+width），
    /// 使横线右端与第三列（上传列）右缘对齐，左端与第一列（进程名）左缘对齐。
    private func separatorView(width: CGFloat, padW: CGFloat) -> NSMenuItem {
        let h: CGFloat = 11
        let total = padW + width + padW
        let box = NSBox()
        box.boxType = .separator
        box.frame = NSRect(x: padW, y: h / 2, width: width, height: 1)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: total, height: h))
        container.addSubview(box)
        let it = NSMenuItem()
        it.view = container
        it.isEnabled = false
        return it
    }

    private func fillRows(into menu: NSMenu) {
        // 整行等宽 JetBrains Mono：进程区列右对齐精确。无表头——用速度值后缀箭头区分：
        // 下载列数值后加 ↓，上传列数值后加 ↑（如 1KB/s↓ / 0KB/s↑，方向与状态栏一致）。
        let gapW = measuredWidth("      ")
        let gap = "      "
        let downArrow = "↓", upArrow = "↑"

        var nameW: CGFloat = 0
        for p in topProcesses { nameW = max(nameW, measuredWidth(p.name)) }
        var downW: CGFloat = 0
        var upW: CGFloat = 0
        for p in topProcesses {
            downW = max(downW, measuredWidth(formatSpeed(p.down) + downArrow))
            upW = max(upW, measuredWidth(formatSpeed(p.up) + upArrow))
        }
        let nameFieldW = nameW + gapW

        func rowString(_ name: String, _ down: String, _ up: String) -> String {
            padTo(name, targetWidth: nameFieldW, alignRight: false)
            + padTo(down, targetWidth: downW, alignRight: true)
            + gap
            + padTo(up, targetWidth: upW, alignRight: true)
        }

        // 进程行：自定义 RowView 手动绘制，灰色文字、无悬停高亮（这些行无点击反馈）、垂直居中。
        func processItem(_ string: String) -> NSMenuItem {
            let contentW = measuredWidth(string)
            let padW = measuredWidth("   ")
            let totalW = padW + contentW + padW
            let h: CGFloat = 20   // 11pt 行高约14pt，行高20居中
            let view = RowView(text: string, font: menuFont, color: .secondaryLabelColor,
                               contentW: contentW, leftInset: padW)
            view.frame = NSRect(x: 0, y: 0, width: totalW, height: h)
            let it = NSMenuItem()
            it.view = view
            it.isEnabled = false   // 无高亮、无点击；view 自定义灰色
            return it
        }

        for p in topProcesses {
            let down = formatSpeed(p.down) + downArrow
            let up = formatSpeed(p.up) + upArrow
            menu.addItem(processItem(rowString(p.name, down, up)))
        }

        // 自定义横线：宽度=数据区总宽，左端=第一列左缘、右端=第三列(KB/s↑)右缘，
        // 与进程行、底部项对齐。
        let padW = measuredWidth("   ")
        let lineContentW = nameFieldW + downW + gapW + upW
        menu.addItem(separatorView(width: lineContentW, padW: padW))

        // 底部功能项：系统 NSMenuItem(title:action:) —— 自带系统原生高亮蓝条 + 原生点击。
        // 图标：SF Symbols（活动监控用波形 ECG、退出用电源），以 NSTextAttachment 嵌入标题，使
        //   前导空格能连图标一起推到与进程名首列(padW)同一竖线；图标颜色跟随标题（高亮时变白）。
        func footerItem(_ title: String, action: Selector, symbol: String) -> NSMenuItem {
            let it = NSMenuItem(title: "", action: action, keyEquivalent: "")
            it.target = self
            it.isEnabled = true
            let attr = NSMutableAttributedString()
            // 前导空格：把【图标左缘】推到与进程名首列(padW)对齐（K + footerLeadingSpaces*空格宽 = padW）
            attr.append(NSAttributedString(string: String(repeating: " ", count: footerLeadingSpaces),
                                           attributes: [.font: menuFooterFont]))
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                // 线条加粗：默认 regular 太细，这里用 semibold 权重（尺寸仍 13pt，线条更实）
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                let img = base.withSymbolConfiguration(cfg) ?? base
                img.isTemplate = true
                let attach = NSTextAttachment()
                attach.image = img
                attach.bounds = NSRect(x: 0, y: -1.5, width: 13, height: 13)   // 13pt 图标，垂直微调居中
                let iconStr = NSMutableAttributedString(attachment: attach)
                iconStr.addAttributes([.font: menuFooterFont], range: NSRange(location: 0, length: iconStr.length))
                attr.append(iconStr)
                attr.append(NSAttributedString(string: "  ", attributes: [.font: menuFooterFont]))   // 图标与文字间空隙（加大到2空格）
            }
            attr.append(NSAttributedString(string: title, attributes: [.font: menuFooterFont, .foregroundColor: NSColor.labelColor]))
            it.attributedTitle = attr
            return it
        }
        menu.addItem(footerItem("打开活动监视器", action: #selector(openActivityMonitor), symbol: "waveform.path.ecg"))
        menu.addItem(footerItem("退出 NetSpeed", action: #selector(quitApp), symbol: "power"))
    }

    @objc private func openActivityMonitor() {
        let path = "/System/Applications/Utilities/Activity Monitor.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // 直接用 NSApp.terminate(nil) 退出（本应用为纯状态栏 accessory 应用，无文档窗口，直接结束进程即可）
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 定时刷新

    private func render(up: String, down: String) {
        let img = StatusRenderer.image(up: up, down: down)
        statusItem.button?.image = img
        // 显式设 statusItem.length = 图片宽 → 消除系统给图片加的约16pt默认横向padding，
        // 按钮宽度与图片一致，左右只保留图片内 horizontalPad 的留白（各4pt）。文字变化时宽度恒定。
        statusItem.length = img.size.width
        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
    }

    private func refresh() {
        // 状态栏总网速
        let sample = currentBytes()
        if let prev = lastSample {
            let upSpeed = Double(max(0, sample.tx - prev.tx)) / refreshInterval
            let downSpeed = Double(max(0, sample.rx - prev.rx)) / refreshInterval
            render(up: formatSpeed(upSpeed), down: formatSpeed(downSpeed))
        }
        lastSample = sample

        // 进程流量 Top10（后台跑 nettop，不阻塞主线程）
        sampleProcesses()
    }

    // MARK: nettop 采样

    private func sampleProcesses() {
        guard !isSamplingProcs else { return }
        isSamplingProcs = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.runNettop()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyProcessSample(rows)
                self.isSamplingProcs = false
            }
        }
    }

    /// 运行 nettop，解析出 [进程key: (累计入, 累计出)]
    private static func runNettop() -> [(key: String, inBytes: Int64, outBytes: Int64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P 按进程聚合 -L 1 单次输出 -x 原始数值 -n 不做域名解析
        task.arguments = ["-P", "-L", "1", "-x", "-n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [(String, Int64, Int64)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, f[0] != "time" else { continue }   // 跳过表头
            // f[1]="进程名.pid"，f[4]=bytes_in，f[5]=bytes_out（-x 下均为累计原始值）
            let key = String(f[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let inB = Int64(f[4]) ?? 0
            let outB = Int64(f[5]) ?? 0
            result.append((key, inB, outB))
        }
        return result
    }

    private func applyProcessSample(_ rows: [(key: String, inBytes: Int64, outBytes: Int64)]) {
        // 用两次采样间的真实时间差（而非 nettop 运行耗时）算速度
        let now = Date()
        let dt = max(0.5, now.timeIntervalSince(lastProcSampleAt))
        lastProcSampleAt = now

        var speeds: [ProcSpeed] = []
        for row in rows {
            let prev = procLast[row.key]
            let dIn = max(0, row.inBytes - (prev?.inBytes ?? row.inBytes))
            let dOut = max(0, row.outBytes - (prev?.outBytes ?? row.outBytes))
            procLast[row.key] = (row.inBytes, row.outBytes)

            let name = procDisplayName(row.key)
            if let idx = speeds.firstIndex(where: { $0.name == name }) {
                speeds[idx] = ProcSpeed(name: name,
                                        down: speeds[idx].down + Double(dIn) / dt,
                                        up: speeds[idx].up + Double(dOut) / dt)
            } else {
                speeds.append(ProcSpeed(name: name,
                                        down: Double(dIn) / dt,
                                        up: Double(dOut) / dt))
            }
        }
        // 清理已退出进程的旧快照，防止字典无限增长
        let alive = Set(rows.map(\.key))
        procLast = procLast.filter { alive.contains($0.key) }

        topProcesses = Array(speeds.sorted { $0.total > $1.total }.prefix(10))
        rebuildMenu()   // 数据更新；菜单打开中时下次打开即见新排名
    }

    /// "python3.11.1727" → "python3.11"（去最后的 .pid）；同进程多连接 nettop 已按 pid 聚合
    private func procDisplayName(_ key: String) -> String {
        guard let lastDot = key.lastIndex(of: "."),
              key[key.index(after: lastDot)...].allSatisfy(\.isNumber) else {
            return key
        }
        return String(key[..<lastDot]).trimmingCharacters(in: .whitespaces)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不出现在 Dock，纯状态栏应用
app.run()
