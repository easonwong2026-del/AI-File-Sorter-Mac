import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

private enum InboxFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case actionable
    case waiting
    case unmatched
    case skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .actionable: return "可处理"
        case .waiting: return "等待中"
        case .unmatched: return "未匹配"
        case .skipped: return "已跳过"
        }
    }
}

private enum InboxSort: String, CaseIterable, Identifiable, Hashable {
    case name
    case modified
    case size
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .modified: return "最近修改"
        case .size: return "大小"
        case .status: return "状态"
        }
    }
}

private enum InboxRowKind: Equatable {
    case actionable
    case waiting
    case unmatched
    case skipped
}

private struct InboxItem: Identifiable {
    let id: String
    let path: String
    let fileName: String
    let extensionName: String
    let fileSize: UInt64
    let modifiedAt: Date
    let kind: InboxRowKind
    let statusTitle: String
    let reason: String
    let remaining: TimeInterval?
    let target: String
    let keyword: String
    let isPending: Bool
}

struct InboxView: View {
    @ObservedObject var model: AppModel
    @State private var inboxItems: [InboxItem] = []
    @State private var selectedPath: String?
    @State private var filter: InboxFilter = .all
    @State private var sortOrder: InboxSort = .name
    @State private var extensionFilter = "全部"
    @State private var searchText = ""
    @State private var watchFolderError: String?
    @State private var showingPlan = false

    private var selectedCount: Int { model.pendingFiles.count(where: \.selected) }

    private var extensions: [String] {
        ["全部", "无扩展名"] + inboxItems.map(\.extensionName).filter { !$0.isEmpty }.sorted().reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private var visibleItems: [InboxItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = inboxItems.filter { item in
            let matchesStatus: Bool
            switch filter {
            case .all: matchesStatus = true
            case .actionable: matchesStatus = item.kind == .actionable
            case .waiting: matchesStatus = item.kind == .waiting
            case .unmatched: matchesStatus = item.kind == .unmatched
            case .skipped: matchesStatus = item.kind == .skipped
            }
            let matchesSearch = query.isEmpty
                || item.fileName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || item.reason.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            let matchesExtension = extensionFilter == "全部"
                || (extensionFilter == "无扩展名" ? item.extensionName.isEmpty : item.extensionName == extensionFilter)
            return matchesStatus && matchesSearch && matchesExtension
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .name:
                return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            case .modified:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            case .size:
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize > rhs.fileSize }
            case .status:
                if lhs.statusTitle != rhs.statusTitle {
                    return lhs.statusTitle.localizedCaseInsensitiveCompare(rhs.statusTitle) == .orderedAscending
                }
            }
            return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
        }
    }

    private var summaryText: String {
        let actionable = inboxItems.count { $0.kind == .actionable }
        let waiting = inboxItems.count { $0.kind == .waiting }
        let unmatched = inboxItems.count { $0.kind == .unmatched }
        let skipped = inboxItems.count { $0.kind == .skipped }
        return "可处理 \(actionable) · 等待 \(waiting) · 未匹配 \(unmatched) · 已跳过 \(skipped)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("收件箱").font(.title2.bold())
                    Text("监听目录第一层的普通文件；不因当前整理方式而隐藏。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("整理计划") {
                    model.generateOrganizingPlan()
                    showingPlan = true
                }
                Button { refreshInbox() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新收件箱")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                TextField("搜索文件名或原因", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Picker("状态", selection: $filter) {
                    ForEach(InboxFilter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                Picker("扩展名", selection: $extensionFilter) {
                    ForEach(extensions, id: \.self) { value in
                        Text(value == "无扩展名" || value == "全部" ? value : ".\(value)").tag(value)
                    }
                }
                .labelsHidden()
                Picker("排序", selection: $sortOrder) {
                    ForEach(InboxSort.allCases) { value in
                        Text("按\(value.title)").tag(value)
                    }
                }
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            HStack(spacing: 10) {
                Text("\(inboxItems.count) 个文件").font(.caption.weight(.medium))
                Text(summaryText).font(.caption).foregroundStyle(.secondary)
                if selectedCount > 0 {
                    Text("已选 \(selectedCount) 项")
                        .font(.caption.weight(.medium)).foregroundStyle(.tint)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            HSplitView {
                inboxList
                    .frame(minWidth: 430, idealWidth: 510)
                inboxDetail
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text(selectedCount == 0 ? "勾选可执行项后可批量整理或忽略" : "将处理 \(selectedCount) 个所选文件")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("忽略 \(selectedCount) 项") { model.ignoreSelectedPending() }
                    .disabled(selectedCount == 0 || model.busy)
                Button("整理 \(selectedCount) 项…") { model.moveSelectedOnce() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0 || model.busy)
            }
            .padding(12)
            if model.busy {
                ProgressView().controlSize(.small).padding(.bottom, 4)
            }
            Text(model.message)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.bottom, 9)
        }
        .onAppear { refreshInbox() }
        .onChange(of: model.pendingFiles.map { "\($0.path)|\($0.ignored)" }) { _ in refreshInbox() }
        .onChange(of: model.config) { _ in refreshInbox() }
        .sheet(item: $model.pendingMoveDraft) { draft in
            PendingMoveSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $showingPlan) {
            OrganizingPlanView(model: model, isPresented: $showingPlan)
        }
    }

    private var inboxList: some View {
        Group {
            if let watchFolderError {
                EmptyStateView(
                    title: "无法读取监听目录",
                    systemImage: "folder.badge.questionmark",
                    detail: "\(watchFolderError)\n请在设置中选择一个可访问的文件夹。"
                )
            } else if inboxItems.isEmpty {
                EmptyStateView(
                    title: "收件箱是空的",
                    systemImage: "tray",
                    detail: "监听目录第一层暂时没有普通文件。"
                )
            } else if visibleItems.isEmpty {
                EmptyStateView(
                    title: "没有符合筛选条件的文件",
                    systemImage: "line.3.horizontal.decrease.circle",
                    detail: "可以清除搜索、状态或扩展名筛选。"
                )
            } else {
                List(selection: $selectedPath) {
                    ForEach(visibleItems) { item in
                        inboxRow(item)
                            .tag(item.path)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func inboxRow(_ item: InboxItem) -> some View {
        HStack(spacing: 9) {
            Toggle("", isOn: selectionBinding(for: item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!item.isPending)
            Image(systemName: statusIcon(for: item.kind))
                .foregroundStyle(statusColor(for: item.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).lineLimit(1)
                Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.statusTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(for: item.kind))
                if let remaining = item.remaining {
                    Text(remainingText(remaining))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var inboxDetail: some View {
        if let selectedPath, let item = inboxItems.first(where: { $0.path == selectedPath }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: statusIcon(for: item.kind))
                            .font(.system(size: 27))
                            .foregroundStyle(statusColor(for: item.kind))
                            .frame(width: 48, height: 48)
                            .background(statusColor(for: item.kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.fileName).font(.title2.bold()).textSelection(.enabled)
                            Text(NSString(string: item.path).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Toggle("加入批量操作", isOn: selectionBinding(for: item))
                            .toggleStyle(.checkbox)
                            .disabled(!item.isPending)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(item.statusTitle).font(.headline).foregroundStyle(statusColor(for: item.kind))
                            Spacer()
                            if let remaining = item.remaining {
                                Text(remainingText(remaining)).font(.caption.weight(.medium)).monospacedDigit()
                            }
                        }
                        Text(item.reason).foregroundStyle(.secondary).textSelection(.enabled)
                        if let target = nonEmptyPath(item.target) {
                            Label("建议整理到：\(NSString(string: target).abbreviatingWithTildeInPath)", systemImage: "folder")
                                .font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding(17)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("文件信息").font(.headline)
                        Text("扩展名：\(item.extensionName.isEmpty ? "无" : ".\(item.extensionName)")")
                        Text("大小：\(fileSizeText(item.fileSize))")
                        Text("最近修改：\(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        Button("快速预览") { model.quickLookPending(pendingFile(for: item)) }
                            .keyboardShortcut(.space, modifiers: [])
                        Button("在 Finder 显示") { model.revealPending(pendingFile(for: item)) }
                        if item.isPending {
                            Button("整理一次…") { model.beginPendingMove(paths: [item.path]) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if !item.isPending {
                        Text("当前文件保留在收件箱中用于说明状态；执行按钮只对现有可执行列表启用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
            }
        } else {
            EmptyStateView(title: "选择一个文件", systemImage: "doc.text.magnifyingglass", detail: "查看状态、原因、建议位置，或使用 Quick Look。")
        }
    }

    private func refreshInbox() {
        let expanded = NSString(string: model.config.watchFolder).expandingTildeInPath
        let folder = URL(fileURLWithPath: expanded, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            inboxItems = []
            watchFolderError = expanded.isEmpty ? "监听文件夹为空" : "目录不存在：\(expanded)"
            selectedPath = nil
            return
        }

        do {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isUserImmutableKey, .fileSizeKey,
                .creationDateKey, .contentModificationDateKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [])
            let now = Date()
            inboxItems = urls.compactMap { makeInboxItem(url: $0, now: now) }
            watchFolderError = nil
            if let selectedPath, !inboxItems.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = inboxItems.first?.path
            } else if self.selectedPath == nil {
                self.selectedPath = inboxItems.first?.path
            }
        } catch {
            inboxItems = []
            watchFolderError = error.localizedDescription
            selectedPath = nil
        }
    }

    private func makeInboxItem(url: URL, now: Date) -> InboxItem? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isUserImmutableKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }

        let fileName = url.lastPathComponent
        let extensionName = url.pathExtension.lowercased()
        let fileSize = UInt64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate ?? values.creationDate ?? now
        let pendingFile = model.pendingFiles.first { $0.path == url.path }
        let pending = pendingFile != nil && !(pendingFile?.ignored ?? false)
        let ignored = pendingFile?.ignored ?? false
        let defaults = InboxItem(
            id: url.path, path: url.path, fileName: fileName, extensionName: extensionName,
            fileSize: fileSize, modifiedAt: modifiedAt, kind: .skipped,
            statusTitle: "已跳过", reason: "暂时无法判断文件状态", remaining: nil,
            target: "", keyword: "", isPending: pending
        )

        if ignored {
            return with(item: defaults, statusTitle: "已忽略", reason: "你已选择暂不处理；文件仍保留在收件箱", kind: .skipped)
        }
        if fileName.hasPrefix(".") {
            return with(item: defaults, statusTitle: "已跳过", reason: "隐藏文件不会被处理")
        }
        let temporarySuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp"]
        if temporarySuffixes.contains(where: { fileName.lowercased().hasSuffix($0) }) {
            return with(item: defaults, statusTitle: "等待中", reason: "下载或写入尚未完成", kind: .waiting)
        }
        if model.config.excludedPaths.contains(where: { pathMatches(url, configuredPath: $0) }) {
            return with(item: defaults, statusTitle: "已排除", reason: "命中设置中的排除路径")
        }
        if values.isUserImmutable == true {
            return with(item: defaults, statusTitle: "已锁定", reason: "文件被系统标记为不可修改")
        }

        let supported = Set(model.config.supportedExtensions.map { $0.lowercased().hasPrefix(".") ? $0.lowercased() : ".\($0.lowercased())" })
        if !supported.contains(".\(extensionName)") {
            return with(item: defaults, statusTitle: "不支持", reason: "扩展名不在受支持类型中")
        }

        if model.config.retentionDays > 0 {
            let ageReference = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? modifiedAt
            let deadline = ageReference.addingTimeInterval(Double(model.config.retentionDays) * 86_400)
            if deadline > now {
                return with(item: defaults, statusTitle: "等待中", reason: "文件保留期尚未结束", remaining: deadline.timeIntervalSince(now), kind: .waiting)
            }
        }
        if model.config.recentModificationProtectionHours > 0 {
            let deadline = modifiedAt.addingTimeInterval(Double(model.config.recentModificationProtectionHours) * 3_600)
            if deadline > now {
                return with(item: defaults, statusTitle: "等待中", reason: "最近仍有修改，先等待文件稳定", remaining: deadline.timeIntervalSince(now), kind: .waiting)
            }
        }

        guard let rule = model.config.rules.first(where: { $0.matches(fileURL: url) }) else {
            return with(item: defaults, statusTitle: "未匹配", reason: "没有规则命中；可手动整理或编辑规则", kind: .unmatched)
        }
        guard !rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return with(item: defaults, statusTitle: "暂不处理", reason: "匹配规则没有目标文件夹", kind: .skipped)
        }
        let watchURL = URL(fileURLWithPath: NSString(string: model.config.watchFolder).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let targetURL = URL(fileURLWithPath: NSString(string: rule.target).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let watchPrefix = watchURL.path.hasSuffix("/") ? watchURL.path : watchURL.path + "/"
        if targetURL == watchURL || targetURL.path.hasPrefix(watchPrefix) {
            return with(item: defaults, statusTitle: "暂不处理", reason: "规则目标位于监听目录内，可能形成整理循环", target: rule.target, kind: .skipped)
        }
        var writableProbe = targetURL
        while !FileManager.default.fileExists(atPath: writableProbe.path), writableProbe.path != "/" {
            writableProbe.deleteLastPathComponent()
        }
        if !FileManager.default.isWritableFile(atPath: writableProbe.path) {
            return with(item: defaults, statusTitle: "暂不处理", reason: "规则目标目录不可写", target: rule.target, kind: .skipped)
        }
        let keyword = rule.keywords.first(where: { fileName.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) ?? ""
        let mode = OrganizationMode(rawValue: model.config.organizationMode) ?? .review
        switch mode {
        case .manual:
            return with(item: defaults, statusTitle: "可手动整理", reason: "命中“\(rule.name)”；当前方式不会自动移动", target: rule.target, keyword: keyword, kind: .actionable)
        case .review:
            return with(item: defaults, statusTitle: "等待确认", reason: "命中“\(rule.name)”；确认后才会移动", target: rule.target, keyword: keyword, kind: .actionable)
        case .automatic:
            return with(item: defaults, statusTitle: "自动整理", reason: "命中“\(rule.name)”；后台会按规则处理", target: rule.target, keyword: keyword, kind: .actionable)
        }
    }

    private func with(
        item: InboxItem,
        statusTitle: String,
        reason: String,
        remaining: TimeInterval? = nil,
        target: String = "",
        keyword: String = "",
        kind: InboxRowKind? = nil
    ) -> InboxItem {
        InboxItem(
            id: item.id, path: item.path, fileName: item.fileName, extensionName: item.extensionName,
            fileSize: item.fileSize, modifiedAt: item.modifiedAt, kind: kind ?? item.kind,
            statusTitle: statusTitle, reason: reason, remaining: remaining,
            target: target, keyword: keyword, isPending: item.isPending
        )
    }

    private func pathMatches(_ file: URL, configuredPath: String) -> Bool {
        let expanded = NSString(string: configuredPath).expandingTildeInPath
        let configured = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let candidate = file.standardizedFileURL.path
        let prefix = configured == "/" ? "/" : (configured.hasSuffix("/") ? configured : configured + "/")
        return candidate == configured || candidate.hasPrefix(prefix)
    }

    private func selectionBinding(for item: InboxItem) -> Binding<Bool> {
        Binding(
            get: { model.pendingFiles.first(where: { $0.path == item.path })?.selected ?? false },
            set: { value in
                guard let index = model.pendingFiles.firstIndex(where: { $0.path == item.path }) else { return }
                model.pendingFiles[index].selected = value
            }
        )
    }

    private func pendingFile(for item: InboxItem) -> PendingFile {
        PendingFile(path: item.path, fileName: item.fileName, keyword: item.keyword, target: item.target, selected: item.isPending)
    }

    private func nonEmptyPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func statusColor(for kind: InboxRowKind) -> Color {
        switch kind {
        case .actionable: return .green
        case .waiting: return .orange
        case .unmatched: return .blue
        case .skipped: return .secondary
        }
    }

    private func statusIcon(for kind: InboxRowKind) -> String {
        switch kind {
        case .actionable: return "checkmark.circle"
        case .waiting: return "clock"
        case .unmatched: return "questionmark.circle"
        case .skipped: return "slash.circle"
        }
    }

    private func remainingText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(interval)))
        if seconds >= 86_400 {
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            return hours == 0 ? "还需 \(days) 天" : "还需 \(days) 天 \(hours) 小时"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "还需 \(hours) 小时" : "还需 \(hours) 小时 \(minutes) 分"
        }
        return "还需 \(max(1, seconds / 60)) 分钟"
    }

    private func fileSizeText(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// 统一整理面板：目标选择与“是否保留规则”在一个地方完成，单个和批量操作完全一致。
struct PendingMoveSheet: View {
    @ObservedObject var model: AppModel
    let draft: PendingMoveDraft
    @State private var target: String
    @State private var saveAsRule = false
    @State private var keyword: String

    init(model: AppModel, draft: PendingMoveDraft) {
        self.model = model
        self.draft = draft
        _target = State(initialValue: draft.suggestedTarget)
        _keyword = State(initialValue: draft.suggestedKeyword)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("整理 \(draft.paths.count) 个文件").font(.title2.bold())
                Text(draft.fileNames.prefix(3).joined(separator: "、") + (draft.fileNames.count > 3 ? " 等" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            GroupBox("1. 移动到哪里") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("目标文件夹", text: $target)
                        Button("选择…") {
                            model.chooseFolder(current: target) { target = $0 }
                        }
                    }
                    if !model.recentTargetFolders.isEmpty {
                        HStack {
                            Text("最近目录").font(.caption).foregroundStyle(.secondary)
                            Menu("选择最近使用的目录") {
                                ForEach(model.recentTargetFolders, id: \.self) { value in
                                    Button(NSString(string: value).abbreviatingWithTildeInPath) { target = value }
                                }
                            }
                        }
                    }
                    Text(NSString(string: target).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(8)
            }

            GroupBox("2. 是否记住这次整理") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $saveAsRule) {
                        Text("只移动这一次").tag(false)
                        Text("保存自动规则，以后自动整理类似文件").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    if saveAsRule {
                        TextField("文件名关键词", text: $keyword)
                        Text("未来文件名包含“\(keyword.isEmpty ? "请填写关键词" : keyword)”且扩展名相同时，将自动移动到上面的目录。当前收件箱中预计匹配 \(model.matchingPendingCount(keyword: keyword)) 个。")
                            .font(.caption).foregroundStyle(.secondary)
                        if draft.paths.count > 1 && draft.suggestedKeyword.isEmpty {
                            Label("所选文件没有可靠的共同关键词，请确认后手动填写。", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.padding(8)
            }

            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Spacer()
                Button("取消") { model.pendingMoveDraft = nil }.keyboardShortcut(.cancelAction)
                Button(saveAsRule ? "移动并保存规则" : "移动") {
                    _ = model.confirmPendingMove(draft: draft, target: target, saveAsRule: saveAsRule, keyword: keyword)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (saveAsRule && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 570)
    }
}
