import SwiftUI
import AppKit

/// Settings › Tickets: per-project WhatsApp chats, repos, keys and options.
struct TicketsSettingsTab: View {
    @ObservedObject var worker: TicketsWorker
    @ObservedObject var configs: TicketsConfigStore
    let projects: [(id: String, name: String)]
    @State private var selectedProject: String?

    init(worker: TicketsWorker, projects: [(id: String, name: String)], initialProject: String?) {
        self.worker = worker
        self.configs = worker.configs
        self.projects = projects
        _selectedProject = State(initialValue: initialProject ?? projects.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Project", selection: $selectedProject) {
                    ForEach(projects, id: \.id) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                DatabaseAccessBadge()
            }
            if let id = selectedProject, let name = projects.first(where: { $0.id == id })?.name {
                TicketsProjectEditor(worker: worker, configs: configs, projectID: id, projectName: name)
                    .id(id)
            } else {
                VStack(spacing: 6) {
                    Text("No project open").font(.headline)
                    Text("Open a project in Ookook, then pick it here to configure its ticket pipeline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}

/// Whether Ookook can read WhatsApp's database, and the button that fixes it.
private struct DatabaseAccessBadge: View {
    @State private var error: String?
    @State private var checked = false

    var body: some View {
        HStack(spacing: 8) {
            if checked {
                Label(error == nil ? "WhatsApp database readable" : "Full Disk Access needed",
                      systemImage: error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(error == nil ? .green : .orange)
                    .font(.caption)
                    .help(error ?? "")
            }
            Button("Full Disk Access…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .font(.caption)
            Button {
                check()
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Check again")
        }
        .onAppear(perform: check)
    }

    private func check() {
        Task.detached {
            let result = WhatsAppStore.canRead()
            await MainActor.run {
                if case .failure(let e) = result { error = e.localizedDescription } else { error = nil }
                checked = true
            }
        }
    }
}

private struct TicketsProjectEditor: View {
    @ObservedObject var worker: TicketsWorker
    @ObservedObject var configs: TicketsConfigStore
    let projectID: String
    let projectName: String

    @State private var draft: TicketsProjectConfig
    @State private var deepSeekKey = ""
    @State private var gitHubToken = ""
    @State private var keysLoaded = false
    @State private var pickingChat = false
    @State private var backtestFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var backtestTo = Date()
    @State private var resetHours = 24.0
    @State private var showLog = false

    init(worker: TicketsWorker, configs: TicketsConfigStore, projectID: String, projectName: String) {
        self.worker = worker
        self.configs = configs
        self.projectID = projectID
        self.projectName = projectName
        _draft = State(initialValue: configs.config(for: projectID))
    }

    private var status: TicketsProjectStatus { worker.status[projectID] ?? TicketsProjectStatus() }

    var body: some View {
        Form {
            Section {
                Toggle("Turn WhatsApp chats into GitHub tickets for \(projectName)", isOn: $draft.enabled)
                    .onChange(of: draft.enabled) { save() }
                statusLine
            }

            Section("Chats") {
                if draft.chats.isEmpty {
                    Text("No chats yet. Messages from these people are classified; your replies count as resolutions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(draft.chats) { chat in
                    HStack {
                        Text(chat.name)
                        Text(chat.jid).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            draft.chats.removeAll { $0.id == chat.id }
                            save()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Chat…") { pickingChat = true }
                    .sheet(isPresented: $pickingChat) {
                        ChatPickerSheet(existing: Set(draft.chats.map(\.jid))) { chat in
                            draft.chats.append(chat)
                            save()
                        }
                    }
            }

            Section("Repositories") {
                Text("First repo is the default target. The local clone gives the model a file map.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($draft.repos) { $repo in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("owner/name", text: $repo.repo)
                                .frame(maxWidth: 220)
                            TextField("what lives here (hint for the model)", text: $repo.hint)
                            Button(role: .destructive) {
                                draft.repos.removeAll { $0.id == repo.id }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("local clone path (optional)", text: $repo.localPath)
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url { repo.localPath = url.path }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Repository") { draft.repos.append(TicketRepo()) }
            }

            Section("Keys") {
                SecureField("DeepSeek API key (this project)", text: $deepSeekKey)
                SecureField("GitHub token (optional; `gh auth token` is used otherwise)", text: $gitHubToken)
                HStack {
                    Text("Leave the project key empty to fall back to the shared key below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Keys") {
                        TicketsKeychain.set(deepSeekKey, account: TicketsKeychain.deepSeekAccount(projectID: projectID))
                        TicketsKeychain.set(gitHubToken, account: TicketsKeychain.gitHubAccount(projectID: projectID))
                    }
                }
                SharedKeyRow()
            }

            Section("Classification") {
                TextField("Model", text: $draft.model)
                TextField("Base URL", text: $draft.baseURL)
                Stepper("Poll every \(draft.pollSeconds)s", value: $draft.pollSeconds, in: 10 ... 600, step: 10)
                Stepper("Batch gap \(draft.batchGapSeconds / 60) min", value: $draft.batchGapSeconds, in: 60 ... 3600, step: 60)
                Stepper("Wait for \(draft.quietSeconds)s of quiet", value: $draft.quietSeconds, in: 0 ... 900, step: 30)
                Stepper("Context messages \(draft.contextMessages)", value: $draft.contextMessages, in: 0 ... 60, step: 5)
                confidenceSlider("Minimum confidence", $draft.minConfidence)
                confidenceSlider("Low-confidence label below", $draft.lowConfidenceBelow)
                Stepper("Closed issues stay visible \(draft.issueLookbackDays) days", value: $draft.issueLookbackDays, in: 0 ... 180, step: 5)
                Stepper("Map at most \(draft.maxMapFilesPerRepo) files per repo", value: $draft.maxMapFilesPerRepo, in: 50 ... 2000, step: 50)
                TextField("Language hint", text: $draft.languageHint)
            }

            Section("Quality of life") {
                Toggle("Notify when a ticket is created", isOn: $draft.notifyOnNewTicket)
                Toggle("Read text in screenshots (local Vision OCR)", isOn: $draft.ocrScreenshots)
                HStack {
                    Toggle("Auto-approve bug/feature tickets", isOn: Binding(
                        get: { draft.autoApproveAbove <= 1 },
                        set: { draft.autoApproveAbove = $0 ? 0.9 : 1.01 }))
                    if draft.autoApproveAbove <= 1 {
                        Slider(value: $draft.autoApproveAbove, in: 0.5 ... 1, step: 0.05)
                        Text(String(format: "≥ %.2f", draft.autoApproveAbove)).monospacedDigit()
                    }
                }
                Text("Auto-approved tickets skip `triage` and land in `todo`, where Claude Code picks them up. Ops, XML and integration tickets always wait for you.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Ignore types")
                    ForEach(ClassifiedTask.types, id: \.self) { t in
                        Toggle(t, isOn: Binding(
                            get: { draft.ignoredTypes.contains(t) },
                            set: { on in
                                if on { draft.ignoredTypes.append(t) } else { draft.ignoredTypes.removeAll { $0 == t } }
                            }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Text("Active hours")
                    Picker("from", selection: $draft.activeHoursStart) {
                        ForEach(0 ..< 24, id: \.self) { Text("\($0):00").tag($0) }
                    }.frame(width: 110)
                    Picker("to", selection: $draft.activeHoursEnd) {
                        ForEach(1 ..< 25, id: \.self) { Text("\($0):00").tag($0) }
                    }.frame(width: 110)
                    Text("Messages outside are picked up at the next active hour.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Labels for new tickets (comma separated)", text: Binding(
                    get: { draft.labels.joined(separator: ", ") },
                    set: { draft.labels = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            }

            Section("Actions") {
                HStack {
                    Button("Run Now") { Task { await worker.runNow(projectID) } }
                        .disabled(!draft.enabled || !draft.isConfigured)
                    Button("Dry Run") { Task { await worker.dryRun(projectID) } }
                        .disabled(!draft.isConfigured)
                    Divider().frame(height: 16)
                    Stepper("Re-read last \(Int(resetHours))h", value: $resetHours, in: 1 ... 720, step: 1)
                    Button("Reset Cursor") { worker.reset(projectID, hours: resetHours) }
                    Spacer()
                    Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                }
                Text("Dry Run classifies whatever is pending and only logs what it would create. Reset moves the reading position back so those messages are seen again.")
                    .font(.caption).foregroundStyle(.secondary)
                if showLog {
                    LogView(lines: worker.log.filter { $0.contains("[\(projectName)]") })
                }
            }

            Section("Backtest") {
                HStack {
                    DatePicker("From", selection: $backtestFrom, displayedComponents: .date)
                    DatePicker("To", selection: $backtestTo, displayedComponents: .date)
                    Button("Run Backtest") { worker.startBacktest(projectID, from: backtestFrom, to: backtestTo) }
                        .disabled(!draft.isConfigured || worker.backtest[projectID]?.isRunning == true)
                    if worker.backtest[projectID]?.isRunning == true {
                        Button("Stop") { worker.backtest[projectID]?.cancelled = true }
                    }
                }
                Text("Replays the chat range through the classifier into memory. Nothing is written to GitHub or to the cursor; it costs API tokens.")
                    .font(.caption).foregroundStyle(.secondary)
                if let run = worker.backtest[projectID] {
                    BacktestResultView(run: run)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadKeys)
        .onChange(of: draft) { save() }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.isRunning ? (status.lastError == nil ? Color.green : .orange) : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if status.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var statusText: String {
        if let error = status.lastError { return error }
        guard status.isRunning else { return draft.enabled ? "Waiting for chats and repos" : "Off" }
        var parts = ["Running"]
        if let poll = status.lastPoll { parts.append("polled " + poll.formatted(date: .omitted, time: .shortened)) }
        if let batch = status.lastBatch { parts.append("last batch " + batch.formatted(date: .omitted, time: .shortened)) }
        parts.append(status.usage.summary)
        return parts.joined(separator: " · ")
    }

    private func confidenceSlider(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: 0 ... 1, step: 0.05)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 36)
        }
    }

    private func loadKeys() {
        guard !keysLoaded else { return }
        keysLoaded = true
        deepSeekKey = TicketsKeychain.get(TicketsKeychain.deepSeekAccount(projectID: projectID)) ?? ""
        gitHubToken = TicketsKeychain.get(TicketsKeychain.gitHubAccount(projectID: projectID)) ?? ""
    }

    private func save() {
        configs.set(draft, for: projectID)
        worker.reconcile()
    }
}

/// The one DeepSeek key every project falls back to.
private struct SharedKeyRow: View {
    @State private var key = TicketsKeychain.get(TicketsKeychain.sharedAccount) ?? ""

    var body: some View {
        HStack {
            SecureField("Shared DeepSeek API key (used when a project has none)", text: $key)
            Button("Save Shared") { TicketsKeychain.set(key, account: TicketsKeychain.sharedAccount) }
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.suffix(200).enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .onChange(of: lines.count) { proxy.scrollTo(min(lines.count, 200) - 1) }
        }
    }
}

private struct BacktestResultView: View {
    @ObservedObject var run: TicketsWorker.BacktestRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let report = run.report {
                let byType = Dictionary(grouping: report.issues, by: \.type).mapValues(\.count)
                Text("\(report.messages) messages, \(report.batches) batches → \(report.issues.count) issues "
                     + "(\(byType.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))")
                    .font(.caption)
                Text(report.usage.summary).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.issues, id: \.ref) { issue in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(issue.ref).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(issue.fullTitle).font(.system(size: 12, weight: .medium))
                                }
                                Text("\(issue.type) · \(issue.priority) · conf \(String(format: "%.2f", issue.confidence)) · \(issue.events.count) update(s) · \(issue.labels.joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .help(issue.body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            LogView(lines: run.lines)
        }
    }
}

/// Picks a WhatsApp chat from the local database.
private struct ChatPickerSheet: View {
    let existing: Set<String>
    let onPick: (TicketChat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [WhatsAppChat] = []
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a chat").font(.headline)
            TextField("Filter by name or number", text: $filter)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            List(filtered) { chat in
                HStack {
                    VStack(alignment: .leading) {
                        Text(chat.name)
                        Text("\(chat.isGroup ? "group" : "1:1") · \(chat.messageCount) msgs · \(chat.jid)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if existing.contains(chat.jid) {
                        Text("added").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Add") {
                            onPick(TicketChat(jid: chat.jid, name: chat.name))
                            dismiss()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
        .onAppear(perform: load)
    }

    private var filtered: [WhatsAppChat] {
        let q = filter.lowercased()
        return q.isEmpty ? chats : chats.filter { $0.name.lowercased().contains(q) || $0.jid.contains(q) }
    }

    private func load() {
        Task.detached {
            let store = WhatsAppStore()
            defer { store.close() }
            do {
                let list = try store.listChats()
                await MainActor.run { chats = list }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}
