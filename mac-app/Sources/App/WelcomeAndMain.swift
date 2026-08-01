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
                    Text("先处理待分类文件，再把重复动作变成自动化规则。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Label("“待分类”支持一次性移动，也能顺手建立长期规则。", systemImage: "1.circle.fill")
                Label("内置规则是图片、视频、压缩包等通用方案，可随时修改。", systemImage: "2.circle.fill")
                Label("也可以让外部 AI 根据你的目录生成 JSON，再从规则页导入。", systemImage: "3.circle.fill")
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
            Text(model.runtimeState.title)
            Text((OrganizationMode(rawValue: model.config.organizationMode) ?? .review).title)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("立即扫描（不移动）") { model.scanOnly() }
                .disabled(model.busy)
            Button("立即整理现有文件") { model.sortExistingNow() }
                .disabled(model.busy)
            if model.automationEnabled {
                Button("停止整理") { model.stopAutomation() }
            } else {
                Button("开始整理") { model.installAndStart() }
            }
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("打开 Downloads") { model.openDownloadsFolder() }
            Divider()
            Button("退出控制面板") { NSApp.terminate(nil) }
        }
    }
}

