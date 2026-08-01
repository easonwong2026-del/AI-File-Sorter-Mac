import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var advancedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("设置").font(.largeTitle.bold())
                        if model.hasUnsavedChanges {
                            Text("未保存")
                                .font(.caption.bold()).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    Text("用最少的设置决定文件放在哪里、什么时候整理。")
                        .foregroundStyle(.secondary)
                }

                StatusCard(model: model)

                GroupBox("核心设置") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("监听文件夹").frame(width: 110, alignment: .leading)
                            TextField("例如 ~/Downloads", text: Binding(
                                get: { model.config.watchFolder },
                                set: { model.config.watchFolder = $0 }
                            ))
                            Button("选择…") {
                                model.chooseFolder(current: model.config.watchFolder) { model.config.watchFolder = $0 }
                            }
                        }

                        Picker("整理方式", selection: Binding(
                            get: { model.config.organizationMode },
                            set: { model.config.organizationMode = $0 }
                        )) {
                            ForEach(OrganizationMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Text((OrganizationMode(rawValue: model.config.organizationMode) ?? .review).detail)
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)

                        Toggle("自动重命名", isOn: Binding(
                            get: { model.config.rename.enabled },
                            set: { model.config.rename.enabled = $0 }
                        ))
                        Text(model.config.rename.enabled
                             ? "整理时会按高级设置中的模板生成新文件名，不会覆盖已有文件。"
                             : "保持原文件名；如果目标位置重名，系统会自动避免覆盖。")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                    }
                    .padding(10)
                }

                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox("安全与调度") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("文件保留时间").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.retentionDays },
                                        set: { model.config.retentionDays = max(0, $0) }
                                    ), in: 0...365) {
                                        let retentionLabel = model.config.retentionDays == 0
                                            ? "不延迟"
                                            : "\(model.config.retentionDays) 天"
                                        Text(retentionLabel).monospacedDigit()
                                    }
                                    Text("新文件先保留，0 表示关闭").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("最近修改保护").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.recentModificationProtectionHours },
                                        set: { model.config.recentModificationProtectionHours = max(0, $0) }
                                    ), in: 0...720) {
                                        Text(model.config.recentModificationProtectionHours == 0
                                             ? "不保护"
                                             : "\(model.config.recentModificationProtectionHours) 小时")
                                            .monospacedDigit()
                                    }
                                    Text("防止仍在编辑的文件被处理").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("自动扫描间隔").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.automaticScanIntervalHours },
                                        set: { model.config.automaticScanIntervalHours = max(0, $0) }
                                    ), in: 0...168) {
                                        Text(model.config.automaticScanIntervalHours == 0
                                             ? "仅响应目录变化"
                                             : "每 \(model.config.automaticScanIntervalHours) 小时")
                                            .monospacedDigit()
                                    }
                                    Text("用于定期重新检查达到保留时间的文件")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("排除路径").frame(width: 110, alignment: .leading)
                                    TextField("多个路径用逗号分隔，例如 ~/Downloads/保留", text: Binding(
                                        get: { model.config.excludedPaths.joined(separator: ", ") },
                                        set: { model.config.excludedPaths = splitRuleList($0) }
                                    ))
                                }
                                Toggle("第一次启用时也整理监听目录中已有的文件", isOn: Binding(
                                    get: { model.config.processExistingOnFirstStart },
                                    set: { model.config.processExistingOnFirstStart = $0 }
                                ))
                                Text("目标文件夹不能位于监听文件夹内；隐藏文件和临时下载文件始终跳过。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(8)
                        }

                        GroupBox("重命名详细设置") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("重命名模板").frame(width: 110, alignment: .leading)
                                    TextField("{date}_{original_name}", text: Binding(
                                        get: { model.config.rename.template },
                                        set: { model.config.rename.template = $0 }
                                    ))
                                }
                                HStack {
                                    Text("日期格式").frame(width: 110, alignment: .leading)
                                    TextField("%Y-%m-%d", text: Binding(
                                        get: { model.config.rename.dateFormat },
                                        set: { model.config.rename.dateFormat = $0 }
                                    ))
                                    Text("预览：\(model.renamedFileName("示例文件.pdf"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("可用变量：{date}、{original_name}、{extension}、{category}、{keyword}")
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                            }
                            .padding(8)
                        }

                        GroupBox("移动与文件安全") {
                            VStack(alignment: .leading, spacing: 9) {
                                Picker("移动方式", selection: Binding(
                                    get: { model.config.moveMethod },
                                    set: { model.config.moveMethod = $0 }
                                )) {
                                    Text("原生文件系统（推荐）").tag("native")
                                    Text("Finder / AppleScript").tag("finder")
                                }
                                .pickerStyle(.segmented)
                                HStack {
                                    Text("文件稳定等待")
                                    Slider(value: Binding(
                                        get: { model.config.stableSeconds },
                                        set: { model.config.stableSeconds = $0 }
                                    ), in: 1...15, step: 1)
                                    Text("\(Int(model.config.stableSeconds)) 秒")
                                        .monospacedDigit().frame(width: 46, alignment: .trailing)
                                }
                            }
                            .padding(8)
                        }

                        GroupBox("环境与权限") {
                            HStack(alignment: .top) {
                                Text(model.healthReport).font(.callout).textSelection(.enabled)
                                Spacer()
                                Button("开始检查") { model.runHealthCheck() }
                            }
                            .padding(8)
                        }

                    }
                    .padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高级设置").font(.headline)
                        Text("保留期、排除路径、重命名模板、移动方式和权限检查")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button("保存设置") { _ = model.saveCurrentConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.hasUnsavedChanges)
                    if model.hasUnsavedChanges {
                        Text("按 ⌘S 保存修改").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(22)
        }
    }
}
