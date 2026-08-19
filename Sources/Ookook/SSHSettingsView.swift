import AppKit
import SwiftUI

/// Saved SSH destinations: a list on the left, one editor on the right.
///
/// The shape is deliberately familiar - it is the same arrangement JetBrains
/// and Terminal.app use for saved hosts - because the whole value of this pane
/// is that you do not have to think about where anything is.
struct SSHSettingsView: View {
    @ObservedObject var store: SSHConnectionStore
    /// Offered as the scope for "only this project"; nil with nothing open.
    let projects: [(id: String, name: String)]

    @State private var selection: UUID?
    @State private var draft: SSHConnection?
    @State private var testResult: SSHTester.Result?
    @State private var testing = false
    @State private var importMessage: String?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
            editor
                .frame(minWidth: 380)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: selection) { loadDraft() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.connections) { connection in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.displayName)
                            .lineLimit(1)
                        if !connection.destination.isEmpty, connection.displayName != connection.destination {
                            Text(connection.destination)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(connection.id)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 2) {
                Button { addConnection() } label: { Image(systemName: "plus") }
                    .help("New connection")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Delete connection")
                Button { duplicateSelected() } label: { Image(systemName: "doc.on.doc") }
                    .disabled(selection == nil)
                    .help("Duplicate connection")
                Spacer()
                Button {
                    let count = store.importSSHConfig()
                    importMessage = count == 0
                        ? "Nothing new in ~/.ssh/config"
                        : "Imported \(count) host\(count == 1 ? "" : "s")"
                    selectFirstIfNeeded()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import hosts from ~/.ssh/config")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let draft {
            Form {
                Section {
                    TextField("Name", text: binding(\.name), prompt: Text(draft.destination))
                    HStack {
                        TextField("Host", text: binding(\.host), prompt: Text("deploy.example.com"))
                        Text("Port")
                            .foregroundStyle(.secondary)
                        // Grouping would render 22445 as "22.445" in a locale
                        // that groups with a dot - a port number is not a
                        // quantity and must never be grouped.
                        TextField("Port", value: binding(\.port),
                                  format: .number.grouping(.never))
                            .frame(width: 64)
                            .labelsHidden()
                    }
                    TextField("Username", text: binding(\.username), prompt: Text("root"))
                }

                Section {
                    Picker("Authentication", selection: binding(\.authentication)) {
                        ForEach(SSHConnection.Authentication.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    if draft.authentication == .keyFile {
                        HStack {
                            TextField("Private key", text: binding(\.identityFile),
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Choose…") { chooseKey() }
                        }
                    }
                    // Saying this out loud matters: someone looking for a
                    // password field should know why there isn't one.
                    Text("Ookook never stores passwords. With password auth, ssh asks in the terminal and you type it there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Run on connect", text: binding(\.remoteCommand),
                              prompt: Text("cd /var/www/app"))
                    TextField("Extra ssh options", text: binding(\.extraOptions),
                              prompt: Text("-A -J bastion"))
                    Picker("Available in", selection: binding(\.projectID)) {
                        Text("All projects").tag(String?.none)
                        ForEach(projects, id: \.id) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                }

                Section("Command") {
                    Text(draft.commandLine())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Test Connection") { test() }
                            .disabled(!draft.isUsable || testing)
                        if testing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let testResult {
                            Label(testResult.message,
                                  systemImage: testResult.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(testResult.ok ? .green : .orange)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 6) {
                Text("No connection selected").font(.headline)
                Text("Add one with +, or import your ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Editing

    /// Edits write straight through to the store: an explicit Save button here
    /// would be a second source of truth for something the menus read live.
    private func binding<Value>(_ path: WritableKeyPath<SSHConnection, Value>) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: path] ?? SSHConnection()[keyPath: path] },
            set: { newValue in
                guard var draft else { return }
                draft[keyPath: path] = newValue
                self.draft = draft
                store.update(draft)
            })
    }

    private func selectFirstIfNeeded() {
        if selection == nil || !store.connections.contains(where: { $0.id == selection }) {
            selection = store.connections.first?.id
        }
        loadDraft()
    }

    private func loadDraft() {
        testResult = nil
        draft = store.connections.first { $0.id == selection }
    }

    private func addConnection() {
        var connection = SSHConnection()
        connection.name = "New Connection"
        store.add(connection)
        selection = connection.id
        loadDraft()
    }

    private func removeSelected() {
        guard let selection else { return }
        store.remove(selection)
        selectFirstIfNeeded()
    }

    private func duplicateSelected() {
        guard let selection, let copy = store.duplicate(selection) else { return }
        self.selection = copy.id
        loadDraft()
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "Choose a private key file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding(\.identityFile).wrappedValue = url.path
    }

    private func test() {
        guard let draft else { return }
        testing = true
        testResult = nil
        Task {
            let result = await SSHTester.test(draft)
            await MainActor.run {
                testing = false
                testResult = result
            }
        }
    }
}

/// Checks a connection without ever prompting.
///
/// Runs in two steps because they fail for different reasons and the difference
/// is what the user needs: a TCP connect proves the host is reachable and the
/// port right, then `BatchMode=yes` proves the *key* works. BatchMode is what
/// keeps the test from hanging on a password prompt no one can answer - a host
/// that only takes passwords is reported as reachable, not broken.
enum SSHTester {
    struct Result {
        let ok: Bool
        let message: String
    }

    static func test(_ connection: SSHConnection) async -> Result {
        let host = connection.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return Result(ok: false, message: "No host set.") }

        guard await reachable(host: host, port: connection.port) else {
            return Result(ok: false, message: "Cannot reach \(host):\(connection.port).")
        }
        if connection.authentication == .password {
            return Result(ok: true, message: "Reachable. Password is typed at the prompt.")
        }

        let (status, output) = await run(connection)
        if status == 0 {
            return Result(ok: true, message: "Connected as \(output.isEmpty ? connection.username : output).")
        }
        // 255 is ssh's own failure code; anything else came from the remote.
        let detail = output.isEmpty ? "authentication failed" : output
        return Result(ok: false, message: "Reachable, but \(detail)")
    }

    private static func reachable(host: String, port: Int) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-z", "-G", "5", "-w", "5", host, String(port)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private static func run(_ connection: SSHConnection) async -> (Int32, String) {
        await Task.detached(priority: .utility) { () -> (Int32, String) in
            var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                             "-o", "StrictHostKeyChecking=accept-new"]
            if connection.port != 22 { arguments += ["-p", String(connection.port)] }
            if connection.authentication == .keyFile {
                let path = (connection.identityFile as NSString).expandingTildeInPath
                if !path.isEmpty { arguments += ["-i", path, "-o", "IdentitiesOnly=yes"] }
            }
            arguments.append(connection.destination)
            arguments.append("echo $USER@$(hostname -s)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // ssh's diagnostics are multi-line; the last line is the reason.
            let lastLine = text.components(separatedBy: .newlines).last ?? text
            return (process.terminationStatus, lastLine)
        }.value
    }
}
