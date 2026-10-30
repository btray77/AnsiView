import AnsiCore
import AppKit
import SwiftUI

/// The saved BBS list in the app's own user defaults (not the suite shared with Quick Look).
final class BBSAddressBookStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var book: BBSAddressBook {
        didSet { defaults.set(book.encoded(), forKey: BBSAddressBook.defaultsKey) }
    }

    var defaultsForTesting: UserDefaults { defaults }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        book = BBSAddressBook(data: defaults.data(forKey: BBSAddressBook.defaultsKey))
    }

    func save(_ entry: BBSEntry) {
        if let index = book.entries.firstIndex(where: { $0.id == entry.id }) {
            book.entries[index] = entry
        } else {
            book.entries.append(entry)
        }
    }

    func remove(id: UUID) {
        book.entries.removeAll { $0.id == id }
    }
}

/// File > Connect to BBS...: quick connect by address, or pick and edit a saved BBS.
struct BBSConnectView: View {
    @ObservedObject var store: BBSAddressBookStore
    var connect: (BBSEntry) -> Void
    @State private var quickAddress = ""
    @State private var selection: UUID?
    @State private var draft = BBSEntry(name: "", host: "")
    @State private var problem: String?

    private static let speeds = PlaybackSpeed.choices

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Address:")
                TextField("bbs.example.com:23", text: $quickAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(quickConnect)
                Button("Connect", action: quickConnect)
                    .disabled(quickAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if store.book.entries.isEmpty {
                        Text("No saved BBSes yet. Type an address above, for example bbs.example.com, and press Connect. To save one, fill in the details on the right and press Save.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        List(selection: $selection) {
                            ForEach(store.book.entries) { entry in
                                VStack(alignment: .leading) {
                                    Text(entry.name.isEmpty ? entry.host : entry.name)
                                    Text(entry.address).font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(entry.id)
                            }
                        }
                    }
                    HStack {
                        Button {
                            selection = nil
                            draft = BBSEntry(name: "", host: "")
                        } label: { Image(systemName: "plus") }
                            .help("New BBS")
                        Button {
                            if let selection { store.remove(id: selection) }
                            selection = nil
                            draft = BBSEntry(name: "", host: "")
                        } label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                            .help("Remove the selected BBS")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 230)
                Divider()
                details
            }
        }
        .frame(minWidth: 700, minHeight: 440)
        .onChange(of: selection) { id in
            if let id, let entry = store.book.entries.first(where: { $0.id == id }) { draft = entry }
        }
    }

    private var details: some View {
        VStack(alignment: .leading) {
            Form {
                TextField("Name:", text: $draft.name, prompt: Text("My favourite BBS"))
                TextField("Host:", text: $draft.host, prompt: Text("bbs.example.com"))
                TextField("Port:", value: $draft.port, format: .number.grouping(.never))
                TextField("Username:", text: Binding(get: { draft.username ?? "" },
                                                     set: { draft.username = $0.isEmpty ? nil : $0 }),
                          prompt: Text("optional, typed by Terminal > Send Username"))
                Picker("Font:", selection: $draft.fontName) {
                    ForEach(BitmapFont.supportedNames, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size:") {
                    HStack {
                        TextField("Columns", value: $draft.columns, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 60)
                        Text("x")
                        TextField("Rows", value: $draft.rows, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 60)
                        Text("columns x rows").foregroundStyle(.secondary)
                    }
                }
                Picker("Encoding:", selection: $draft.encoding) {
                    ForEach(TextEncoding.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Protocol:", selection: $draft.mode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Speed:", selection: $draft.baud) {
                    ForEach(Self.speeds, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) baud").tag($0) }
                }
                Toggle("Backspace sends DEL (127) instead of BS (8)", isOn: $draft.backspaceSendsDelete)
            }
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Save") { if let entry = validated() { store.save(entry); selection = entry.id } }
                Button("Connect") { if let entry = validated() { connect(entry) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// The draft with its size clamped, or nil (and a message) when the host or port is unusable.
    private func validated() -> BBSEntry? {
        var entry = draft
        entry.host = entry.host.trimmingCharacters(in: .whitespaces)
        guard let parsed = BBSAddress.parse(entry.host, defaultPort: entry.port), (1...65535).contains(entry.port) else {
            problem = "Enter a host name or address, and a port from 1 to 65535."
            return nil
        }
        entry.host = parsed.host
        entry.port = parsed.port
        entry.columns = min(255, max(1, entry.columns))
        entry.rows = min(255, max(1, entry.rows))
        if entry.name.trimmingCharacters(in: .whitespaces).isEmpty { entry.name = entry.host }
        problem = nil
        draft = entry
        return entry
    }

    private func quickConnect() {
        guard let parsed = BBSAddress.parse(quickAddress) else {
            problem = "\"\(quickAddress)\" is not an address. Try a host name such as bbs.example.com, or host:port."
            return
        }
        problem = nil
        connect(BBSEntry(name: parsed.host, host: parsed.host, port: parsed.port))
    }
}

final class BBSConnectWindowController: NSWindowController, NSWindowDelegate {
    private static var current: BBSConnectWindowController?

    static func show() {
        if let current {
            current.showWindow(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Connect to BBS"
        window.contentView = makeContentView(store: BBSAddressBookStore())
        let controller = BBSConnectWindowController(window: window)
        window.delegate = controller
        window.center()
        current = controller
        controller.showWindow(nil)
    }

    static func makeContentView(store: BBSAddressBookStore) -> NSView {
        NSHostingView(rootView: BBSConnectView(store: store) { entry in
            TerminalWindowController.open(entry: entry)
        })
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
