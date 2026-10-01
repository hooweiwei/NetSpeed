import AppKit
import Darwin

// MARK: - 网速采样：sysctl(NET_RT_IFLIST2) 读取物理网卡与 awdl0 的累计收发字节数
//
// 路由消息按 msglen 紧凑排列（非 8 字节对齐），Swift 里不能直接 load 结构体（未对齐 UB），
// 必须按字节拷贝读取。偏移实测并与 netstat -ib 数值比对一致：
//   if_msghdr2：msglen=u16@+0, type=u8@+3, ibytes=u64@+96, obytes=u64@+104
//   sockaddr_dl：nlen=u8@+165, 接口名字符在 +168 起 nlen 个字节
//   （macOS 15 实测 msglen=160；macOS 26 实测 msglen=180，多出的字段在尾部，上述偏移未变）
// 注意：macOS 26 内核把 ibytes/obytes 当 32 位计数器写入（高 32 位恒为 0），
// 累计值在 4.29GB(2³²) 处回绕——所以速度必须用 wrapDelta32() 做回绕减法，
// 且绝对值只用于展示/调试，不可直接当真实累计量。

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
            // 统计 en* 物理网卡 + awdl0（AirDrop/接力/随航的专用直连链路）。
            // utun* 仍排除：VPN(ClashX TUN) 流量已在底层物理网卡计过，避免双重计数。
            // llw0(Wi-Fi Aware)/bridge0(互联网共享)/anpi*(内部聚合) 无独立流量或会重复计数，一并排除。
            let isPhysicalEN = name.hasPrefix("en") && name.dropFirst(2).allSatisfy(\.isNumber)
            if isPhysicalEN || name == "awdl0" {
                rx += Int64(bitPattern: readLE(buffer, offset + 96, UInt64.self))
                tx += Int64(bitPattern: readLE(buffer, offset + 104, UInt64.self))
            }
        }
        offset += msglen
    }
    return (rx, tx)
}

/// 计数器差分：只取低 32 位做回绕减法（&-）。
/// 内核计数器在 2³² 处回绕且高 32 位恒为 0，只要单次采样间隔流量 < 4.29GB
/// （即网速 < ~17Gbit/s），差分结果就与真实增量完全一致；老系统真 64 位计数器同样适用。
func wrapDelta32(_ now: Int64, _ prev: Int64) -> Int64 {
    let mask = UInt32(0xFFFF_FFFF)
    return Int64((UInt32(truncatingIfNeeded: now) & mask) &- (UInt32(truncatingIfNeeded: prev) & mask))
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

// 菜单宽度固定化（右缘不跳动的关键）：
// 旧实现每 2 秒按「当前 Top10 实测最宽值」定列宽，进程名/速度位数一变菜单就变宽变窄。
// 现在：速度列按最坏情况恒定预留；进程名列在【菜单打开瞬间】算一次并钉住，
// 打开期间所有重填沿用钉住值 → 开着的时候宽度纹丝不动，下次打开再按新数据自适应。
/// 进程名列宽上限（防极端长名撑爆菜单）：20 个 CJK 字符宽（"中"是等宽字体里最宽的一类字符），超出截断加 "…"
let menuNameMaxW = measuredWidth(String(repeating: "中", count: 20))
/// 速度列固定宽："999MB/s↓"——formatSpeed 各分支的最宽输出（"999KB/s"/"9.9MB/s"/"999MB/s" 同 7 字符，
/// GB/s 受 32 位计数器回绕上限约束最宽约 "2GB/s"，反而窄），再留 1 空格余量
let menuSpeedFieldW = measuredWidth("999MB/s↓") + measuredWidth(" ")
/// 列间空隙 / 行左右边距：全局唯一来源，行内容、横线、底部项对齐都引用这里
let menuGapStr = "      "
let menuGapW = measuredWidth(menuGapStr)
let menuSidePadW = measuredWidth("   ")

/// 超宽字符串按字符逐个实测截断，补 "…"，保证结果宽度不超过 targetWidth
private func truncateToWidth(_ s: String, targetWidth: CGFloat) -> String {
    if measuredWidth(s) <= targetWidth { return s }
    var result = ""
    for ch in s {
        if measuredWidth(result + String(ch) + "…") > targetWidth { break }
        result.append(ch)
    }
    return result + "…"
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

    private var isMenuOpen = false          // 菜单是否处于打开状态（打开期间才需要实时重填）
    private var lastMenuSignature = ""      // 上次渲染的 Top10 内容签名：数据没变就不重填，避免闪烁
    // 进程名列宽：菜单【打开瞬间】按当时最宽进程名测一次并钉住，打开期间所有重填沿用它，
    // 之后 Top10 数据再怎么变，菜单宽度都恒定（速度列本就按最坏情况恒定预留）。
    private var pinnedNameW: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 防止 App Nap 拖慢 2 秒定时器；用 AllowingIdleSystemSleep 变体，
        // 不申请 idleSystemSleepDisabled 位，避免让整机无法空闲睡眠
        activityTokenLogic()

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        // 状态栏按钮对 image 有系统默认的横向内容边距（非我们渲染图 padding）。
        // 通过 NSImage.alignmentRectInsets 声明「对齐矩形=整个图」，消除按钮额外边距，
        // 让图标两侧贴近（配合 horizontalPad=0 后剩余空间来自此边距）。
        render(up: "0KB/s", down: "0KB/s")
        setupMenu()   // 菜单只创建一次；打开期间由数据更新直接重填，与状态栏同步刷新

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
        // 注意：.userInitiated 自带 idleSystemSleepDisabled 位（0x100000，
        // 实测 userInitiated=0xffffff vs AllowingIdleSystemSleep=0xefffff），
        // 那是「用户发起的重活别让系统睡」的语义，会把整机钉住不休眠。
        // 菜单栏 2 秒定时器只需要防 App Nap，因此改用后者。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "NetSpeed 定时刷新网速")
    }

    /// 退出时显式释放活动令牌，与 beginActivity 成对。
    /// 进程结束系统本也会回收，但显式 endActivity 更清晰，
    /// 也避免个别情况下（如 NSApp.terminate）令牌句柄悬空。
    func applicationWillTerminate(_ notification: Notification) {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    // MARK: 菜单

    /// 菜单只创建一次并常驻 statusItem。旧实现每次数据更新都新建 NSMenu 赋给 statusItem，
    /// 但屏幕上「已打开的那个菜单」仍是旧对象，新赋值对它无效，
    /// 且 menuNeedsUpdate 只在打开瞬间触发一次 → 菜单开着时 Top10 永远不刷新。
    /// 现改为：打开期间直接重填同一个菜单实例，与状态栏同步 2 秒刷新。
    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        fillRows(into: menu, nameW: pinnedNameW)
        statusItem.menu = menu
    }

    /// 菜单 delegate：打开瞬间强制重填一次，保证展示的就是最新排名。
    /// 同时在这里重新测定并「钉住」进程名列宽——打开之后的定时重填全部沿用该值，
    /// 菜单宽度在整段打开期间保持恒定。
    func menuNeedsUpdate(_ menu: NSMenu) {
        lastMenuSignature = currentMenuSignature()
        var nameW: CGFloat = 0
        for p in topProcesses { nameW = max(nameW, measuredWidth(p.name)) }
        pinnedNameW = min(nameW, menuNameMaxW)
        menu.removeAllItems()
        fillRows(into: menu, nameW: pinnedNameW)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func currentMenuSignature() -> String {
        topProcesses
            .map { "\($0.name)|\(formatSpeed($0.down))|\(formatSpeed($0.up))" }
            .joined(separator: "\n")
    }

    /// 菜单打开中 → 直接重填当前打开的菜单，Top10 与状态栏同步实时刷新。
    /// 内容签名没变化时跳过，避免空闲时每 2 秒无意义重绘（高亮/闪烁）。
    private func refillOpenMenu() {
        guard isMenuOpen, let menu = statusItem.menu else { return }
        let signature = currentMenuSignature()
        guard signature != lastMenuSignature else { return }
        lastMenuSignature = signature
        menu.removeAllItems()
        fillRows(into: menu, nameW: pinnedNameW)   // 沿用打开瞬间钉住的列宽，宽度不变
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

    /// - Parameter nameW: 进程名列宽。由 menuNeedsUpdate 在打开瞬间钉住（menuNeedsUpdate 里
    ///   min(最宽进程名, menuNameMaxW)），打开期间的定时重填沿用它 → 列宽恒定。
    ///   速度两列恒用 menuSpeedFieldW（最坏情况预留），列间距/边距恒用全局常量。
    private func fillRows(into menu: NSMenu, nameW: CGFloat) {
        // 整行等宽 JetBrains Mono：进程区列右对齐精确。无表头——用速度值后缀箭头区分：
        // 下载列数值后加 ↓，上传列数值后加 ↑（如 1KB/s↓ / 0B/s↑，方向与状态栏一致）。
        let gap = menuGapStr
        let downArrow = "↓", upArrow = "↑"

        func rowString(_ name: String, _ down: String, _ up: String) -> String {
            padTo(truncateToWidth(name, targetWidth: nameW), targetWidth: nameW, alignRight: false)
            + gap
            + padTo(down, targetWidth: menuSpeedFieldW, alignRight: true)
            + gap
            + padTo(up, targetWidth: menuSpeedFieldW, alignRight: true)
        }

        // 行内容总宽 = 五个字段之和（全部恒定/已钉住），不按实测文字宽——
        // 补齐取整的亚像素误差也不会让菜单宽度逐帧抖动，右缘因此固定。
        let contentW = nameW + menuGapW + menuSpeedFieldW + menuGapW + menuSpeedFieldW

        // 进程行：自定义 RowView 手动绘制，labelColor 文字（浅色近黑、深色纯白，随系统外观自适应）、无悬停高亮（这些行无点击反馈）、垂直居中。
        func processItem(_ string: String) -> NSMenuItem {
            let padW = menuSidePadW
            let totalW = padW + contentW + padW
            let h: CGFloat = 20   // 11pt 行高约14pt，行高20居中
            let view = RowView(text: string, font: menuFont, color: .labelColor,
                               contentW: contentW, leftInset: padW)
            view.frame = NSRect(x: 0, y: 0, width: totalW, height: h)
            let it = NSMenuItem()
            it.view = view
            it.isEnabled = false   // 无高亮、无点击；view 负责文字颜色（labelColor）
            return it
        }

        for p in topProcesses {
            let down = formatSpeed(p.down) + downArrow
            let up = formatSpeed(p.up) + upArrow
            menu.addItem(processItem(rowString(p.name, down, up)))
        }

        // 自定义横线：宽度=数据区总宽（与进程行同一表达式，必然相等），
        // 左端=第一列左缘、右端=第三列(↑)右缘，与进程行、底部项对齐。
        menu.addItem(separatorView(width: contentW, padW: menuSidePadW))

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
            let upSpeed = Double(wrapDelta32(sample.tx, prev.tx)) / refreshInterval
            let downSpeed = Double(wrapDelta32(sample.rx, prev.rx)) / refreshInterval
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
            // 注意：nettop 的进程累计值是真 64 位（会超 2³²）但【不单调】——
            // 连接关闭时其字节会从统计中消失（实测 sharingd 传输中会回退数百 MB）。
            // 所以这里必须钳位为 0，不能用 wrapDelta32（会把回退误算成巨大正尖峰）。
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
        refillOpenMenu()   // 菜单打开中：直接重填当前菜单 → 与状态栏同步实时刷新
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

// 调试模式：--debug-bytes 打印一次累计收发字节数后退出。
// 用于校验接口统计口径：与 netstat -ib 中 en* + awdl0（按接口去重）的合计对账。
if CommandLine.arguments.contains("--debug-bytes") {
    let b = currentBytes()
    print("rx=\(b.rx) tx=\(b.tx)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不出现在 Dock，纯状态栏应用
app.run()
