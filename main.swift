import AppKit
import Darwin
import IOKit

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

// MARK: - 功耗格式化：最多 1 位小数，整数去掉 .0（9.2W / 30W / 0W）

func formatWatts(_ watts: Double) -> String {
    guard watts.isFinite else { return "0W" }
    let clamped = min(max(watts, 0), 999.9)
    let tenths = Int((clamped * 10).rounded())
    if tenths % 10 == 0 { return "\(tenths / 10)W" }
    return String(format: "%.1fW", Double(tenths) / 10)
}

// MARK: - SMC 功耗采样：AppleSMC 的 PSTR / PDTR（免 root）
//
// AppleSMC 用户客户端只接受固定的 80 字节 SMCKeyData_t（64 位布局），字段偏移：
//   key(u32)@0, keyInfo.dataSize(u32)@28, keyInfo.dataType(u32)@32,
//   result(u8)@40, data8(u8)@42, bytes[32]@48
// 这里用 [UInt8] 手工读写，避免 Swift 结构体布局/对齐与 C 不一致。
// PSTR = Total System Power（系统自身功耗）；PDTR = DC 输入功率（适配器输入，含充电）。
// 两个 key 都是未公开 SMC key，且可能因机型/系统版本缺失；读不到时返回 nil。
//
// 电池充电功率不走 SMC：Apple Silicon 上 PPBR 是电池放电轨读数，充电时并不可靠，
// 因此改为读取 AppleSmartBattery 的 Amperage × Voltage，并以 IsCharging 判断是否在充电。

final class PowerSampler {
    private var connection: io_connect_t = 0
    private var knownKeySizes: [String: UInt32] = [:]

    private static let structSize = 80
    private static let kernelIndexSMC: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let offKey = 0
    private static let offDataSize = 28
    private static let offDataType = 32
    private static let offResult = 40
    private static let offData8 = 42
    private static let offBytes = 48
    private static let floatType: UInt32 = 0x666c_7420   // "flt "

    init() { openIfNeeded() }
    deinit { close() }

    func systemPowerWatts() -> Double? { readFloat("PSTR").map(Double.init) }
    func adapterPowerWatts() -> Double? { readFloat("PDTR").map(Double.init) }

    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    private func openIfNeeded() {
        guard connection == 0 else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return }
        connection = conn
    }

    private func readFloat(_ key: String) -> Float? {
        openIfNeeded()
        guard connection != 0 else { return nil }

        let size: UInt32
        if let cached = knownKeySizes[key] {
            size = cached
        } else {
            guard let info = readKeyInfo(key),
                  info.size == 4,
                  info.type == Self.floatType else { return nil }
            size = info.size
            knownKeySizes[key] = size
        }
        guard size == 4 else { return nil }

        var input = [UInt8](repeating: 0, count: Self.structSize)
        writeUInt32(Self.packKey(key), to: &input, at: Self.offKey)
        writeUInt32(size, to: &input, at: Self.offDataSize)
        input[Self.offData8] = Self.cmdReadBytes
        guard let output = call(input), output[Self.offResult] == 0 else { return nil }

        // Apple Silicon 的 SMC flt 为小端 IEEE-754；PSTR/PDTR 均走这一分支。
        let bits = UInt32(output[Self.offBytes])
            | UInt32(output[Self.offBytes + 1]) << 8
            | UInt32(output[Self.offBytes + 2]) << 16
            | UInt32(output[Self.offBytes + 3]) << 24
        let watts = Float(bitPattern: bits)
        guard watts.isFinite, watts >= 0, watts < 1000 else { return nil }
        return watts
    }

    private func readKeyInfo(_ key: String) -> (size: UInt32, type: UInt32)? {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        writeUInt32(Self.packKey(key), to: &input, at: Self.offKey)
        input[Self.offData8] = Self.cmdReadKeyInfo
        guard let output = call(input) else { return nil }
        return (readUInt32(output, at: Self.offDataSize),
                readUInt32(output, at: Self.offDataType))
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                IOConnectCallStructMethod(
                    connection, Self.kernelIndexSMC,
                    inputRaw.baseAddress, Self.structSize,
                    outputRaw.baseAddress, &outputSize)
            }
        }
        return kr == KERN_SUCCESS ? output : nil
    }

    private static func packKey(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8 { value = (value << 8) | UInt32(byte) }
        return value
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

// MARK: - 电池充电功率：AppleSmartBattery 的电压 × 电流（未充电时为 0W）

func batteryChargingWatts() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    func number(_ key: String) -> NSNumber? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return value as? NSNumber
    }

    // 电池供电、充满、优化充电暂停都算「未充电」→ 统一显示 0W
    guard number("IsCharging")?.boolValue == true else { return 0 }
    guard let voltageMV = number("Voltage")?.doubleValue, voltageMV > 0 else { return nil }
    let currentMA = number("Amperage")?.doubleValue
        ?? number("InstantAmperage")?.doubleValue ?? 0
    // 适配器功率不足时系统可能仍报 IsCharging，但电流为负（实际在放电）→ 按 0W 处理
    guard currentMA > 0 else { return 0 }
    return currentMA * voltageMV / 1_000_000
}

// MARK: - 菜单排版：原生 NSMenuItem + 段落制表位（tab stop）
//
// 不再用「补空格」凑对齐——空格排版依赖字体实测宽度，换机器/换系统版本就会错位。
// 现在整行是一个原生 attributedTitle，三列由 NSParagraphStyle.tabStops 定义：
//   第 1 列左对齐（进程名），第 2、3 列右对齐（下载/上传速度）。
// 右对齐制表位的语义是「文字右缘落在该位置」，因此每行段落宽度恒等于最后一个制表位，
// 菜单宽度天然固定（与原来「钉住列宽」的目的一致，但不再需要任何实测补偿）。
//
// 字体用系统自带的 SF Mono（monospacedSystemFont），无需随包分发字体文件。

// 菜单字体：表格/数值用 SF Mono 11pt；功耗行标签与标题行用系统字体。
let menuFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
let menuFooterFont = NSFont.menuFont(ofSize: 13)

/// 菜单图标在菜单里的目标尺寸（系统图标槽位为 16pt）。
let menuIconTargetSize: CGFloat = 16
/// 标题行 logo 尺寸（与标题文字视觉高度相当）。
let menuLogoSize: CGFloat = 15

private func measuredWidth(_ s: String) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: menuFont]).size().width
}

// MARK: 菜单宽度与标题行

/// 标题行左侧内边距：让 logo 与功耗行图标列左缘对齐。
/// 视图原点比菜单左缘靠内约 9pt（系统菜单项的内边距），实测 logo 落在 12pt 处即与图标列齐。
let menuHeaderLeadingInset: CGFloat = 12
/// 标题行右侧内边距。
let menuHeaderTrailingInset: CGFloat = 14
/// 标题行高度。
let menuHeaderHeight: CGFloat = 30
/// 标题字号：与系统菜单栏/状态栏同量级（13pt），不再放大。
let menuHeaderFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

/// 活动监视器路径（系统固定位置）。
let activityMonitorPath = "/System/Applications/Utilities/Activity Monitor.app"

/// 菜单内容区宽度（标题列起点 → 最后一个右对齐制表位）。
func menuContentWidth(nameW: CGFloat) -> CGFloat {
    let stops = menuTabStops(nameW: nameW)
    return stops.last?.location ?? 0
}

/// 标题行视图：logo + NetSpeed，右侧「退出」胶囊按钮。
/// 这是菜单里唯一的自定义视图——原生菜单项无法把控件贴到最右缘。
final class MenuHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "NetSpeed")
    private let closeButton = ExitPillButton()
    private let onClose: () -> Void

    init(contentWidth: CGFloat, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: contentWidth + menuHeaderLeadingInset + menuHeaderTrailingInset,
                                 height: menuHeaderHeight))
        autoresizingMask = [.width]

        // 标题：与系统菜单同字号（13pt），略加粗
        titleLabel.font = menuHeaderFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        // 退出按钮：文字「退出」+ 胶囊外框，灰色字体，悬停高亮
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "退出 NetSpeed"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let buttonH: CGFloat = 18
        let buttonW: CGFloat = 44
        let gapLogoTitle: CGFloat = 6

        closeButton.frame = NSRect(x: bounds.width - menuHeaderTrailingInset - buttonW,
                                   y: (h - buttonH) / 2,
                                   width: buttonW, height: buttonH)

        // logo 与标题整体靠左：logo 紧贴菜单左内边距（menuHeaderLeadingInset = 0）
        let titleX = menuHeaderLeadingInset + menuLogoSize + gapLogoTitle
        let titleH: CGFloat = 17
        titleLabel.frame = NSRect(x: titleX,
                                  y: (h - titleH) / 2,
                                  width: max(0, closeButton.frame.minX - 8 - titleX),
                                  height: titleH)
    }

    /// logo 画在标题左侧（自己绘制，避免 NSImageView 对 SVG 的处理差异）。
    override func draw(_ dirtyRect: NSRect) {
        guard let logo = menuLogoImage else { return }
        let logoRect = NSRect(x: menuHeaderLeadingInset,
                              y: (bounds.height - menuLogoSize) / 2,
                              width: menuLogoSize, height: menuLogoSize)
        // 模板图由绘制上下文的 tint 着色，这里直接画即可
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    @objc private func closeTapped() {
        // 菜单处于 tracking 模式，直接 terminate 可能被吞；先结束菜单跟踪再退出。
        enclosingMenuItem?.menu?.cancelTracking()
        onClose()
    }
}

/// 「退出」胶囊按钮：自绘圆角边框与悬停底色。
/// 不用 NSButton 的 bezel——无边框样式会把 layer 的底色/描边一并吃掉，且高亮行为不可控。
final class ExitPillButton: NSButton {
    private var hovered = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        super.mouseDown(with: event)          // 交给 NSButton 处理点击与 action
        pressed = false; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        if hovered {
            NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.75 : 1.0).setFill()
            path.fill()
        } else {
            NSColor.clear.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let text = "退出" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: hovered ? NSColor.white : NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }
}

// 列宽：速度列按最坏情况恒定预留（"999MB/s↓" 是 formatSpeed 最宽输出），
// 进程名列在【菜单打开瞬间】按当时最宽进程名测一次并钉住，打开期间不变 → 右缘不跳动。
/// 进程名列宽上限（防极端长名撑爆菜单）：20 个 CJK 字符宽，超出截断加 "…"
let menuNameMaxW = measuredWidth(String(repeating: "中", count: 20))
/// 速度列固定宽："999MB/s↓"——formatSpeed 各分支的最宽输出
let menuSpeedFieldW = ceil(measuredWidth("999MB/s↓"))
/// 列间空隙：制表位之间的最小间隔
let menuGapW = 6 * measuredWidth(" ")

/// 三列的制表位位置（相对行内容左缘）。第 1 列无制表位，天然左对齐。
func menuTabStops(nameW: CGFloat) -> [NSTextTab] {
    let stop2 = nameW + menuGapW + menuSpeedFieldW
    let stop3 = stop2 + menuGapW + menuSpeedFieldW
    return [NSTextTab(textAlignment: .right, location: stop2),
            NSTextTab(textAlignment: .right, location: stop3)]
}

/// 三列内容的段落样式。制表位位置相对标题列左缘（即系统摆好图标之后的起点），
/// 因此所有行——无论有没有图标——三列的相对位置都完全一致。
func menuRowStyle(nameW: CGFloat) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.tabStops = menuTabStops(nameW: nameW)
    return p
}

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

/// 项目 logo：SVG 由 AppKit 直接加载，栅格化成模板图。
/// 资源查找顺序：app bundle 内 → 可执行文件同级 Resources → 仓库 docs 目录（开发时直接跑二进制）。
let menuLogoImage: NSImage? = {
    let candidates: [URL?] = [
        Bundle.main.url(forResource: "netspeed-logo", withExtension: "svg"),
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/netspeed-logo.svg"),
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("netspeed-logo.svg"),
    ]
    for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let svg = NSImage(contentsOf: url) {
            return menuSymbolImage(svg, accessibilityDescription: "NetSpeed",
                                   pointSize: 16, targetSize: menuLogoSize)
        }
    }
    return nil
}()

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
            drawRow(value: up, arrow: "↑",
                    y: y0, valueRightX: valueRightX, arrowRightX: arrowRightX)
            drawRow(value: down, arrow: "↓",
                    y: y0 + lineHeight, valueRightX: valueRightX, arrowRightX: arrowRightX)
            return true
        }
    }

    // 箭头与数值同色（labelColor：深色菜单栏为白、浅色菜单栏为黑，随系统外观自适应）
    private static func drawRow(value: String, arrow: String,
                                y: CGFloat, valueRightX: CGFloat, arrowRightX: CGFloat) {
        let valueAttr = attributedText(value, color: .labelColor)
        let arrowAttr = attributedText(arrow, color: .labelColor)
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

/// 不可点击的整行透明占位图：让原生菜单项照常走「图标列 + 标题列」布局，
/// 但视觉上只留标题。进程行用它，保证所有行的标题左缘来自同一套系统布局。
let menuInvisibleIcon: NSImage = {
    let img = NSImage(size: NSSize(width: 16, height: 16))
    img.isTemplate = true
    return img
}()

/// 菜单图标：把任意矢量图（SF Symbol / SVG）栅格化成位图模板图，并裁到图形实际边界后铺满目标尺寸。
///
/// 两个必须这么做的原因：
/// 1. 菜单项的 image 槽位不渲染 SF Symbol 的矢量表示（实测整枚图标不显示），只有位图能显示。
/// 2. 符号自带大量内边距（bolt.fill 在 13pt 画布里图形只有约 4×6pt），
///    直接按画布缩放会显得很小；因此先量出图形的实际像素边界，裁掉留白再放大。
/// isTemplate = true 让图标跟随标题颜色（高亮时变白）。
func menuSymbolImage(_ source: NSImage,
                      accessibilityDescription: String,
                      pointSize: CGFloat = 13,
                      targetSize: CGFloat = menuIconTargetSize) -> NSImage? {
    // SF Symbol 需要按 pointSize 配置；SVG 等普通图没有 symbol 配置，保持原样。
    let sym = source.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)) ?? source

    // 1) 高分辨率渲染到 probe 画布，量出墨迹边界（裁掉符号自带的内边距）
    let probeSide: CGFloat = 96
    let probePx = Int(probeSide)
    guard let probe = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: probePx, pixelsHigh: probePx,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    // 同 out：size 必须在创建 context 之前设好
    probe.size = NSSize(width: probeSide, height: probeSide)
    guard let probeCtx = NSGraphicsContext(bitmapImageRep: probe) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = probeCtx
    let s = sym.size
    let fit = min(probeSide / max(s.width, 0.01), probeSide / max(s.height, 0.01))
    let pw = s.width * fit, ph = s.height * fit
    drawImage(sym, in: NSRect(x: (probeSide - pw) / 2, y: (probeSide - ph) / 2, width: pw, height: ph))
    NSGraphicsContext.restoreGraphicsState()

    let bbox = inkBounds(probe)
    guard bbox.width > 0, bbox.height > 0 else { return nil }

    // 2) 按墨迹边界裁剪（裁的是像素，因此用像素坐标），再等比放大到目标尺寸
    let scale: CGFloat = 3
    let px = Int(targetSize * scale)
    let srcW = bbox.width, srcH = bbox.height
    let scaleFit = min(CGFloat(px) / srcW, CGFloat(px) / srcH)
    let dw = srcW * scaleFit / scale, dh = srcH * scaleFit / scale

    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    // 必须在创建 NSGraphicsContext 之前设 size：上下文按创建时刻的 rep.size 决定坐标系，
    // 先建上下文再改 size 会让绘制按旧的像素尺寸（48pt）布局，图形只剩 1/3 大。
    out.size = NSSize(width: targetSize, height: targetSize)
    guard let outCtx = NSGraphicsContext(bitmapImageRep: out) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = outCtx
    outCtx.cgContext.interpolationQuality = .high
    // 直接从 probe 位图按墨迹矩形取像素绘制：一步完成「裁剪 + 缩放」，
    // 不经过 CGImage.cropping，避免两个坐标系来回换算出错。
    if let probeCG = probe.cgImage, let cropped = probeCG.cropping(to: bbox) {
        outCtx.cgContext.draw(cropped,
                              in: CGRect(x: (targetSize - dw) / 2, y: (targetSize - dh) / 2,
                                         width: dw, height: dh))
    }
    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: NSSize(width: targetSize, height: targetSize))
    img.addRepresentation(out)
    img.isTemplate = true
    return img
}

/// SF Symbol 便捷入口。
func menuSymbolImage(_ name: String,
                     accessibilityDescription: String,
                     pointSize: CGFloat = 13,
                     targetSize: CGFloat = menuIconTargetSize) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
        return nil
    }
    return menuSymbolImage(base, accessibilityDescription: accessibilityDescription,
                           pointSize: pointSize, targetSize: targetSize)
}

/// 把图像画进当前上下文。SVG 走 cgImage（`draw(in:)` 在位图上下文里对 SVG 表现不稳定），
/// 位图/符号走常规 `draw(in:)`。
private func drawImage(_ image: NSImage, in rect: NSRect) {
    if image.representations.first is NSBitmapImageRep {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        return
    }
    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
    } else {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}

/// 位图里不透明像素的边界（用于裁掉图形周围留白）。
/// 用 `colorAt` 读取而非直接读 dataProvider 缓冲区：后者在刚绘制完的位图上可能还是旧数据。
private func inkBounds(_ rep: NSBitmapImageRep) -> CGRect {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return .zero }
    // 钳到画布内：cropping(to:) 的矩形越界会返回 nil（SVG 撑满整高时正好触到边界）
    let x0 = max(0, min(minX, w - 1))
    let y0 = max(0, min(minY, h - 1))
    let x1 = max(x0, min(maxX, w - 1))
    let y1 = max(y0, min(maxY, h - 1))
    return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

// MARK: - 应用逻辑：状态栏 + 2 秒定时刷新 + Top10 进程流量菜单

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let refreshInterval: TimeInterval = 2
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastSample: (rx: Int64, tx: Int64)?

    // 功耗：SMC PSTR（系统运行）/ PDTR（电源输入）+ 电池充电功率，2 秒采样 + EMA 平滑
    private let powerSampler = PowerSampler()
    private var systemPowerW: Double = 0
    private var adapterPowerW: Double = 0
    private var batteryPowerW: Double = 0
    private var systemPowerHasSample = false
    private var adapterPowerHasSample = false
    private var batteryPowerHasSample = false
    private let powerSmoothingFactor = 0.3
    private let systemPowerIconName = "bolt.fill"
    private let adapterPowerIconName: String = {
        for name in ["powerplug.fill", "powerplug"] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        }
        return "bolt.fill"
    }()
    private let batteryPowerIconName: String = {
        // 实心电池块 + 闪电（无内边框），与 bolt.fill / powerplug.fill 的实心风格一致
        for name in ["bolt.batteryblock.fill", "battery.100.bolt", "battery.100"] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        }
        return "battery.100"
    }()
    // 底部功能项图标：与功耗行同为面性填充风格；旧系统回退到填充柱状图/原线框符号。

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
        powerSampler.close()
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
            + "\nPWR|\(formatWatts(systemPowerW))|\(formatWatts(adapterPowerW))|\(formatWatts(batteryPowerW))"
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

    /// - Parameter nameW: 进程名列宽。由 menuNeedsUpdate 在打开瞬间钉住
    ///   （min(最宽进程名, menuNameMaxW)），打开期间的定时重填沿用它 → 列宽恒定。
    ///   速度两列恒用 menuSpeedFieldW（最坏情况预留），列间距恒用 menuGapW。
    private func fillRows(into menu: NSMenu, nameW: CGFloat) {
        // 无表头——用速度值后缀箭头区分：下载列加 ↓、上传列加 ↑（方向与状态栏一致）。
        // 三列由制表位定位：进程名左对齐，两个速度列右对齐。
        let downArrow = "↓", upArrow = "↑"

        /// 标题行（NetSpeed + 关闭按钮）。宽度 = 内容区 + 两侧内边距，
        /// 与菜单宽度一致，按钮因此贴在最右缘。
        func headerItem(width: CGFloat) -> NSMenuItem {
            let view = MenuHeaderView(contentWidth: width) { NSApp.terminate(nil) }
            let it = NSMenuItem()
            it.view = view
            it.isEnabled = false
            return it
        }

        /// 把三列内容拼成「原生 attributedTitle」：一个制表位分隔的字符串。
        /// 所有行共用同一套制表位，列对齐由排版引擎保证，与文字实际宽度无关。
        func rowTitle(_ name: String, _ down: String, _ up: String) -> NSAttributedString {
            let text = "\(truncateToWidth(name, targetWidth: nameW))\t\(down)\t\(up)"
            return NSAttributedString(string: text, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: menuRowStyle(nameW: nameW),
            ])
        }

        // 进程行：原生菜单项 + 透明占位图标（标题列左缘由系统统一决定）。
        // 点击任意进程行 → 打开活动监视器的「网络」页。
        func processItem(_ name: String, _ down: String, _ up: String) -> NSMenuItem {
            let it = NSMenuItem()
            it.attributedTitle = rowTitle(name, down, up)
            it.image = menuInvisibleIcon
            it.action = #selector(openActivityMonitorNetwork)
            it.target = self
            it.isEnabled = true
            return it
        }

        // 功耗行：图标 = 左侧 SF Symbol（原生图标列），标题 = 「标签 \t 数值」，
        // 数值走与速度列相同的右对齐制表位 → 右缘与表格右缘严格对齐。
        // 数值与进程行同一字体（SF Mono 11pt），走同一个右对齐制表位 → 与第 3 列严格对齐。
        func powerItem(iconName: String, label: String, value: String) -> NSMenuItem {
            let it = NSMenuItem()
            // 两个制表位：数值跳过第 2 列（下载列），直接右对齐到第 3 列（上传列）右缘。
            let text = "\(label)\t\t\(value)"
            let attr = NSMutableAttributedString(string: text, attributes: [
                .font: menuFooterFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: menuRowStyle(nameW: nameW),
            ])
            let valueRange = NSRange(location: (label as NSString).length + 2, length: (value as NSString).length)
            attr.addAttribute(.font, value: menuFont, range: valueRange)
            it.attributedTitle = attr
            it.image = menuSymbolImage(iconName, accessibilityDescription: label)
            it.action = #selector(openActivityMonitorEnergy)   // 点击任意功耗行 → 活动监视器「能耗」页
            it.target = self
            it.isEnabled = true
            return it
        }

        // 顶部标题行：NetSpeed（大一号、加粗）+ 最右侧关闭按钮。
        // 视图项宽度决定菜单宽度，因此先按行内容算好整宽再构造，按钮才能贴到最右缘。
        menu.addItem(headerItem(width: menuContentWidth(nameW: nameW)))
        menu.addItem(.separator())      // 标题行与进程列表之间的分隔线

        for p in topProcesses {
            menu.addItem(processItem(p.name,
                                     formatSpeed(p.down) + downArrow,
                                     formatSpeed(p.up) + upArrow))
        }

        menu.addItem(.separator())

        menu.addItem(powerItem(iconName: systemPowerIconName,
                               label: "系统运行功耗",
                               value: formatWatts(systemPowerW)))
        menu.addItem(powerItem(iconName: adapterPowerIconName,
                               label: "电源输入功率",
                               value: formatWatts(adapterPowerW)))
        menu.addItem(powerItem(iconName: batteryPowerIconName,
                               label: "电池充电功率",
                               value: formatWatts(batteryPowerW)))
    }

    /// 打开活动监视器并落到指定标签页（0=CPU 1=内存 2=能耗 3=磁盘 4=网络）。
    ///
    /// 活动监视器只在【启动时】读取 `SelectedTab` 偏好，且没有可用的命令行参数切换标签页
    /// （`strings` 里只有一个 `-file`），运行中改偏好或传参都不会切页。
    /// 因此这里的策略是：未运行 → 先写偏好再启动，保证落在目标页；
    /// 已运行 → 只把它激活到前台，不改动用户当前的标签页与窗口状态。
    private func openActivityMonitor(tab: Int) {
        let bundleID = "com.apple.ActivityMonitor"
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        let defaults = UserDefaults(suiteName: bundleID)
        defaults?.set(tab, forKey: "SelectedTab")
        defaults?.synchronize()
        NSWorkspace.shared.open(URL(fileURLWithPath: activityMonitorPath))
    }

    @objc private func openActivityMonitorNetwork() { openActivityMonitor(tab: 4) }
    @objc private func openActivityMonitorEnergy() { openActivityMonitor(tab: 2) }

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
        // 功耗（PSTR/PDTR + 电池充电）：读不到时按 0W 处理
        refreshPower()

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

    // MARK: 功耗采样

    private func refreshPower() {
        applyPowerSample(powerSampler.systemPowerWatts(),
                         into: &systemPowerW, hasSample: &systemPowerHasSample)
        applyPowerSample(powerSampler.adapterPowerWatts(),
                         into: &adapterPowerW, hasSample: &adapterPowerHasSample)
        applyPowerSample(batteryChargingWatts(),
                         into: &batteryPowerW, hasSample: &batteryPowerHasSample)
    }

    /// EMA 平滑；读不到时立即回落到 0W（PDTR 在电池供电时也是 0）。
    private func applyPowerSample(_ raw: Double?,
                                  into value: inout Double,
                                  hasSample: inout Bool) {
        guard let raw else {
            value = 0
            hasSample = false
            return
        }
        let clamped = min(max(raw, 0), 999.9)
        if !hasSample || clamped <= 0.05 {
            value = clamped
            hasSample = true
            return
        }
        value += (clamped - value) * powerSmoothingFactor
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

    /// 弹出真实菜单（--show-menu），供截图核对系统实际排版。
    func showMenuForScreenshot() {
        guard let menu = statusItem.menu, let button = statusItem.button else { return }
        menuNeedsUpdate(menu)
        isMenuOpen = true
        // 与真实点击一致：从按钮下沿向下弹出（按钮坐标系 y 向上，故取负值）
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: -4),
                   in: button)
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

// 调试模式：--debug-power 连续打印 5 次 PSTR/PDTR 与电池充电功率后退出。
if CommandLine.arguments.contains("--debug-power") {
    let sampler = PowerSampler()
    for i in 0..<5 {
        let pstr = sampler.systemPowerWatts()
        let pdtr = sampler.adapterPowerWatts()
        let battery = batteryChargingWatts()
        print("PSTR=\(pstr.map { String(format: "%.2f", $0) } ?? "nil") "
            + "PDTR=\(pdtr.map { String(format: "%.2f", $0) } ?? "nil") "
            + "BATT=\(battery.map { String(format: "%.2f", $0) } ?? "nil")")
        if i < 4 { Thread.sleep(forTimeInterval: 1) }
    }
    sampler.close()
    exit(0)
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

// 调试模式：--show-menu 直接弹出真实菜单并保持打开，供截图核对系统实际渲染效果。
if CommandLine.arguments.contains("--show-menu") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        delegate.showMenuForScreenshot()
    }
}
app.run()
