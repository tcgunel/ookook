import SwiftUI
import AppKit

/// One group of ticket settings, as listed in the Tickets sidebar.
enum TicketsSettingsPane: String, CaseIterable, Identifiable {
    case status, sources, tickets, media, schedule, keys, advanced, backtest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .sources: return "Sources"
        case .tickets: return "Tickets"
        case .media: return "Media"
        case .schedule: return "Schedule & Cost"
        case .keys: return "Keys"
        case .advanced: return "Advanced"
        case .backtest: return "Backtest"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "waveform.path.ecg"
        case .sources: return "bubble.left.and.bubble.right"
        case .tickets: return "tray.full"
        case .media: return "photo.on.rectangle"
        case .schedule: return "clock"
        case .keys: return "key"
        case .advanced: return "slider.horizontal.3"
        case .backtest: return "clock.arrow.circlepath"
        }
    }
}

/// Settings › Tickets: per-project WhatsApp chats, repos, keys and options.
///
/// A sidebar of groups beside one pane at a time, in the order the pipeline
/// is used: what it is doing now, where messages come from, where tickets go,
/// how media is read, when it runs, keys, then tuning and the backtest.
/// Explanations live in hover help so each pane stays short; only the
/// attachment privacy warning is always shown.
struct TicketsSettingsTab: View {
    @ObservedObject var worker: TicketsWorker
    @ObservedObject var configs: TicketsConfigStore
    let projects: [(id: String, name: String)]
    @State private var selectedProject: String?
    @State private var pane: TicketsSettingsPane
    @State private var query: String
    /// Search every pane, or only the selected one.
    @State private var searchAll = true

    init(worker: TicketsWorker, projects: [(id: String, name: String)], initialProject: String?,
         initialPane: TicketsSettingsPane = .status, initialQuery: String = "", searchAll: Bool = true) {
        self.worker = worker
        self.configs = worker.configs
        self.projects = projects
        _selectedProject = State(initialValue: initialProject ?? projects.first?.id)
        _pane = State(initialValue: initialPane)
        _query = State(initialValue: initialQuery)
        _searchAll = State(initialValue: searchAll)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// The panes the detail side shows: the selected one, or every pane with
    /// a match while searching across all of them.
    private var shownPanes: [TicketsSettingsPane] {
        guard isSearching else { return [pane] }
        let candidates = searchAll ? TicketsSettingsPane.allCases : [pane]
        return candidates.filter { TicketsSettingsIndex.matchCount($0, query: trimmedQuery) > 0 }
    }

    private var status: TicketsProjectStatus {
        selectedProject.flatMap { worker.status[$0] } ?? TicketsProjectStatus()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let id = selectedProject, let name = projects.first(where: { $0.id == id })?.name {
                if shownPanes.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text("No settings match “\(trimmedQuery)”").font(.headline)
                        if !searchAll {
                            Button("Search all settings") { searchAll = true }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TicketsProjectEditor(worker: worker, configs: configs, projectID: id, projectName: name,
                                         panes: shownPanes, query: trimmedQuery)
                        .id(id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 6) {
                    Text("No project open").font(.headline)
                    Text("Open a project in Ookook, then pick it here to configure its ticket pipeline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Project", selection: $selectedProject) {
                ForEach(projects, id: \.id) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .padding([.horizontal, .top], 10)
            searchField
                .padding(.horizontal, 10)
            if isSearching {
                Picker("Search in", selection: $searchAll) {
                    Text("All").tag(true)
                    Text(pane.title).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .help("Search every group, or only the selected one")
            }
            List(TicketsSettingsPane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { select(p) } })) { item in
                let matches = isSearching ? TicketsSettingsIndex.matchCount(item, query: trimmedQuery) : nil
                HStack {
                    Label(item.title, systemImage: item.symbol)
                    Spacer()
                    if let matches {
                        if matches > 0 { Text("\(matches)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    } else {
                        badge(for: item)
                    }
                }
                .opacity(matches == 0 ? 0.4 : 1)
                .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 190)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
            if isSearching {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
    }

    /// Picking a group during an "All" search narrows the search to it.
    private func select(_ item: TicketsSettingsPane) {
        pane = item
        if isSearching { searchAll = false }
    }

    /// What needs a look, shown where it can be fixed.
    @ViewBuilder
    private func badge(for item: TicketsSettingsPane) -> some View {
        switch item {
        case .status:
            Circle()
                .fill(!status.isRunning ? Color.secondary.opacity(0.4)
                      : status.lastError != nil ? .red
                      : status.waitingForMedia.isEmpty ? .green : .orange)
                .frame(width: 7, height: 7)
        case .media where !status.waitingForMedia.isEmpty:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                .help("Waiting for media to download")
        default:
            EmptyView()
        }
    }
}

/// Whether Ookook can read each local message store, with the button that
/// fixes the reason it cannot.
private struct DatabaseAccessRows: View {
    @State private var whatsappError: String?
    @State private var zapfastError: String?
    @State private var checked = false

    var body: some View {
        LabeledContent("Access") {
            HStack(spacing: 12) {
                if checked {
                    access("ZapFast", error: zapfastError)
                    access("WhatsApp app", error: whatsappError)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button {
                    check(reprompt: true)
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check again (re-asks for the ZapFast keychain item if it was denied)")
            }
        }
        .onAppear { check(reprompt: false) }
        if let zapfastError {
            fix(zapfastError, button: "Open ZapFast") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "me.paolino.fastsapp") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        if let whatsappError {
            fix(whatsappError, button: "Full Disk Access…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
    }

    private func access(_ name: String, error: String?) -> some View {
        Label(name, systemImage: error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(error == nil ? .green : .orange)
            .help(error ?? "Readable")
    }

    private func fix(_ message: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(button, action: action)
        }
    }

    private func check(reprompt: Bool) {
        Task.detached {
            if reprompt { ZapFastKeychain.resetFailures() }
            let whatsapp = WhatsAppStore.canRead()
            let zapfast = ZapFastStore.canRead()
            await MainActor.run {
                if case .failure(let e) = whatsapp { whatsappError = e.localizedDescription } else { whatsappError = nil }
                if case .failure(let e) = zapfast { zapfastError = e.localizedDescription } else { zapfastError = nil }
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
    @State private var pickingChat = false
    @State private var backtestFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var backtestTo = Date()
    @State private var resetHours = 4.0
    let panes: [TicketsSettingsPane]
    let query: String

    init(worker: TicketsWorker, configs: TicketsConfigStore, projectID: String, projectName: String,
         panes: [TicketsSettingsPane], query: String) {
        self.worker = worker
        self.configs = configs
        self.projectID = projectID
        self.projectName = projectName
        self.panes = panes
        self.query = query
        _draft = State(initialValue: configs.config(for: projectID))
    }

    /// Whether a row is shown under the current search.
    private func shows(_ ids: String...) -> Bool {
        ids.contains { TicketsSettingsIndex.matches($0, query: query) }
    }

    private var status: TicketsProjectStatus { worker.status[projectID] ?? TicketsProjectStatus() }

    private var modelBinding: Binding<String> {
        Binding(get: { worker.transcriber.model }, set: { worker.transcriber.model = $0 })
    }

    var body: some View {
        Form {
            ForEach(panes) { pane in
                switch pane {
                case .status: statusSection
                case .sources: sourcesSection
                case .tickets: destinationSection
                case .media: mediaSection
                case .schedule: scheduleSection
                case .keys: keysSection
                case .advanced: advancedSection
                case .backtest: backtestSection
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { save() }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        if shows("enabled", "run", "reread") {
            Section("Status") {
                if shows("enabled") {
                    Toggle(isOn: $draft.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Turn WhatsApp chats into GitHub tickets")
                            statusLine
                        }
                    }
                }
                if shows("enabled"), !status.waitingForMedia.isEmpty {
                    Label("Holding a batch until its media downloads: \(status.waitingForMedia.joined(separator: ", ")). Open the chat in ZapFast.",
                          systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if shows("run", "reread") {
                    HStack {
                        Button("Run Now") { Task { await worker.runNow(projectID) } }
                            .disabled(!draft.enabled || !draft.isConfigured)
                            .help("Classify pending messages now, without waiting for the chat to go quiet.")
                        Button("Dry Run") { Task { await worker.dryRun(projectID) } }
                            .disabled(!draft.isConfigured)
                            .help("Classify pending messages and only log what would be created. Costs API tokens.")
                        Spacer()
                        Text("Last \(Int(resetHours)) h")
                            .monospacedDigit()
                        Stepper("Hours", value: $resetHours, in: 1 ... 720, step: 1)
                            .labelsHidden()
                        Button("Re-read") { worker.reset(projectID, hours: resetHours) }
                            .help("Move the reading position back so those messages are classified again on the next poll. Already-filed tickets are not duplicated.")
                    }
                }
            }
        }
        if shows("log") {
            Section("Log") {
                LogView(lines: worker.log.filter { $0.contains("[\(projectName)]") })
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if status.isBusy { ProgressView().controlSize(.mini) }
        }
    }

    private var statusColor: Color {
        guard status.isRunning else { return .secondary.opacity(0.4) }
        if status.lastError != nil { return .red }
        return status.waitingForMedia.isEmpty ? .green : .orange
    }

    private var statusText: String {
        if let error = status.lastError { return error }
        guard status.isRunning else {
            if !draft.enabled { return "Off" }
            if draft.chats.isEmpty { return "Add a chat to start" }
            if draft.repos.allSatisfy({ $0.repo.isEmpty }) { return "Add a repository to start" }
            return "Starting…"
        }
        var parts = ["Running"]
        if let poll = status.lastPoll { parts.append("polled " + poll.formatted(date: .omitted, time: .shortened)) }
        if let batch = status.lastBatch { parts.append("last batch " + batch.formatted(date: .omitted, time: .shortened)) }
        parts.append(status.usage.summary)
        return parts.joined(separator: " · ")
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section("Sources") {
            if shows("source") {
                Picker("Read messages from", selection: $draft.messageSource) {
                    ForEach(TicketMessageSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .help("Automatic follows whichever client is actually receiving: ZapFast while it stays linked and fresh, the official app if ZapFast falls behind. Pin one only to force a side.")
            }
            if shows("access") { DatabaseAccessRows() }
            if shows("chats") {
                if draft.chats.isEmpty {
                    Text("No chats yet. Messages from the people in these chats are classified; your own replies count as follow-ups and resolutions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(draft.chats) { chat in
                    LabeledContent {
                        removeButton { draft.chats.removeAll { $0.id == chat.id } }
                    } label: {
                        Text(chat.name)
                        Text(chat.jid)
                    }
                }
                Button("Add Chat…") { pickingChat = true }
                    .sheet(isPresented: $pickingChat) {
                        ChatPickerSheet(existing: Set(draft.chats.map(\.jid))) { chat in
                            draft.chats.append(chat)
                        }
                    }
            }
        }
    }

    // MARK: Destination

    private var autoApprove: Binding<Bool> {
        Binding(get: { draft.autoApproveAbove <= 1 }, set: { draft.autoApproveAbove = $0 ? 0.9 : 1.01 })
    }

    private var destinationSection: some View {
        Section {
            if shows("repos") {
                ForEach($draft.repos) { $repo in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("owner/name", text: $repo.repo)
                                .frame(maxWidth: 200)
                                .help("The GitHub repository tickets are filed in.")
                            TextField("What lives here", text: $repo.hint)
                                .help("A hint for the model when it picks between repositories.")
                            removeButton { draft.repos.removeAll { $0.id == repo.id } }
                        }
                        HStack {
                            TextField("Local clone (optional)", text: $repo.localPath)
                                .help("A local checkout gives the model a file map, so tickets can name likely files.")
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url { repo.localPath = url.path }
                            }
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 2)
                }
                Button("Add Repository") { draft.repos.append(TicketRepo()) }
            }
            if shows("labels") {
                TextField("Labels on new tickets", text: Binding(
                    get: { draft.labels.joined(separator: ", ") },
                    set: { draft.labels = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .help("Comma separated. `triage` is the column a human approves from.")
            }
            if shows("autoApprove") {
                Toggle("Auto-approve confident bug and feature tickets", isOn: autoApprove)
                    .help("Auto-approved tickets skip `triage` and land in `todo`, where Claude Code picks them up. Ops, XML and integration tickets always wait for you.")
                if autoApprove.wrappedValue {
                    LabeledContent("At confidence") {
                        HStack {
                            Slider(value: $draft.autoApproveAbove, in: 0.5 ... 1, step: 0.05).frame(maxWidth: 220)
                            Text(String(format: "≥ %.2f", draft.autoApproveAbove)).monospacedDigit()
                        }
                    }
                }
            }
            if shows("neverFile") {
                LabeledContent("Never file") {
                    HStack(spacing: 10) {
                        ForEach(ClassifiedTask.types, id: \.self) { t in
                            Toggle(t, isOn: Binding(
                                get: { draft.ignoredTypes.contains(t) },
                                set: { on in
                                    if on { draft.ignoredTypes.append(t) } else { draft.ignoredTypes.removeAll { $0 == t } }
                                }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .help("Ticket types that are never created. The model still reads those messages as context.")
            }
        } header: {
            Text("Tickets")
        } footer: {
            if shows("repos") {
                Text("The first repository is the default target.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Media

    private var mediaSection: some View {
        Section("Media") {
            if shows("ocr") {
                Toggle("Read text in screenshots", isOn: $draft.ocrScreenshots)
                    .help("Local Vision OCR. The text goes through the redactor before the model sees it.")
            }
            if shows("transcribe") {
                Toggle("Transcribe voice notes and videos", isOn: $draft.transcribeMedia)
                    .help("Local Whisper. Audio never leaves this Mac; each message is transcribed once, up to the first 10 minutes.")
            }
            if draft.transcribeMedia {
                if shows("whisperModel") {
                    Picker("Whisper model", selection: modelBinding) {
                        ForEach(Transcriber.models, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }
                if shows("language") {
                    Picker("Spoken language", selection: $draft.transcribeLanguage) {
                        Text("Auto-detect").tag("")
                        Text("Turkish").tag("tr")
                        Text("English").tag("en")
                    }
                }
                if shows("whisperModel", "transcribe") {
                    TranscriptionStatusRow(transcriber: worker.transcriber)
                }
            }
            if shows("mediaWait") {
                Stepper("Wait up to \(draft.mediaWaitMinutes) min for media to download",
                        value: $draft.mediaWaitMinutes, in: 0 ... 1440, step: 15)
                    .help("ZapFast downloads a chat's media when the chat is opened. A batch whose screenshot, video or voice note is not on disk yet waits this long, and Ookook notifies you once so you can open the chat.")
            }
            if shows("attach") {
                Toggle("Attach screenshots, videos and documents to tickets", isOn: $draft.attachMedia)
            }
            if shows("attach"), draft.attachMedia {
                Stepper("At most \(draft.maxAttachmentsPerPost) per ticket or comment",
                        value: $draft.maxAttachmentsPerPost, in: 0 ... 20, step: 1)
                Stepper("Skip files over \(draft.maxAttachmentMB) MB",
                        value: $draft.maxAttachmentMB, in: 1 ... 100, step: 1)
                Label("Files are committed as-is to an `ookook-attachments` branch in the ticket's repo. Only text is redacted, so anything visible in a screenshot — panel passwords included — becomes readable by everyone with access to that repo.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Schedule

    private var scheduleSection: some View {
        Section("Schedule & Cost") {
            if shows("activeHours") {
                LabeledContent("Active hours") {
                    HStack {
                        Picker("From", selection: $draft.activeHoursStart) {
                            ForEach(0 ..< 24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        Text("to")
                        Picker("To", selection: $draft.activeHoursEnd) {
                            ForEach(1 ..< 25, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help("Messages outside these hours are picked up at the next active hour.")
            }
            if shows("notify") {
                Toggle("Notify me about new tickets and waiting media", isOn: $draft.notifyOnNewTicket)
            }
            if shows("pricing") { DeepSeekPeakHoursRow() }
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        Section {
            if shows("deepseekKey") {
                KeyField(label: "DeepSeek key", prompt: "Uses the shared key when empty",
                         account: TicketsKeychain.deepSeekAccount(projectID: projectID))
            }
            if shows("sharedKey") {
                KeyField(label: "Shared DeepSeek key", prompt: "Used by every project without its own",
                         account: TicketsKeychain.sharedAccount)
            }
            if shows("githubToken") {
                KeyField(label: "GitHub token", prompt: "Uses `gh auth token` when empty",
                         account: TicketsKeychain.gitHubAccount(projectID: projectID))
            }
        } header: {
            Text("Keys")
        } footer: {
            Text("Stored in the login keychain and saved as you type.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section("Advanced") {
            if shows("model") { TextField("Model", text: $draft.model) }
            if shows("baseURL") { TextField("Base URL", text: $draft.baseURL) }
            if shows("languageHint") {
                TextField("Language hint", text: $draft.languageHint)
                    .help("Told to the model with every batch.")
            }
            if shows("poll") {
                Stepper("Poll every \(draft.pollSeconds) s", value: $draft.pollSeconds, in: 10 ... 600, step: 10)
            }
            if shows("quiet") {
                Stepper("Wait for \(draft.quietSeconds) s of quiet", value: $draft.quietSeconds, in: 0 ... 900, step: 30)
                    .help("A batch is classified only after the chat has been silent this long, so a request typed over several messages arrives whole.")
            }
            if shows("batchGap") {
                Stepper("Batch gap \(draft.batchGapSeconds / 60) min", value: $draft.batchGapSeconds, in: 60 ... 3600, step: 60)
                    .help("Messages closer together than this are classified as one batch.")
            }
            if shows("context") {
                Stepper("Context messages \(draft.contextMessages)", value: $draft.contextMessages, in: 0 ... 60, step: 5)
                    .help("Earlier messages sent along with each batch so follow-ups make sense.")
            }
            if shows("minConfidence") {
                confidenceSlider("Minimum confidence", $draft.minConfidence, help: "Tasks below this are dropped.")
            }
            if shows("lowConfidence") {
                confidenceSlider("Low-confidence label below", $draft.lowConfidenceBelow,
                                 help: "Tickets below this get the `low-confidence` label.")
            }
            if shows("lookback") {
                Stepper("Closed issues stay visible \(draft.issueLookbackDays) days", value: $draft.issueLookbackDays, in: 0 ... 180, step: 5)
                    .help("How far back the model sees closed issues, so a repeat request links to the old ticket.")
            }
            if shows("mapFiles") {
                Stepper("Map at most \(draft.maxMapFilesPerRepo) files per repo", value: $draft.maxMapFilesPerRepo, in: 50 ... 2000, step: 50)
            }
        }
    }

    // MARK: Backtest

    private var backtestSection: some View {
        Section("Backtest") {
            Group {
                HStack {
                    DatePicker("From", selection: $backtestFrom, displayedComponents: .date)
                    DatePicker("To", selection: $backtestTo, displayedComponents: .date)
                    Spacer()
                    if worker.backtest[projectID]?.isRunning == true {
                        Button("Stop") { worker.backtest[projectID]?.cancelled = true }
                    }
                    Button("Run Backtest") { worker.startBacktest(projectID, from: backtestFrom, to: backtestTo) }
                        .disabled(!draft.isConfigured || worker.backtest[projectID]?.isRunning == true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replays the chat range through the classifier into memory. Nothing is written to GitHub or to the reading position; it costs API tokens.")
                        .font(.caption).foregroundStyle(.secondary)
                    PeakRateNotice()
                }
                if let run = worker.backtest[projectID] {
                    BacktestResultView(run: run)
                }
            }
        }
    }

    // MARK: Helpers

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove")
    }

    private func confidenceSlider(_ label: String, _ value: Binding<Double>, help: String) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0 ... 1, step: 0.05).frame(maxWidth: 220)
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 36)
            }
        }
        .help(help)
    }

    private func save() {
        configs.set(draft, for: projectID)
        worker.reconcile()
    }
}

/// One keychain-backed secret. Saved shortly after typing stops, so a key
/// pasted in and left behind is not silently lost the way it was behind a
/// separate Save button.
private struct KeyField: View {
    let label: String
    let prompt: String
    let account: String
    @State private var value = ""
    @State private var loaded = false
    @State private var saved = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                SecureField(label, text: $value, prompt: Text(prompt))
                    .labelsHidden()
                    .onSubmit(commit)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .opacity(saved ? 1 : 0)
                    .help("Saved to the keychain")
            }
        }
        .onAppear {
            guard !loaded else { return }
            value = TicketsKeychain.get(account) ?? ""
            loaded = true
        }
        .onChange(of: value) {
            guard loaded else { return }
            saved = false
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                commit()
            }
        }
        .onDisappear { if pending != nil { commit() } }
    }

    private func commit() {
        pending?.cancel()
        pending = nil
        TicketsKeychain.set(value, account: account)
        saved = true
    }
}

/// Live view of DeepSeek's peak/off-peak billing windows on the local clock.
private struct DeepSeekPeakHoursRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let state = DeepSeekPricing.state(at: now)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isPeak ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(DeepSeekPricing.statusText(at: now)).font(.caption)
                    Spacer()
                    Button("Pricing page…") { NSWorkspace.shared.open(DeepSeekPricing.pricingURL) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text("Peak hours in \(TimeZone.current.identifier): "
                     + DeepSeekPricing.localWeeklyPattern(around: now, timeZone: .current)
                     + ". Off-peak is half price.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .help(DeepSeekPricing.detail(at: now))
        }
    }
}

/// A nudge when an action would run while DeepSeek charges peak rates.
private struct PeakRateNotice: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = DeepSeekPricing.state(at: context.date)
            if state.isPeak, let end = state.changesAt {
                Label("Peak rates right now — they drop at "
                      + DeepSeekPricing.transitionLabel(end, from: context.date)
                      + " (off-peak is half price).",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Whisper model state, and the button that fetches it before the first note.
private struct TranscriptionStatusRow: View {
    @ObservedObject var transcriber: Transcriber

    private var canDownload: Bool {
        switch transcriber.state {
        case .idle, .failed: return true
        case .loading, .ready: return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            switch transcriber.state {
            case .idle:
                if transcriber.isModelDownloaded {
                    Text("Model downloaded — it loads on first use.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Model not downloaded yet.").font(.caption).foregroundStyle(.secondary)
                }
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading the model — the first download is large.").font(.caption).foregroundStyle(.secondary)
            case .ready:
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            if canDownload {
                Button(transcriber.isModelDownloaded ? "Load Model" : "Download Model") { transcriber.prepare() }
                    .font(.caption)
            }
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
    @State private var chats: [ChatSummary] = []
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
                        Text("\(chat.isGroup ? "group" : "1:1") · \(chat.messageCount) msgs · \(chat.sourceLabel ?? "chat") · \(chat.jid)")
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

    private var filtered: [ChatSummary] {
        let q = filter.lowercased()
        return q.isEmpty ? chats : chats.filter { $0.name.lowercased().contains(q) || $0.jid.contains(q) }
    }

    private func load() {
        Task.detached {
            let store = ChatStoreResolver.resolve(source: .auto)
            defer { store.close() }
            do {
                let list = try store.listChats(limit: 500)
                await MainActor.run { chats = list }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}
