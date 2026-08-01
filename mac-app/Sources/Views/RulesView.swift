import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var showingPreview = false
    @State private var showingDiagnostics = false
    @State private var expandedRuleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                    VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("自动化规则（\(model.config.rules.count)）").font(.title2.bold())
                        if model.hasUnsavedChanges {
                            Text("未保存")
                                .font(.caption.bold()).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    Text("规则按顺序匹配。点击一条规则展开编辑，常用信息保持简洁。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("规则管理") {
                    Button("导出规则…") { model.exportRules() }
                    Button("导入规则…") { model.importRules() }
                    Button("复制给 AI 的规则需求模板") { model.copyAIRulePrompt() }
                    Divider()
                    Button("恢复上次备份") { model.restoreRuleBackup() }
                    Button("恢复默认规则") { model.restoreDefaultRules() }
                }
                Button("检查冲突") {
                    model.analyzeRuleConflicts()
                    showingDiagnostics = true
                }
                Button {
                    model.generateOrganizingPlan()
                    showingPreview = true
                } label: { Label("整理计划", systemImage: "checklist") }
                Button {
                    withAnimation {
                        model.config.rules.insert(
                            SorterRule(name: "新规则", keywords: ["新关键词"], target: "~/Documents/下载整理/新分类"),
                            at: 0
                        )
                        expandedRuleID = model.config.rules.first?.id
                    }
                    model.message = "已在顶部添加新规则；编辑后请点击“保存规则”"
                } label: { Label("添加规则", systemImage: "plus") }
            }

            List {
                ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { index, rule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("启用", isOn: Binding(
                                get: { rule.enabled },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].enabled = value
                                    }
                                }
                            )).toggleStyle(.switch).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).font(.headline)
                                Text(rule.summaryText)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                withAnimation { expandedRuleID = expandedRuleID == rule.id ? nil : rule.id }
                            } label: {
                                Image(systemName: expandedRuleID == rule.id ? "chevron.up" : "chevron.down")
                            }.buttonStyle(.borderless).help("展开或收起")
                            Button {
                                if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                    var copy = model.config.rules[current]
                                    copy.id = UUID()
                                    model.config.rules.insert(copy, at: current + 1)
                                }
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("复制规则")
                            Button(role: .destructive) {
                                model.config.rules.removeAll { $0.id == rule.id }
                                model.message = "规则已删除；点击“保存规则”后生效"
                            } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        if expandedRuleID == rule.id {
                        HStack {
                            Text("名称").frame(width: 72, alignment: .leading)
                            TextField("规则名称", text: Binding(
                                get: { rule.name },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].name = value
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("匹配方式").frame(width: 72, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { rule.matchMode },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].matchMode = value
                                    }
                                }
                            )) {
                                Text("任意关键词").tag("any")
                                Text("全部关键词").tag("all")
                            }.pickerStyle(.segmented).frame(maxWidth: 280)
                        }
                        HStack {
                            Text("关键词").frame(width: 72, alignment: .leading)
                            TextField("合同, invoice, 项目名称", text: Binding(
                                get: { rule.keywords.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].keywords = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("排除词").frame(width: 72, alignment: .leading)
                            TextField("模板, 草稿（可留空）", text: Binding(
                                get: { rule.excludeKeywords.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].excludeKeywords = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("扩展名").frame(width: 72, alignment: .leading)
                            TextField("pdf, docx（留空表示全部支持类型）", text: Binding(
                                get: { rule.extensions.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].extensions = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        DisclosureGroup("更多条件（可选）") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("名称正则").frame(width: 72, alignment: .leading)
                                    TextField(#"例如 ^项目.*\.pdf$"#, text: Binding(
                                        get: { rule.nameRegex },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].nameRegex = value
                                            }
                                        }
                                    ))
                                }
                                HStack {
                                    Text("文件大小").frame(width: 72, alignment: .leading)
                                    TextField("最小 MB", value: Binding(
                                        get: { rule.minimumSizeMB },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].minimumSizeMB = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    Text("至").foregroundStyle(.secondary)
                                    TextField("最大 MB", value: Binding(
                                        get: { rule.maximumSizeMB },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].maximumSizeMB = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                }
                                HStack {
                                    Text("修改时间").frame(width: 72, alignment: .leading)
                                    TextField("早于天数", value: Binding(
                                        get: { rule.modifiedOlderThanDays },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].modifiedOlderThanDays = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    TextField("最近天数", value: Binding(
                                        get: { rule.modifiedNewerThanDays },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].modifiedNewerThanDays = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    Text("留空表示不限").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("Finder 标签").frame(width: 72, alignment: .leading)
                                    TextField("工作, 重要（任一标签命中）", text: Binding(
                                        get: { rule.finderTags.joined(separator: ", ") },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].finderTags = splitRuleList(value)
                                            }
                                        }
                                    ))
                                }
                            }.padding(.top, 6)
                        }
                        HStack {
                            Text("目标").frame(width: 72, alignment: .leading)
                            TextField("~/Documents/资料库/分类", text: Binding(
                                get: { rule.target },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].target = value
                                    }
                                }
                            ))
                            Button("选择…") {
                                model.chooseFolder(current: rule.target) { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].target = value
                                    }
                                }
                            }
                        }
                        let issues = model.ruleValidationIssues(for: rule, at: index)
                        if !issues.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(issues) { issue in
                                    Label(issue.text, systemImage: issue.isError ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(issue.isError ? .red : .orange)
                                }
                            }
                            .padding(.leading, 72)
                        }
                        }
                    }
                    .padding(.vertical, 8)
                    .opacity(rule.enabled ? 1 : 0.58)
                }
                .onMove { source, destination in model.config.rules.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.inset)

            HStack {
                Button("保存规则") { _ = model.saveCurrentConfiguration() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !model.hasUnsavedChanges)
                if model.hasUnsavedChanges {
                    Text("按 ⌘S 保存修改").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.message).font(.callout).foregroundStyle(.secondary)
            }

            GroupBox("文件名测试") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("输入完整文件名，例如 Samsung_S95F_报价单.pdf", text: $model.ruleTestFileName)
                        Button("测试") { model.testRuleMatch() }
                    }
                    Text(model.ruleTestResult).font(.callout).textSelection(.enabled)
                }.padding(6)
            }

            if showingDiagnostics {
                GroupBox("规则检查结果") {
                    HStack(alignment: .top) {
                        Text(model.ruleDiagnostics).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("关闭") { showingDiagnostics = false }
                    }.padding(6)
                }
            }
        }
        .padding(22)
        .sheet(isPresented: $showingPreview) {
            OrganizingPlanView(model: model, isPresented: $showingPreview)
        }
    }
}

