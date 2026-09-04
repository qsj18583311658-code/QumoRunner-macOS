import AppKit
import ServiceManagement
import SwiftUI
import RunnerCore

struct SettingsView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @EnvironmentObject private var launchAgent: LaunchAgentManager
    @State private var serverURL = ""
    @State private var pairingCode = ""
    @State private var startupEnabled = false
    @State private var showUnpairConfirmation = false

    var body: some View {
        ScrollView {
            Form {
                Section("服务器配对") {
                    if store.runnerID.isEmpty {
                        TextField("Canvas API 地址", text: $serverURL, prompt: Text("https://canvas.example.com"))
                        SecureField("10 分钟有效的单次配对码", text: $pairingCode)
                        HStack {
                            Button("配对此 Mac") { Task { await pair() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.isPerformingOperation || serverURL.isEmpty || pairingCode.isEmpty)
                            if store.isPerformingOperation { ProgressView().controlSize(.small) }
                        }
                    } else {
                        LabeledContent("服务器", value: store.savedServerURL)
                        LabeledContent("Runner ID", value: store.runnerID)
                        LabeledContent("设备 Token", value: "已存入登录 Keychain")
                        Button("移除此设备的本地配对…", role: .destructive) { showUnpairConfirmation = true }
                    }
                }

                Section("后台服务") {
                    Toggle("用户登录后自动启动", isOn: $startupEnabled)
                        .onChange(of: startupEnabled) { _, enabled in Task { await setStartup(enabled) } }
                    LabeledContent("LaunchAgent", value: launchAgent.statusText)
                    if launchAgent.status == .requiresApproval {
                        HStack {
                            Text("请在“登录项与扩展”中允许 Qumo Runner。 ").foregroundStyle(.orange)
                            Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    if let error = launchAgent.lastError { Text(error).foregroundStyle(.red).font(.caption) }
                    Text("关闭窗口不会停止后台服务。只有菜单中的“停止服务并退出”会注销 LaunchAgent。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("执行") {
                    Stepper(value: Binding(get: { store.concurrencyLimit }, set: { value in Task { await store.updateConcurrency(value) } }), in: 1...8) {
                        LabeledContent("全局 Profile 并发", value: "\(store.concurrencyLimit)")
                    }
                    Text("每个 Profile 的并发固定为 1；全局上限可在 1–8 之间调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("数据与通知") {
                    LabeledContent("数据目录") {
                        HStack {
                            Text(store.dataDirectory).lineLimit(1).truncationMode(.middle)
                            Button("在 Finder 中显示", action: revealDataDirectory)
                        }
                    }
                    Toggle("CLI 更新、离线、登录/积分异常与待确认时通知", isOn: $store.notificationsEnabled)
                        .onChange(of: store.notificationsEnabled) { _, enabled in
                            if enabled { Task { _ = await RunnerNotificationService.shared.requestAuthorization() } }
                        }
                }

                Section("LibTV 与诊断") {
                    LabeledContent("当前使用版本", value: store.snapshot.libTVVersion ?? "未检测")
                    CLIUpdateView()
                    LabeledContent("完整性", value: store.snapshot.libTVVerified ? "版本、SHA-256、代码签名已通过" : "未通过或尚未校验")
                    HStack {
                        Button("运行 LibTV 诊断") { Task { await store.runLibTVDiagnostic() } }
                        Button("导出诊断 ZIP") { store.exportDiagnostics() }
                    }
                    Text("诊断包会脱敏 Token、Authorization、密码和密钥字段，不包含 LibTV credentials.json。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        }
        .navigationTitle("设置")
        .onAppear {
            serverURL = store.savedServerURL
            launchAgent.refresh()
            startupEnabled = launchAgent.isRegistered
        }
        .confirmationDialog("移除本地配对？", isPresented: $showUnpairConfirmation) {
            Button("移除 Keychain Token", role: .destructive) { removeLocalPairing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只移除本机保存的设备 Token，不会替代服务端撤销。管理员仍应在 Canvas 撤销该 Runner。")
        }
    }

    private func pair() async {
        if await store.pair(serverURLText: serverURL, pairingCode: pairingCode) { pairingCode = "" }
    }

    private func setStartup(_ enabled: Bool) async {
        let success = enabled ? await launchAgent.register() : await launchAgent.unregister()
        if success { store.autoStartEnabled = enabled }
        else { startupEnabled = launchAgent.isRegistered }
    }

    private func revealDataDirectory() {
        let url = URL(fileURLWithPath: store.dataDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeLocalPairing() {
        do {
            try KeychainStore().deleteDeviceToken(runnerID: store.runnerID)
            try? RunnerConfigurationStore().remove()
            store.runnerID = ""
            store.savedServerURL = ""
            serverURL = ""
            store.operationMessage = "本地设备 Token 已移除。请同时在 Canvas 管理端撤销此 Runner。"
            Task { _ = try? await RunnerAgentClient.shared.command("reload_pairing") }
        } catch { store.operationMessage = error.localizedDescription }
    }
}

struct CLIUpdateView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @State private var specifiedVersion = ""
    var compact = false
    private var update: LibTVUpdateStatus? { store.snapshot.libTVUpdate }
    private var available: String? { update?.availableVersion(current: store.snapshot.libTVVersion) }
    private var busy: Bool { update?.isBusy == true || store.isPerformingOperation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let available {
                Label("LibTV CLI 可更新：\(store.snapshot.libTVVersion ?? "未知") → \(available)", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                Text("旧 CLI 可能无法适配 LibTV 服务端变化，请及时更新。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !compact {
                Text("官方更新通道：\(update?.channelVersion ?? "尚未检查")")
                HStack {
                    Link("LibTV 官网", destination: LibTVUpdateClient.websiteURL)
                    Text("官网版本：\(update?.websiteVersion ?? "未公开") · 下载清单：\(update?.manifestVersion ?? "未检查")")
                }.font(.caption)
                Text(update?.sourceNote ?? "从 LibTV 官网和官方安装清单检查更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = update?.message {
                HStack {
                    if update?.isBusy == true { ProgressView().controlSize(.small) }
                    Text(message).font(.callout).textSelection(.enabled)
                        .foregroundStyle(update?.phase == "failed" ? Color.red : Color.secondary)
                }
            }
            if let error = update?.checkError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("检查 CLI 更新") { Task { await store.checkCLIUpdate() } }.disabled(busy)
                if let available {
                    Button("更新到 \(available)") { Task { await store.updateCLI(version: available) } }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
                if !compact, let previous = update?.previousVersion {
                    Button("回滚到 \(previous)") { Task { await store.rollbackCLI() } }.disabled(busy)
                }
            }
            if !compact {
                Toggle("夜间自动更新 CLI（03:00–04:00）", isOn: Binding(
                    get: { update?.nightlyEnabled ?? true },
                    set: { value in Task { await store.setCLINightly(value) } }
                ))
                Text("按本机时区执行；有任务则推迟，每晚最多尝试一次，错过窗口顺延下一晚。")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = update?.scheduleNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let checked = update?.checkedAt {
                    Text("上次成功检查：\(checked.formatted(date: .abbreviated, time: .shortened)) · 每 6 小时自动检查")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("指定官方版本更新") {
                    Text("官方清单滞后时，可填写已发布版本号。Runner 仅从官方站点下载，并验证签名和命令兼容性。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("版本号，例如 1.1.3", text: $specifiedVersion).frame(maxWidth: 220)
                        Button("下载并更新") {
                            Task { await store.updateCLI(version: specifiedVersion.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }.disabled(busy || specifiedVersion.isEmpty)
                    }
                }
                Text("先下载再暂停领取，任务结束后切换；模型参数验证完成才恢复领取。下载最多 5 分钟，更新最多 45 分钟，失败或超时自动恢复原版；恢复异常保持暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
