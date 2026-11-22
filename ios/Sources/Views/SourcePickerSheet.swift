import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 2026-11-20：播放器动作行「音源」按钮弹出的半屏音源面板。
///
/// 需求：点击弹出弹窗显示音源，可对音源开关、调整顺序。
/// 复用 `SourceStore.setEnabled` / `reorder`，数据与实际解析优先级完全一致。
/// 🔴 2026-11-21：嵌在 `CompactPanelOverlay` 里，横条/背景/圆角由外层统一提供；
///    列表高度按音源行数自适应。深色模式跟随 App 主题（去掉强制浅色）。
/// 🔴 2026-11-21（二）：右上角「排序」改成「检测音源」按钮（重新体检全部音源），
///    底部优先级说明按用户要求移除。
/// 🔴 2026-11-22：排序改成「长按行直接拖动」——不再要「排序/完成」按钮；仅把顶栏行高度加大一点，其余尺寸沿用旧版。
/// 🔴 2026-11-22（二）：修左右边距（ScrollView 无 List 自带 inset）；
///    拖动状态拆到每行独立视图 → 每帧只有被拖的那行重算，父视图只在跨行时更新插入线，根治卡顿。
/// 🔴 2026-11-22（三）：移除三横图标；整行长按拖动改用 UIKit 识别器 ——
///    长按 0.35s 才激活拖动（未激活前 ScrollView 正常滚动、开关正常点击），
///    激活后临时禁用父 ScrollView 的 pan，松手恢复。纯 SwiftUI gesture 无法同时兼顾三者。
struct SourcePickerSheet: View {
    @ObservedObject private var store = SourceStore.shared
    @State private var isChecking = false
    let onDismiss: () -> Void

    /// 每行内容高度（标题 + 详情两行）。
    private let rowHeight: CGFloat = 72
    /// 🔴 2026-11-22(六)：行与行之间显式间距。
    ///    之前靠 `frame(height:)` 固定每行、行间 spacing=0，最后一行被底部挤压只剩 ~55pt
    ///    （实测标题间距：前 4 段 72pt，最后一段 55pt），用户反馈「最下面那个贴太近」。
    ///    现在把「行高 + 间距」拆开，每行占 rowPitch = rowHeight + rowSpacing，
    ///    拖动换算也用 rowPitch —— 保证包括最后一行在内，所有行间距完全一致。
    private let rowSpacing: CGFloat = 12
    private var rowPitch: CGFloat { rowHeight + rowSpacing }

    /// 🔴 2026-11-22(五)：导入后的提示（成功/失败条数），短暂显示后自动消失。
    @State private var importMessage: String?

    // MARK: 长按拖动排序状态（父视图只持有跨行才变的量）
    /// 只用 id 保存顺序；行内容一律从 store 按 id 实时取，避免状态不同步。
    @State private var orderedIDs: [String] = []
    /// 正在拖动的行 id（nil = 未在拖动）。
    @State private var draggingID: String?
    /// 插入指示线目标下标（-1 = 不显示）。
    @State private var insertionIndex: Int = -1

    var body: some View {
        VStack(spacing: 0) {
            // 顶部拖拽指示条（点击也能关闭）——恢复旧版尺寸
            Button { onDismiss() } label: {
                Capsule()
                    .fill(AppStyle.stroke)
                    .frame(width: 38, height: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // 顶栏：字号/间距沿用旧版，🔴 仅把这一行的高度加大一点（上下各 12pt）
            HStack {
                Text("音源")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 8)
                // 🔴 2026-11-22(六)：导入图标放大（22），保持 30 命中区。
                Button { importSources() } label: {
                    LucideIcon(icon: .listPlus, size: 22, color: AppStyle.accent)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !store.sources.isEmpty {
                    Button {
                        guard !isChecking else { return }
                        isChecking = true
                        Task {
                            await SourceHealth.shared.checkAll()
                            await MainActor.run { isChecking = false }
                        }
                    } label: {
                        // 🔴 2026-11-22(六)：按用户要求移除「检测音源」前的图标，只保留文字。
                        Text(isChecking ? "检测中…" : "检测音源")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // 列表：长按某行即可拖动排序（松手提交）
            ScrollView {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(Array(orderedIDs.enumerated()), id: \.element) { index, id in
                        sourceRow(id: id, index: index)
                    }
                }
                // 🔴 2026-11-22：ScrollView 不像 List 自带 inset，手动补 16pt 左右边距
                .padding(.horizontal, 16)
            }
            .compatScrollContentBackground(.hidden)
            // 🔴 高度贴合内容：行数×内容高 + (行数-1)×行间距，最多展示 6 行。
            //    显式把间距算进高度，最后一行不再被挤压。
            .frame(height: {
                let n = min(max(1, store.sources.count), 6)
                return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing + 8
            }())

            // 🔴 导入结果提示（短暂显示，不占常驻高度）
            if let msg = importMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        // 🔴 背景透明，交给外层面板按深浅模式绘制。
        .background(Color.clear)
        .onAppear { syncOrderFromStore(force: true) }
        // store 里增删音源时同步本地顺序（拖动中不同步，避免打断手势）
        .onReceive(store.$sources) { _ in
            syncOrderFromStore(force: false)
        }
    }

    // MARK: - 顺序同步

    /// 以 store.sources 的顺序为准同步 orderedIDs。
    /// - force：首次出现强制重建。
    /// - 非强制时：拖动中不动；已存在的 id 保持当前顺序，仅补齐新增/移除的 id。
    private func syncOrderFromStore(force: Bool) {
        guard draggingID == nil || force else { return }
        let ids = store.sources.map(\.id)
        if force {
            orderedIDs = ids
            return
        }
        let valid = Set(ids)
        var merged = orderedIDs.filter { valid.contains($0) }
        for id in ids where !merged.contains(id) { merged.append(id) }
        if merged != orderedIDs { orderedIDs = merged }
    }

    // MARK: - 行

    @ViewBuilder
    private func sourceRow(id: String, index: Int) -> some View {
        if let source = store.sources.first(where: { $0.id == id }) {
            SourcePickerRowView(
                source: source,
                index: index,
                totalCount: orderedIDs.count,
                rowHeight: rowHeight,
                dragStep: rowPitch,
                showInsertLine: draggingID != nil && draggingID != id && insertionIndex == index,
                onDragStart: { draggingID = $0; insertionIndex = index },
                onDragMove: { insertionIndex = $0 },
                onDragEnd: { finishDrag() },
                onToggle: { store.setEnabled(!source.enabled, id: source.id) }
            )
        }
    }

    /// 松手：按插入线位置把行移到目标下标，整体重排后一次性写回 store。
    private func finishDrag() {
        defer {
            draggingID = nil
            insertionIndex = -1
        }
        guard let id = draggingID,
              let from = orderedIDs.firstIndex(of: id),
              insertionIndex >= 0, insertionIndex != from else { return }

        var ids = orderedIDs
        let moved = ids.remove(at: from)
        ids.insert(moved, at: insertionIndex)
        orderedIDs = ids

        let ordered = ids.compactMap { sid in store.sources.first { $0.id == sid } }
        if ordered.count == store.sources.count {
            store.reorder(ordered)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 导入音源（复用 SourceSettingsView 的解析规则）

    /// 🔴 2026-11-22(五)：顶栏导入按钮 —— 选文件 → 先按 JSON 配置解析，认不出当 JS 脚本存。
    private func importSources() {
        var types: [UTType] = [.item, .json, .plainText, .data]
        for ext in ["txt", "conf", "js", "json5", "ini"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        FilePicker.pick(types: types) { urls in
            Task { await self.performImport(urls) }
        }
    }

    @MainActor
    private func performImport(_ urls: [URL]) async {
        var added = 0
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = Self.decodeText(data) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parsed = SourceStore.parseImport(text)
            if !parsed.isEmpty {
                for source in parsed { store.upsertReplacingByName(source) }
                added += parsed.count
                continue
            }
            let isScript = ["js", "mjs", "cjs", "txt"].contains(url.pathExtension.lowercased())
                || text.contains("globalThis") || text.contains("module.exports")
                || text.contains("require(") || text.contains("function")
            if isScript {
                let name = url.deletingPathExtension().lastPathComponent
                store.upsertReplacingByName(ThirdPartySource(
                    name: name.isEmpty ? "导入的脚本音源" : name,
                    kind: .script, script: text))
                added += 1
            }
        }
        importMessage = added > 0 ? "已导入 \(added) 个音源" : "未识别到可导入的音源"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        importMessage = nil
    }

    /// 解码文本（UTF-8 BOM / UTF-16 / GBK），与 SourceSettingsView 保持一致。
    private static func decodeText(_ data: Data) -> String? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.count >= 2 {
            let le = data[0] == 0xFF && data[1] == 0xFE
            let be = data[0] == 0xFE && data[1] == 0xFF
            if le || be {
                return String(data: data, encoding: le ? .utf16LittleEndian : .utf16BigEndian)
            }
        }
        return String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    }
}

/// 单个音源行：把拖动状态（dragOffset / isDragging）放在这里，
/// 每帧拖动只重算这一行；父视图只在跨行时收到一次 `onDragMove`。
/// 🔴 2026-11-22（三）：三横图标已移除。整行长按拖动交给 `LongPressReorderRow`
///    （UIKit 识别器），未长按时滚动 / 开关点击完全不受影响。
private struct SourcePickerRowView: View {
    let source: ThirdPartySource
    let index: Int
    let totalCount: Int
    let rowHeight: CGFloat
    /// 拖动一行的距离标尺 = 行高 + 行间距（与视觉 pitch 一致，跨行换算才准）。
    let dragStep: CGFloat
    let showInsertLine: Bool
    let onDragStart: (String) -> Void
    let onDragMove: (Int) -> Void
    let onDragEnd: () -> Void
    let onToggle: () -> Void

    @ObservedObject private var health = SourceHealth.shared
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// 已上报给父视图的目标下标，避免每帧重复回调触发父视图重算。
    @State private var reportedTarget = -1

    var body: some View {
        LongPressReorderRow(
            sourceID: source.id,
            index: index,
            totalCount: totalCount,
            rowHeight: dragStep,
            onStart: { _ in
                isDragging = true
                dragOffset = 0
                reportedTarget = index
                onDragStart(source.id)
            },
            onMove: { target in
                if target != reportedTarget {
                    reportedTarget = target
                    onDragMove(target)
                }
            },
            onEnd: {
                isDragging = false
                dragOffset = 0
                onDragEnd()
            },
            dragOffset: $dragOffset
        ) {
            rowVisual
        }
        // 🔴 2026-11-22(六)：fixedSize 保证每行（含最后一行）都拿到完整 rowHeight，
        //    不被 ScrollView 底部可用空间压缩 —— 这是「最后一行贴太近」的根因。
        .frame(height: rowHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 行的视觉内容（不含拖动手势）：健康点 + 文案 + 开关 + 插入线 / 拖动位移反馈。
    private var rowVisual: some View {
        HStack(spacing: 10) {
            healthDot
            VStack(alignment: .leading, spacing: 5) {
                Text(source.isBundled ? "默认音源" : source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(AppStyle.accent)
        }
        .padding(.vertical, 4)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDragging ? AppStyle.accent.opacity(0.14) : Color.clear)
        )
        .overlay(alignment: .top) {
            // 插入指示线：不占高度，避免布局跳动
            if showInsertLine {
                Rectangle()
                    .fill(AppStyle.accent)
                    .frame(height: 2)
            }
        }
        .offset(y: isDragging ? dragOffset : 0)
        .scaleEffect(isDragging ? 1.02 : 1)
        .zIndex(isDragging ? 10 : 0)
    }

    @ViewBuilder
    private var healthDot: some View {
        switch health.status(for: source.id) {
        case .ok:
            Circle().fill(Color.green).frame(width: 9, height: 9)
        case .bad:
            Circle().fill(Color.red).frame(width: 9, height: 9)
        case .checking:
            ProgressView().scaleEffect(0.6).frame(width: 9, height: 9).tint(AppStyle.tertiaryText)
        case .unknown:
            Color.clear.frame(width: 9, height: 9)
        }
    }

    private var detail: String {
        let support = source.supportedQualityLabels
        let supportText = support.isEmpty ? "默认 \(source.quality)" : "支持 \(support.joined(separator: "·"))"
        if source.isScript { return "JS 脚本 · \(supportText)" }
        let host = URL(string: source.template)?.host ?? "地址无效"
        return "\(host) · \(supportText)"
    }
}

/// 🔴 2026-11-22（三）：整行长按拖动识别器。
///
/// 为什么不用纯 SwiftUI gesture：
///  · 整行挂 `.gesture(LongPress+Drag)` 会吞掉 ScrollView 滚动和开关点击（用户实测「不能上滑、开关点不动」）；
///  · 只挂 24pt 小把手则用户按不到、长按排序「不起作用」。
/// 改用 UIKit `UILongPressGestureRecognizer` 包住整行：
///  · minimumPressDuration 0.35s → 手指停住才激活；滑动列表时长按直接 failed，滚动照常；
///  · `shouldRecognizeSimultaneouslyWith` 允许与 ScrollView pan 共存，激活瞬间禁用其 pan，
///    松手恢复 → 拖动期间列表不会跟着滚；
///  · `shouldReceive touch` 排除 UIControl（开关），开关点击独立生效。
private struct LongPressReorderRow<Content: View>: UIViewControllerRepresentable {
    let sourceID: String
    let index: Int
    let totalCount: Int
    let rowHeight: CGFloat
    let content: Content
    let onStart: (String) -> Void
    let onMove: (Int) -> Void
    let onEnd: () -> Void
    @Binding var dragOffset: CGFloat

    init(
        sourceID: String,
        index: Int,
        totalCount: Int,
        rowHeight: CGFloat,
        onStart: @escaping (String) -> Void,
        onMove: @escaping (Int) -> Void,
        onEnd: @escaping () -> Void,
        dragOffset: Binding<CGFloat>,
        @ViewBuilder content: () -> Content
    ) {
        self.sourceID = sourceID
        self.index = index
        self.totalCount = totalCount
        self.rowHeight = rowHeight
        self.onStart = onStart
        self.onMove = onMove
        self.onEnd = onEnd
        self._dragOffset = dragOffset
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        let lp = UILongPressGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handle(_:)))
        lp.minimumPressDuration = 0.35
        lp.allowableMovement = 10
        lp.delegate = context.coordinator
        host.view.addGestureRecognizer(lp)
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
        let c = context.coordinator
        c.sourceID = sourceID
        c.index = index
        c.totalCount = totalCount
        c.rowHeight = rowHeight
        c.onStart = onStart
        c.onMove = onMove
        c.onEnd = onEnd
        c.dragOffset = $dragOffset
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var sourceID = ""
        var index = 0
        var totalCount = 0
        var rowHeight: CGFloat = 60
        var onStart: ((String) -> Void)?
        var onMove: ((Int) -> Void)?
        var onEnd: (() -> Void)?
        var dragOffset: Binding<CGFloat>?

        private var startY: CGFloat = 0
        private var target = -1
        private var active = false

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                active = true
                startY = g.location(in: g.view).y
                target = index
                Self.setScrollPan(enabled: false, for: g.view)
                onStart?(sourceID)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                guard active, let view = g.view else { return }
                let dy = g.location(in: view).y - startY
                dragOffset?.wrappedValue = dy
                let steps = Int((dy / rowHeight).rounded())
                let t = min(max(index + steps, 0), max(totalCount - 1, 0))
                if t != target {
                    target = t
                    onMove?(t)
                }
            case .ended, .cancelled, .failed:
                guard active else { return }
                active = false
                Self.setScrollPan(enabled: true, for: g.view)
                onEnd?()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// 开关（UISwitch）等 UIControl 区域不触发长按，保证点击独立生效。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view: UIView? = touch.view
            while let cur = view {
                if cur is UIControl { return false }
                view = cur.superview
            }
            return true
        }

        /// 激活拖动时临时关掉父 ScrollView 的 pan，松手恢复 —— 拖动不会带着列表滚动。
        private static func setScrollPan(enabled: Bool, for view: UIView?) {
            var v: UIView? = view?.superview
            while let cur = v {
                if let scroll = cur as? UIScrollView {
                    scroll.panGestureRecognizer.isEnabled = enabled
                    return
                }
                v = cur.superview
            }
        }
    }
}
