import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct OrganizingPlanView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    private var selectedItems: [OrganizingPlanItem] { model.organizingPlan.filter(\.selected) }

    private var selectedSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(selectedItems.reduce(0) { $0 + $1.fileSize }, UInt64(Int64.max))), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("整理计划").font(.title2.bold())
                    Text("确认来源、规则和目标后再执行；取消不会移动任何文件。")
                        .foregroundStyle(.secondary)
                    Text("\(model.organizingPlan.count) 项 · 已选 \(selectedItems.count) 项 · \(selectedSizeText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") {
                    for index in model.organizingPlan.indices where model.organizingPlan[index].canSelect {
                        model.organizingPlan[index].selected = true
                    }
                }
                Button("全不选") {
                    for index in model.organizingPlan.indices { model.organizingPlan[index].selected = false }
                }
            }

            if model.organizingPlan.isEmpty {
                EmptyStateView(title: "没有可执行项目", systemImage: "checkmark.circle", detail: "当前文件没有命中启用的规则。")
            } else {
                List {
                    ForEach($model.organizingPlan) { $item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: $item.selected).labelsHidden()
                                .disabled(!item.canSelect)
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.fileName).font(.headline).lineLimit(1)
                                    Text(item.ruleName).font(.caption)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text("→ \(NSString(string: item.destinationPath).abbreviatingWithTildeInPath)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("文件年龄 \(item.ageDays) 天 · \(ByteCountFormatter.string(fromByteCount: Int64(min(item.fileSize, UInt64(Int64.max))), countStyle: .file)) · 修改于 \(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(item.status).font(.caption)
                                .foregroundStyle(item.canSelect ? Color.secondary : Color.orange)
                        }.padding(.vertical, 5)
                    }
                }.listStyle(.inset)
            }

            HStack {
                Text("已选择 \(selectedItems.count) 项 · \(selectedSizeText)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { isPresented = false }
                Button("确认整理") {
                    model.executeOrganizingPlan()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.organizingPlan.contains(where: \.selected))
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 540)
        .onDisappear { if !model.busy { model.organizingPlan = [] } }
    }
}
