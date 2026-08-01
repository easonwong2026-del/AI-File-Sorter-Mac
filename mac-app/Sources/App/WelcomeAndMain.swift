import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct WelcomeView: View {
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 42)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 AI File Sorter").font(.title.bold())
                    Text("先查看收件箱，再选择适合你的整理方式。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Label("收件箱会列出监听目录第一层的普通文件，并说明可整理、等待、跳过或未匹配的原因。", systemImage: "1.circle.fill")
                Label("你可以选择只提供整理建议、整理前确认，或自动整理；三种方式不会改变收件箱展示。", systemImage: "2.circle.fill")
                Label("整理前可快速预览文件或在 Finder 中定位；已有文件不会被覆盖。", systemImage: "3.circle.fill")
            }

            GroupBox {
                Label("应用默认不上传文件名、目录或内容，也不会自动调用任何 AI 服务。", systemImage: "hand.raised.fill")
                    .font(.callout).foregroundStyle(.secondary).padding(6)
            }

            HStack {
                Spacer()
                Button("开始使用") { finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 610)
    }
}

@main
struct AIFileSorterApplication: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup("AI File Sorter") {
            SidebarContentView(model: model)
                .onAppear { applicationDelegate.model = model }
        }
            .windowStyle(.titleBar)
            .defaultSize(width: 900, height: 700)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandGroup(replacing: .saveItem) {
                    Button("保存当前设置") { _ = model.saveCurrentConfiguration() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.hasUnsavedChanges)
                }
            }

        MenuBarExtra("AI File Sorter", systemImage: model.automationEnabled ? "folder.fill.badge.checkmark" : "folder.badge.gearshape") {
            Text(model.serviceStatus.title)
            Text("收件箱：\(model.inboxFileCount) 个文件")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("立即扫描") { model.scanOnly() }
                .disabled(model.busy)
            if model.automationEnabled {
                Button("暂停自动整理") { model.stopAutomation() }
            } else {
                Button("开始自动整理") { model.installAndStart() }
            }
            Button("打开监听文件夹") { model.openDownloadsFolder() }
            Button("打开应用") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}
