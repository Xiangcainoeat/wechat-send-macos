import AppKit
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case tasks
    case logs
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: return "发送任务"
        case .logs: return "执行记录"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .tasks: return "clock.badge.checkmark"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .tasks

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                BrandHeader()
                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            switch selection ?? .tasks {
            case .tasks: TaskListView()
            case .logs: LogView()
            case .settings: SettingsView()
            }
        }
        .tint(Color(red: 0.12, green: 0.48, blue: 0.33))
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(red: 0.12, green: 0.48, blue: 0.33))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("微信发送")
                    .font(.system(size: 15, weight: .semibold))
                Text("本机微信计划任务 · v1.0.4")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }
}

private struct TaskListView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var scheduler: TaskScheduler
    @EnvironmentObject private var weChatStatus: WeChatStatusMonitor
    @State private var showingNewTask = false
    @State private var editingTask: SendTask?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "发送任务",
                subtitle: "任务只保存在这台 Mac；到点后控制已登录的微信。"
            ) {
                Button {
                    showingNewTask = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            WeChatStatusBar()

            Divider()

            if store.tasks.isEmpty {
                ContentUnavailableView {
                    Label("还没有发送任务", systemImage: "clock")
                } description: {
                    Text("建立一个单次任务，先用文件传输助手测试。")
                } actions: {
                    Button("新建任务") { showingNewTask = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.tasks) { task in
                            TaskRow(task: task) {
                                editingTask = task
                            } run: {
                                scheduler.runNow(task)
                            } retry: {
                                store.retry(task)
                            } delete: {
                                store.delete(task)
                            }
                            Divider().padding(.leading, 76)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            SafetyBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNewTask) {
            TaskEditorView()
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(existingTask: task)
        }
    }
}

private struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var scheduler: TaskScheduler
    let task: SendTask
    let edit: () -> Void
    let run: () -> Void
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(stateColor.opacity(0.12))
                Image(systemName: task.filePaths.isEmpty ? "text.bubble" : "paperclip")
                    .foregroundStyle(stateColor)
                    .font(.system(size: 18, weight: .medium))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(task.contact).font(.system(size: 15, weight: .semibold))
                    StatusBadge(state: task.state)
                }
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !task.uniqueContactConfirmed {
                    Text("需编辑并确认联系人名称唯一")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if !task.lastDetail.isEmpty && task.state != .pending {
                    Text(task.lastDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(task.state == .failed ? .red : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 5) {
                Text(task.nextExecutionDescription)
                    .font(.system(size: 13, weight: .medium))
                Text(task.repeatRule.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .trailing)

            Menu {
                Button("编辑", systemImage: "pencil", action: edit)
                Button("立即执行", systemImage: "play.fill", action: run)
                    .disabled(scheduler.isExecuting || !task.uniqueContactConfirmed)
                if task.state == .failed || task.state == .needsAttention {
                    Button("重新加入队列", systemImage: "arrow.clockwise", action: retry)
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .onTapGesture(perform: edit)
    }

    private var summary: String {
        let text = task.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = task.filePaths.count
        if !text.isEmpty && files > 0 { return "\(text)  ·  \(files) 个附件" }
        if files > 0 { return "\(files) 个附件" }
        return text
    }

    private var stateColor: Color {
        switch task.state {
        case .pending: return .blue
        case .running: return .orange
        case .draftReady: return .purple
        case .submitted: return .green
        case .needsAttention: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

private struct StatusBadge: View {
    let state: TaskState
    var body: some View {
        Text(state.title)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch state {
        case .pending: return .blue
        case .running, .needsAttention: return .orange
        case .draftReady: return .purple
        case .submitted: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

private struct SafetyBar: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var scheduler: TaskScheduler

    var body: some View {
        Divider()
        HStack(spacing: 8) {
            Image(systemName: scheduler.isExecuting ? "arrow.triangle.2.circlepath" : modeIcon)
                .foregroundStyle(modeColor)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text("微信需保持登录，Mac 需保持解锁")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 42)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var modeIcon: String { store.settings.realSendEnabled ? "paperplane.fill" : "shield.lefthalf.filled" }
    private var modeColor: Color { store.settings.realSendEnabled ? .green : .purple }
    private var statusText: String {
        if scheduler.isExecuting { return "正在执行微信任务" }
        return store.settings.realSendEnabled ? "真实发送已开启" : "安全预览：只填入草稿，不发送"
    }
}

private struct WeChatStatusBar: View {
    @EnvironmentObject private var monitor: WeChatStatusMonitor
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(monitor.snapshot.phase.title)
                        .font(.system(size: 12, weight: .semibold))
                    if !accountDescription.isEmpty {
                        Text(accountDescription)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(monitor.snapshot.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 92, alignment: .trailing)
            } else {
                Button("刷新", systemImage: "arrow.clockwise") {
                    monitor.refresh()
                }
                .buttonStyle(.borderless)
                .help("刷新微信状态")
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
        .background(statusColor.opacity(0.055))
    }

    private var statusColor: Color {
        switch monitor.snapshot.phase {
        case .loggedIn: return .green
        case .loginRequired: return .orange
        case .runningUnknown: return .yellow
        case .notRunning: return .red
        }
    }

    private var accountDescription: String {
        store.settings.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private struct TaskEditorView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    let existingTask: SendTask?
    @State private var contact: String
    @State private var message: String
    @State private var files: [String]
    @State private var scheduledAt: Date
    @State private var repeatRule: RepeatRule
    @State private var uniqueContactConfirmed: Bool
    @State private var validationMessage = ""

    init(existingTask: SendTask? = nil) {
        self.existingTask = existingTask
        _contact = State(initialValue: existingTask?.contact ?? "")
        _message = State(initialValue: existingTask?.message ?? "")
        _files = State(initialValue: existingTask?.filePaths ?? [])
        _scheduledAt = State(initialValue: existingTask?.scheduledAt ?? Date().addingTimeInterval(300))
        _repeatRule = State(initialValue: existingTask?.repeatRule ?? .once)
        _uniqueContactConfirmed = State(initialValue: existingTask?.uniqueContactConfirmed ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existingTask == nil ? "新建发送任务" : "编辑发送任务")
                        .font(.system(size: 20, weight: .semibold))
                    Text("请填写在微信搜索结果中唯一的联系人名称")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(22)

            Divider()

            Form {
                Section("接收人") {
                    TextField("例如：文件传输助手", text: $contact)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: contact) { oldValue, newValue in
                            let oldName = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            let newName = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if oldName != newName {
                                uniqueContactConfirmed = false
                            }
                        }

                    Toggle("我确认该联系人名称在微信搜索结果中唯一", isOn: $uniqueContactConfirmed)
                        .toggleStyle(.checkbox)
                    Text("程序会搜索该名称并直接打开第一项，不截图、不读取微信数据库。名称必须唯一；若有重名，请先在微信中设置唯一备注名。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("发送内容") {
                    TextEditor(text: $message)
                        .font(.system(size: 13))
                        .frame(minHeight: 96)
                        .padding(5)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

                    HStack {
                        Button("添加附件", systemImage: "paperclip") { chooseFiles() }
                        Spacer()
                        if !files.isEmpty {
                            Text("\(files.count) 个文件")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                    ForEach(files, id: \.self) { path in
                        HStack {
                            Image(systemName: "doc")
                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { files.removeAll { $0 == path } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }

                Section("时间") {
                    DatePicker("发送时间", selection: $scheduledAt)
                    Picker("重复", selection: $repeatRule) {
                        ForEach(RepeatRule.allCases) { rule in Text(rule.title).tag(rule) }
                    }
                    .pickerStyle(.segmented)
                }

                if !validationMessage.isEmpty {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(store.settings.realSendEnabled ? "保存后到点真实发送" : "保存后到点只填入草稿")
                    .font(.system(size: 11))
                    .foregroundStyle(store.settings.realSendEnabled ? .green : .secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingTask == nil ? "创建任务" : "保存修改") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 560, height: 680)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for path in panel.urls.map(\.path) where !files.contains(path) { files.append(path) }
        }
    }

    private func save() {
        let cleanContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContact.isEmpty else { validationMessage = "请填写联系人"; return }
        guard uniqueContactConfirmed else {
            validationMessage = "请确认该联系人名称在微信搜索结果中唯一"; return
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
            validationMessage = "请填写消息或添加附件"; return
        }
        guard scheduledAt > Date().addingTimeInterval(-5) || existingTask != nil else {
            validationMessage = "发送时间必须在未来"; return
        }

        if var task = existingTask {
            task.contact = cleanContact
            task.message = message
            task.filePaths = files
            task.scheduledAt = scheduledAt
            task.repeatRule = repeatRule
            task.uniqueContactConfirmed = uniqueContactConfirmed
            task.state = .pending
            task.isEnabled = true
            task.lastDetail = ""
            store.update(task)
        } else {
            store.add(SendTask(
                contact: cleanContact,
                message: message,
                filePaths: files,
                scheduledAt: scheduledAt,
                repeatRule: repeatRule,
                uniqueContactConfirmed: uniqueContactConfirmed
            ))
        }
        dismiss()
    }
}

private struct LogView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "执行记录", subtitle: "最多保留最近 200 条本机记录。") { EmptyView() }
            Divider()
            if store.logs.isEmpty {
                ContentUnavailableView("暂无执行记录", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.logs) { log in
                    HStack(spacing: 12) {
                        Image(systemName: log.result == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(log.result == .failed ? .red : .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(log.contact).font(.system(size: 13, weight: .semibold))
                            Text(log.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(log.timestamp, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var accessAllowed = PermissionCenter.hasAccessibility
    @State private var showingRealSendConfirmation = false
    @State private var launchError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "设置", subtitle: "只需辅助功能权限，用于控制本机微信。") { EmptyView() }

                SettingsSection(title: "系统权限") {
                    PermissionRow(
                        icon: "hand.raised.fill",
                        title: "辅助功能",
                        detail: "用于向微信发送搜索、粘贴和回车操作",
                        allowed: accessAllowed
                    ) {
                        PermissionCenter.requestAccessibility()
                        refreshPermissionsLater()
                    }
                }

                SettingsSection(title: "发送行为") {
                    Toggle(isOn: Binding(
                        get: { store.settings.realSendEnabled },
                        set: { enabled in
                            if enabled { showingRealSendConfirmation = true }
                            else {
                                var settings = store.settings
                                settings.realSendEnabled = false
                                store.replaceSettings(settings)
                            }
                        }
                    )) {
                        HStack(spacing: 10) {
                            Text("允许真实发送")
                                .font(.system(size: 13, weight: .medium))
                            Text("关闭时只把内容填入聊天框，不会按发送键")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Toggle(isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { enabled in toggleLaunchAtLogin(enabled) }
                    )) {
                        HStack(spacing: 10) {
                            Text("登录后保持运行")
                                .font(.system(size: 13, weight: .medium))
                            Text("安装本机 LaunchAgent，保证计划任务调度器在运行")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !launchError.isEmpty {
                        Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }

                SettingsSection(title: "微信账号") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("微信名或微信号").font(.system(size: 13, weight: .medium))
                            Text("用于在状态栏标记当前账号；程序不会读取微信数据目录")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("例如：张开 / zhangkai", text: Binding(
                            get: { store.settings.accountLabel },
                            set: { value in
                                var settings = store.settings
                                settings.accountLabel = value
                                store.replaceSettings(settings)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    }
                }

                SettingsSection(title: "本机数据") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("任务与日志").font(.system(size: 13, weight: .medium))
                            Text(TaskStore.defaultStateURL().path)
                                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([TaskStore.defaultStateURL()])
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .alert("开启真实发送？", isPresented: $showingRealSendConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认开启") {
                var settings = store.settings
                settings.realSendEnabled = true
                store.replaceSettings(settings)
            }
        } message: {
            Text("到点后程序会搜索联系人并直接打开第一项，再投递消息。请确保联系人名称唯一，并先用文件传输助手完成测试。")
        }
    }

    private func refreshPermissionsLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            accessAllowed = PermissionCenter.hasAccessibility
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAgentManager.setEnabled(enabled)
            var settings = store.settings
            settings.launchAtLogin = enabled
            store.replaceSettings(settings)
            launchError = ""
        } catch {
            launchError = error.localizedDescription
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 28)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(allowed ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed {
                Label("已允许", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            } else {
                Button("去授权", action: action)
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var scheduler: TaskScheduler
    @EnvironmentObject private var weChatStatus: WeChatStatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("微信发送").font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(weChatStatus.snapshot.phase == .loggedIn ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(weChatStatus.snapshot.phase.title)
                    .font(.caption)
                if !accountDescription.isEmpty {
                    Text(accountDescription).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let next = store.tasks.first(where: { $0.isEnabled && $0.state == .pending }) {
                Text("下一项：\(next.contact) · \(next.nextExecutionDescription)")
                    .font(.caption)
            } else {
                Text("没有等待中的任务").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(store.settings.realSendEnabled ? "真实发送已开启" : "当前为安全预览")
                .font(.caption).foregroundStyle(store.settings.realSendEnabled ? .green : .purple)
            Button("打开主窗口") { NSApp.activate(ignoringOtherApps: true) }
            Button("退出") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var accountDescription: String {
        store.settings.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
