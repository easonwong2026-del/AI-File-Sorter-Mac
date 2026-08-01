import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct PendingInboxView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPath: String?
    @State private var showingPlan = false

    private var selectedCount: Int { model.pendingFiles.count(where: \.selected) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待分类").font(.title2.bold())
                        HStack(spacing: 7) {
                            Text("\(model.pendingFiles.count) 个文件").font(.caption).foregroundStyle(.secondary)
                            if selectedCount > 0 {
                                Text("已选 \(selectedCount) 项")
                                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    Spacer()
                    Button("整理计划") {
                        model.generateOrganizingPlan()
                        showingPlan = true
                    }
                    Button { model.refreshPendingFiles() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新")
                }.padding(16)
                Divider()
                if model.pendingFiles.isEmpty {
                    EmptyStateView(title: "已整理完毕", systemImage: "checkmark.circle", detail: "新的未匹配文件会出现在这里。")
                } else {
                    List(selection: $selectedPath) {
                        ForEach($model.pendingFiles) { $item in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $item.selected).labelsHidden()
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.fileName).lineLimit(1)
                                    Text(item.keyword).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(item.path)
                        }
                    }.listStyle(.sidebar)
                }
                Divider()
                HStack {
                    Text(selectedCount == 0 ? "勾选文件后可批量处理" : "将处理 \(selectedCount) 个所选文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("忽略 \(selectedCount) 项") { model.ignoreSelectedPending() }
                        .help("忽略所选的 \(selectedCount) 个文件")
                        .disabled(selectedCount == 0 || model.busy)
                    Button("整理 \(selectedCount) 项…") { model.moveSelectedOnce() }
                        .buttonStyle(.borderedProminent)
                        .help("整理所选的 \(selectedCount) 个文件")
                        .disabled(selectedCount == 0 || model.busy)
                }
                .padding(12)
                if model.busy {
                    ProgressView().controlSize(.small).padding(.bottom, 4)
                }
                Text(model.message)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .frame(minWidth: 270, idealWidth: 310)

            pendingDetail
        }
        .onAppear { if selectedPath == nil { selectedPath = model.pendingFiles.first?.path } }
        .onChange(of: model.pendingFiles.map(\.path)) { paths in
            if selectedPath == nil || !paths.contains(selectedPath ?? "") {
                selectedPath = paths.first
            }
        }
        .sheet(item: $model.pendingMoveDraft) { draft in
            PendingMoveSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $showingPlan) {
            OrganizingPlanView(model: model, isPresented: $showingPlan)
        }
    }

    @ViewBuilder private var pendingDetail: some View {
        if let path = selectedPath, let index = model.pendingFiles.firstIndex(where: { $0.path == path }) {
            let item = model.pendingFiles[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28)).foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.fileName).font(.title2.bold()).textSelection(.enabled)
                            Text(NSString(string: item.path).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Toggle("加入所选", isOn: Binding(
                            get: { model.pendingFiles[index].selected },
                            set: { model.pendingFiles[index].selected = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .help("将当前文件加入底部的批量整理或忽略操作")
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("建议整理到", systemImage: "folder")
                            .font(.headline)
                        Text(NSString(string: item.target).abbreviatingWithTildeInPath)
                            .font(.title3.weight(.medium)).textSelection(.enabled).lineLimit(2)
                        Text("整理时可改用最近目录或 Finder 选择其他位置，并可选择保存为自动规则。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

                    Divider()
                    HStack {
                        Button("快速预览") { model.quickLookPending(item) }
                            .keyboardShortcut(.space, modifiers: [])
                        Button("在 Finder 显示") { model.revealPending(item) }
                    }
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
            }
        } else {
            EmptyStateView(title: "选择一个文件", systemImage: "doc.text.magnifyingglass", detail: "查看建议位置或建立自动规则。")
        }
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
                        Text("未来文件名包含“\(keyword.isEmpty ? "请填写关键词" : keyword)”且扩展名相同时，将自动移动到上面的目录。当前待分类中预计匹配 \(model.matchingPendingCount(keyword: keyword)) 个。")
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

