import SwiftUI

/// The settings window: Claude Code's own configuration on the left tabs,
/// Ookook's preferences on the last one.
///
/// Everything here edits real files under `~/.claude`, so the view never writes
/// on keystroke - edits stay in a local draft until Save, and Save always shows
/// what happened.
struct SettingsView: View {
    @ObservedObject var store: ClaudeConfigStore
    @ObservedObject var ssh: SSHConnectionStore
    /// For scoping a connection to one project.
    let projects: [(id: String, name: String)]

    var body: some View {
        TabView {
            ClaudeSettingsTab(store: store)
                .tabItem { Label("Claude Code", systemImage: "sparkles") }
            AgentsTab(store: store)
                .tabItem { Label("Agents", systemImage: "person.2") }
            MCPTab(store: store)
                .tabItem { Label("MCP", systemImage: "server.rack") }
            SSHSettingsView(store: ssh, projects: projects)
                .tabItem { Label("SSH", systemImage: "network") }
            TerminalAppearanceTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            OokookPreferencesTab()
                .tabItem { Label("Ookook", systemImage: "gearshape") }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { store.reload() }
    }
}

/// Claude Code reads its settings at process start; a running session keeps the
/// values it launched with. Saying so once, next to the controls, saves a long
/// "why did nothing change" detour.
private struct RestartNotice: View {
    var body: some View {
        Label(
            "Changes apply to Claude Code sessions started after saving. Restart a running session to pick them up.",
            systemImage: "arrow.clockwise.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Claude Code settings

private struct ClaudeSettingsTab: View {
    @ObservedObject var store: ClaudeConfigStore
    @State private var scope: Scope = .user

    enum Scope: String, CaseIterable, Identifiable {
        case user = "User"
        case local = "User (local)"
        case project = "Project"
        var id: String { rawValue }
    }

    private var document: ClaudeSettingsDocument? {
        switch scope {
        case .user: return store.userSettings
        case .local: return store.userLocalSettings
        case .project: return store.projectSettings
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("File", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.rawValue)
                        .tag(scope)
                        // Only the project segment depends on a project being
                        // open; disabling the whole control would lock the user
                        // out of the user-local file, which is where their
                        // permission list actually lives.
                        .disabled(scope == .project && store.projectSettings == nil)
                }
            }
            .pickerStyle(.segmented)

            if let document {
                SettingsEditor(document: document, store: store)
                    // A fresh draft per file; without this the editor would keep
                    // the previous file's text after switching scope.
                    .id(document.url)
            } else {
                ContentUnavailableMessage(
                    title: "No project open",
                    detail: "Open a project in Ookook to edit its .claude/settings.json.")
            }

            if !store.loadErrors.isEmpty {
                ForEach(store.loadErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
    }
}

private struct SettingsEditor: View {
    @ObservedObject var store: ClaudeConfigStore
    /// The draft. Saving merges it back onto whatever is on disk at that moment.
    @State private var draft: ClaudeSettingsDocument
    @State private var original: ClaudeSettingsDocument
    @State private var newRule: [ClaudeSettingsDocument.PermissionList: String] = [:]

    init(document: ClaudeSettingsDocument, store: ClaudeConfigStore) {
        self.store = store
        _draft = State(initialValue: document)
        _original = State(initialValue: document)
    }

    private var isDirty: Bool { draft != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Model") {
                    TextField("Model", text: $draft.model, prompt: Text("opus, sonnet, or a full model id"))
                    TextField("Default permission mode", text: $draft.defaultMode, prompt: Text("auto, plan, acceptEdits…"))
                }

                Section("Permissions") {
                    ForEach(ClaudeSettingsDocument.PermissionList.allCases) { list in
                        PermissionListEditor(
                            list: list,
                            rules: draft.permissionRules(list),
                            draftRule: Binding(
                                get: { newRule[list] ?? "" },
                                set: { newRule[list] = $0 }),
                            onAdd: { rule in
                                var rules = draft.permissionRules(list)
                                rules.append(rule)
                                draft.setPermissionRules(list, rules)
                                newRule[list] = ""
                            },
                            onRemove: { index in
                                var rules = draft.permissionRules(list)
                                rules.remove(at: index)
                                draft.setPermissionRules(list, rules)
                            })
                    }
                }

                Section("Environment") {
                    EnvironmentEditor(
                        pairs: draft.environment,
                        onChange: { draft.setEnvironment($0) })
                }

                if !draft.untouchedKeys.isEmpty {
                    Section("Left untouched") {
                        Text(draft.untouchedKeys.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Ookook does not edit these keys. They are preserved exactly as written when you save.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shortPath(draft.url))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    RestartNotice()
                }
                Spacer()
                if let error = store.saveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Revert") { draft = original }
                    .disabled(!isDirty)
                Button("Save") {
                    store.save(draft)
                    // Only accept the draft as the new baseline if it actually
                    // reached disk; otherwise Save and Revert both disable and
                    // the edit cannot be retried.
                    if store.saveError == nil {
                        original = draft
                    }
                }
                .keyboardShortcut("s")
                .disabled(!isDirty)
            }
            .padding(.top, 10)
        }
    }

    private func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

private struct PermissionListEditor: View {
    let list: ClaudeSettingsDocument.PermissionList
    let rules: [String]
    @Binding var draftRule: String
    let onAdd: (String) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(list.title).font(.subheadline.weight(.semibold))
                Text(list.help).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack {
                    Text(rule).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button {
                        onRemove(index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add rule", text: $draftRule, prompt: Text("Bash(git status)"))
                    .onSubmit(add)
                Button("Add", action: add).disabled(trimmed.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private var trimmed: String { draftRule.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
    }
}

private struct EnvironmentEditor: View {
    let pairs: [(key: String, value: String)]
    let onChange: ([(key: String, value: String)]) -> Void
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                HStack {
                    Text(pair.key).font(.callout.monospaced())
                    Text("=").foregroundStyle(.secondary)
                    Text(pair.value).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        var updated = pairs
                        updated.remove(at: index)
                        onChange(updated)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Name", text: $newKey, prompt: Text("ANTHROPIC_MODEL"))
                TextField("Value", text: $newValue)
                Button("Add") {
                    let key = newKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    onChange(pairs.filter { $0.key != key } + [(key: key, value: newValue)])
                    newKey = ""
                    newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Exported into every tool call Claude Code makes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Agents

/// Read-only for v1, deliberately. An agent file is a Markdown prompt with YAML
/// frontmatter; round-tripping the body through an editor risks mangling prompts
/// that took real work to write, and the frontmatter alone is not worth that.
/// "Reveal in Finder" hands the file to a real editor instead.
private struct AgentsTab: View {
    @ObservedObject var store: ClaudeConfigStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.agents.isEmpty {
                ContentUnavailableMessage(
                    title: "No custom agents",
                    detail: "Agents live in ~/.claude/agents and <project>/.claude/agents as Markdown files with YAML frontmatter.")
            } else {
                List(store.agents) { agent in
                    AgentRow(agent: agent)
                }
                .listStyle(.inset)
            }
            Label("Read-only. Edit the Markdown file to change an agent.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct AgentRow: View {
    let agent: ClaudeAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(agent.name).font(.headline)
                if !agent.model.isEmpty {
                    Text(agent.model).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if agent.isProjectScoped {
                    Text("project").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([agent.url]) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if !agent.description.isEmpty {
                Text(agent.description).font(.callout).foregroundStyle(.secondary)
            }
            if !agent.tools.isEmpty {
                Text(agent.tools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(agent.extraFields, id: \.key) { field in
                Text("\(field.key): \(field.value)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - MCP

/// Also read-only: `~/.claude.json` is the CLI's live state file - it holds
/// session counters and per-project history that Claude Code rewrites constantly -
/// so Ookook reads `mcpServers` out of it and never writes it back.
private struct MCPTab: View {
    @ObservedObject var store: ClaudeConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.mcpServers.isEmpty {
                ContentUnavailableMessage(
                    title: "No MCP servers",
                    detail: "Servers are declared in ~/.claude.json and in a project's .mcp.json.")
            } else {
                List(store.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(server.name).font(.headline)
                            Text(server.transport).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(server.source).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text(server.summary).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !server.environmentKeys.isEmpty {
                            // Values are routinely API tokens; names are enough
                            // to tell whether a server is configured.
                            Text("env: " + server.environmentKeys.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            Label("Read-only. Restart Claude Code after changing MCP servers.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Ookook's own preferences

private struct OokookPreferencesTab: View {
    @AppStorage("viewMode") private var viewMode: String = ViewMode.single.rawValue
    @AppStorage("gridColumns") private var gridColumns: Int = 0
    @AppStorage("notifySound") private var notifySound: Bool = true
    @AppStorage("notifyBanners") private var notifyBanners: Bool = true
    @AppStorage(ClaudeLaunchOptions.skipPermissionsKey) private var skipPermissions: Bool = true
    @AppStorage(ClaudeLaunchOptions.codexBypassApprovalsAndSandboxKey)
    private var bypassCodexApprovalsAndSandbox: Bool = true

    var body: some View {
        Form {
            Section("Claude Code") {
                Toggle("Skip permission prompts (--dangerously-skip-permissions)",
                       isOn: $skipPermissions)
                Text("Agents run every tool call without asking - including writes, "
                     + "deletes and shell commands. Applies to sessions started from now on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Codex") {
                Toggle("Run with --yolo (bypass approvals and sandbox)",
                       isOn: $bypassCodexApprovalsAndSandbox)
                Text("Codex runs without asking and with unrestricted system access. "
                     + "Enable only in a workspace you fully trust. Applies to sessions started from now on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Layout") {
                // ViewMode is not CaseIterable and lives in a file this window
                // does not own, so the two cases are named here explicitly.
                Picker("View mode", selection: $viewMode) {
                    Text("Single").tag(ViewMode.single.rawValue)
                    Text("Grid").tag(ViewMode.grid.rawValue)
                }
                Picker("Grid columns", selection: $gridColumns) {
                    Text("Automatic").tag(0)
                    ForEach(1 ... 4, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            }
            Section("Alerts") {
                Toggle("Play sounds", isOn: $notifySound)
                Toggle("Show notifications", isOn: $notifyBanners)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        // Notifier reads these defaults directly, so the Alerts menu and this
        // pane stay in step without either owning the other.
        .onChange(of: notifySound) { Notifier.shared.soundEnabled = notifySound }
        .onChange(of: notifyBanners) { Notifier.shared.bannersEnabled = notifyBanners }
    }
}

/// Font and colours for every terminal. Changes are pushed to the live views,
/// so the preview below is the same renderer the real thing uses.
private struct TerminalAppearanceTab: View {
    @AppStorage(TerminalAppearance.Key.fontName) private var fontName: String = ""
    @AppStorage(TerminalAppearance.Key.fontSize) private var fontSize: Double = TerminalAppearance.defaultSize
    @AppStorage(TerminalAppearance.Key.theme) private var themeID: String = TerminalTheme.system.id

    private let families = TerminalAppearance.availableFonts

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $fontName) {
                    Text("System Monospace").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Slider(value: $fontSize, in: 9 ... 24, step: 1)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }

            Section("Theme") {
                Picker("Colours", selection: $themeID) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.inline)
                ThemePreview(theme: TerminalTheme.theme(id: themeID),
                             font: TerminalAppearance.font)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        // Every change repaints the running terminals; they are never rebuilt,
        // because rebuilding one would throw away its scrollback.
        .onChange(of: fontName) { TerminalAppearance.broadcast() }
        .onChange(of: fontSize) { TerminalAppearance.broadcast() }
        .onChange(of: themeID) { TerminalAppearance.broadcast() }
    }
}

/// Enough of a terminal to judge a palette without applying it first.
private struct ThemePreview: View {
    let theme: TerminalTheme
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("~/Projects/ookook %")
                .foregroundStyle(Color(nsColor: NSColor(hex: theme.foreground)))
            HStack(spacing: 0) {
                Text("claude").foregroundStyle(Color(nsColor: NSColor(hex: theme.ansi[5])))
                Text(" --dangerously-skip-permissions")
                    .foregroundStyle(Color(nsColor: NSColor(hex: theme.ansi[3])))
            }
            Text("✓ 3 files changed")
                .foregroundStyle(Color(nsColor: NSColor(hex: theme.ansi[2])))
            Text("✗ error: build failed")
                .foregroundStyle(Color(nsColor: NSColor(hex: theme.ansi[1])))
            HStack(spacing: 4) {
                ForEach(0 ..< 8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: NSColor(hex: theme.ansi[index + 8])))
                        .frame(width: 16, height: 8)
                }
            }
            .padding(.top, 4)
        }
        .font(Font(font as CTFont))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: NSColor(hex: theme.background)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Shared

/// `ContentUnavailableView` is macOS 14, but its message-only form reads heavier
/// than these panes want; this keeps the empty states quiet.
private struct ContentUnavailableMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
