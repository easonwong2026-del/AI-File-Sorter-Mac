import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

// AI File Sorter 原生 macOS 前端：管理规则、启动状态、存量整理和日志。

import AppKit
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var previewURL: URL?

    func show(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path), let panel = QLPreviewPanel.shared() else { return }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        model.showQuitConfirmation = true
        return .terminateLater
    }
}

