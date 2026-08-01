import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct LogsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行日志").font(.title2.bold())
                Spacer()
                Button("打开日志文件夹") { model.openLogsFolder() }
                Button("刷新") { model.refreshLog() }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(model.logText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("打开 Downloads") { model.openDownloadsFolder() }
                Spacer()
                Text(model.runtimeState.title).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .onAppear { model.refreshLog() }
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var showingLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("整理记录（\(model.historyRecords.count)）").font(.title2.bold())
                    Text("最多保留最近 500 条移动记录；撤销时如原位置已有同名文件，会自动避免覆盖。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即整理") { model.sortExistingNow() }.disabled(model.busy)
                Button("撤销最近批次") { model.undoLatestBatch() }
                    .disabled(model.busy || model.latestUndoableBatchID == nil)
                Button("技术日志") { showingLogs = true }
                Button("刷新") { model.refreshHistory() }
            }
            if model.historyRecords.isEmpty {
                EmptyStateView(title: "暂无整理历史", systemImage: "clock.arrow.circlepath")
            } else {
                List(model.historyRecords) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(URL(fileURLWithPath: record.destinationPath).lastPathComponent).font(.headline)
                            Text(record.reason).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            if record.undone { Text("已撤销").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("原位置：\(NSString(string: record.originalPath).abbreviatingWithTildeInPath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("目标：\(NSString(string: record.destinationPath).abbreviatingWithTildeInPath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Button("在 Finder 中显示") { model.revealHistoryFile(record) }
                            Button("撤销") { model.undoMove(record) }
                                .disabled(record.undone || model.busy || !FileManager.default.fileExists(atPath: record.destinationPath))
                        }
                    }
                    .padding(.vertical, 7)
                }
                .listStyle(.inset)
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(22)
        .onAppear { model.refreshHistory() }
        .sheet(isPresented: $showingLogs) {
            LogsView(model: model).frame(minWidth: 760, minHeight: 520)
        }
    }
}

