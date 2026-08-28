import AppKit
import SwiftUI

@main
struct QumoRunnerApp: App {
    @StateObject private var store = RunnerAppStore()
    @StateObject private var launchAgent = LaunchAgentManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(launchAgent)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    if store.autoStartEnabled,
                       launchAgent.status != .enabled,
                       launchAgent.status != .requiresApproval {
                        _ = await launchAgent.register()
                    }
                    store.start()
                }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("关闭窗口") { NSApp.keyWindow?.close() }
                    .keyboardShortcut("q", modifiers: [.command])
                Divider()
                Button("停止服务并退出…") { stopServiceAndQuit() }
            }
            CommandMenu("Runner") {
                Button(store.snapshot.serviceState == .paused ? "继续领取新任务" : "暂停领取新任务") {
                    Task { await store.setPaused(store.snapshot.serviceState != .paused) }
                }
                Button("立即刷新") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(launchAgent)
                .frame(width: 720, height: 560)
        }
    }

    private func stopServiceAndQuit() {
        let alert = NSAlert()
        alert.messageText = "停止后台服务并退出？"
        alert.informativeText = "后台将不再领取新任务。正在运行的远端任务可能需要人工确认；仅关闭窗口不会停止服务。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "停止服务并退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let notification = Task { _ = try? await RunnerAgentClient.shared.command("prepare_shutdown") }
            try? await Task.sleep(for: .milliseconds(300))
            notification.cancel()
            _ = await launchAgent.unregister()
            NSApp.terminate(nil)
        }
    }
}
