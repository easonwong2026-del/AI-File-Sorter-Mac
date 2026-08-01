import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

enum SidebarSection: String, Hashable {
    case pending, rules, activity, settings
}

// 2.3 使用稳定的侧边栏信息架构，把日常整理与低频设置明确分开。
struct SidebarContentView: View {
    @ObservedObject var model: AppModel
    @State private var section: SidebarSection? = .pending
    @State private var requestedSection: SidebarSection?
    @State private var showingNavigationConfirmation = false
    @AppStorage("didShowWelcomeV23") private var didShowWelcome = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { section },
                    set: { requested in
                        guard let requested, requested != section else { return }
                        if model.hasUnsavedChanges {
                            requestedSection = requested
                            showingNavigationConfirmation = true
                        } else {
                            section = requested
                        }
                    }
                )) {
                    Section("整理") {
                        Label {
                            HStack {
                                Text("待分类")
                                Spacer()
                                if !model.pendingFiles.isEmpty {
                                    Text("\(model.pendingFiles.count)")
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        } icon: { Image(systemName: "tray.full") }
                        .tag(SidebarSection.pending)
                        Label("自动化规则", systemImage: "list.bullet.rectangle").tag(SidebarSection.rules)
                        Label("整理记录", systemImage: "clock.arrow.circlepath").tag(SidebarSection.activity)
                    }
                    Section("应用") {
                        Label("设置", systemImage: "gearshape").tag(SidebarSection.settings)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.automationEnabled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.runtimeState.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            switch section ?? .pending {
            case .pending: PendingInboxView(model: model)
            case .rules: RulesView(model: model)
            case .activity: HistoryView(model: model)
            case .settings: OverviewView(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: Binding(
            get: { !didShowWelcome },
            set: { if !$0 { didShowWelcome = true } }
        )) {
            WelcomeView { didShowWelcome = true }
        }
        .sheet(isPresented: $model.showOrganizingPlan) {
            OrganizingPlanView(model: model, isPresented: $model.showOrganizingPlan)
        }
        .alert("未保存的修改", isPresented: $showingNavigationConfirmation) {
            Button("保存并继续") {
                if model.saveCurrentConfiguration() { section = requestedSection }
                requestedSection = nil
            }
            Button("放弃修改", role: .destructive) {
                model.discardUnsavedChanges()
                section = requestedSection
                requestedSection = nil
            }
            Button("取消", role: .cancel) { requestedSection = nil }
        } message: {
            Text("切换页面前请保存设置，或放弃本次未保存的修改。")
        }
        .alert("未保存的修改", isPresented: $model.showQuitConfirmation) {
            Button("保存并退出") {
                if model.saveCurrentConfiguration() { NSApp.reply(toApplicationShouldTerminate: true) }
                else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
            Button("放弃修改", role: .destructive) {
                model.discardUnsavedChanges()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            Button("取消", role: .cancel) { NSApp.reply(toApplicationShouldTerminate: false) }
        } message: {
            Text("退出前请保存设置，或放弃本次未保存的修改。")
        }
    }
}

// 首次引导只解释核心工作流，避免把高级设置一次性塞给新用户。

