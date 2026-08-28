import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @State private var level: LogLevel?
    @State private var jobID = "全部任务"
    @State private var profileRef = "全部账号"
    @State private var query = ""

    private var filteredLogs: [RunnerLogEntry] {
        store.snapshot.logs.filter { entry in
            (level == nil || entry.level == level) &&
            (jobID == "全部任务" || entry.jobID == jobID) &&
            (profileRef == "全部账号" || entry.profileRef == profileRef) &&
            (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }
    private var jobIDs: [String] { ["全部任务"] + Array(Set(store.snapshot.logs.compactMap(\.jobID))).sorted() }
    private var profileRefs: [String] { ["全部账号"] + Array(Set(store.snapshot.logs.compactMap(\.profileRef))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("级别", selection: $level) {
                    Text("全部级别").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 135)
                Picker("任务", selection: $jobID) { ForEach(jobIDs, id: \.self) { Text($0).tag($0) } }.frame(width: 165)
                Picker("账号", selection: $profileRef) { ForEach(profileRefs, id: \.self) { Text($0).tag($0) } }.frame(width: 165)
                Spacer()
                Button { store.exportDiagnostics() } label: { Label("导出诊断 ZIP", systemImage: "square.and.arrow.up") }
            }
            .padding(14)
            Divider()
            if store.snapshot.logs.isEmpty {
                EmptyStateView(icon: "doc.text", title: "暂无日志", message: "后台服务开始运行后，脱敏日志会显示在这里。")
            } else if filteredLogs.isEmpty {
                EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "没有匹配的日志", message: "请调整任务、账号、级别或搜索条件。")
            } else {
                Table(filteredLogs) {
                    TableColumn("时间") { Text($0.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(80)
                    TableColumn("级别") { StateBadge(title: $0.level.title, color: $0.level.color) }.width(92)
                    TableColumn("账号") { Text($0.profileRef ?? "—").font(.caption.monospaced()).lineLimit(1) }.width(min: 90, ideal: 130)
                    TableColumn("任务") { Text($0.jobID ?? "—").font(.caption.monospaced()).lineLimit(1) }.width(min: 90, ideal: 130)
                    TableColumn("消息") { Text(DiagnosticExporter.redact($0.message)).textSelection(.enabled).lineLimit(3) }.width(min: 260, ideal: 500)
                }
            }
        }
        .navigationTitle("日志")
        .searchable(text: $query, prompt: "搜索脱敏日志")
    }
}
