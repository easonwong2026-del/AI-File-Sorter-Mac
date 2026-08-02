import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

struct StatusCard: View {
    @ObservedObject var model: AppModel

    private var stateColor: Color {
        switch model.runtimeState {
        case .running, .awaitingConfirmation: return .green
        case .scanning, .organizing: return .blue
        case .temporarilyPaused: return .orange
        case .stopped, .error: return .orange
        }
    }

    private var stateIcon: String {
        switch model.runtimeState {
        case .running: return "checkmark.circle.fill"
        case .awaitingConfirmation: return "checkmark.circle.fill"
        case .scanning: return "magnifyingglass.circle.fill"
        case .organizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .temporarilyPaused: return "pause.circle.fill"
        case .stopped: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: stateIcon)
                .font(.system(size: 34))
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("后台服务：\(model.automationEnabled ? "已启用" : "未启用")")
                    .font(.title3.bold())
                Text(model.serviceStatus.title).font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("整理方式：\(OrganizationMode(rawValue: model.config.organizationMode)?.title ?? "需要检查") · \(model.serviceStatus.detail)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Toggle("后台整理服务", isOn: Binding(
                get: { model.automationEnabled },
                set: { enabled in enabled ? model.installAndStart() : model.stopAutomation() }
            ))
            .toggleStyle(.switch)
            .disabled(model.busy)
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

// 兼容 macOS 13 的轻量空状态，避免引入仅 macOS 14 可用的 ContentUnavailableView。
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var detail = ""

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
