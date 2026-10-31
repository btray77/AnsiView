import AnsiCore
import SwiftUI

/// AnsiView for iPhone and iPad: a viewer for ANSI and other text mode art (plan 8). The BBS
/// terminal, editor, file transfers and ANSI music are Mac only.
@main
struct AnsiViewMobileApp: App {
    @StateObject private var library = ArtLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: ArtLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: ArtItem?
    @State private var importing = false
    @State private var openError: String?
    /// Both columns from the start, so an iPad in portrait shows the list instead of an empty viewer.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section(String(localized: "Samples")) {
                    ForEach(library.samples) { row($0, symbol: "sparkles") }
                }
                Section {
                    if library.documents.isEmpty {
                        Text(String(localized: "Copy art into the AnsiView folder in the Files app and it appears here."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.documents) { row($0, symbol: "doc") }
                } header: {
                    Text(UIDevice.current.userInterfaceIdiom == .pad
                         ? String(localized: "On This iPad") : String(localized: "On This iPhone"))
                }
                if !library.opened.isEmpty {
                    Section(String(localized: "Opened")) {
                        ForEach(library.opened) { row($0, symbol: "folder") }
                    }
                }
            }
            .navigationTitle("AnsiView")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label(String(localized: "Open from Files"), systemImage: "folder.badge.plus")
                    }
                }
            }
            .refreshable { library.refresh() }
        } detail: {
            NavigationStack {
                if let selection {
                    ViewerScreen(item: selection).id(selection)
                } else {
                    ContentUnavailableView(String(localized: "No Art Selected"), systemImage: "square.grid.3x3.fill",
                                           description: Text(String(localized: "Choose a sample, or open art from Files.")))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $importing, allowedContentTypes: ArtLoader.contentTypes) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): openError = error.localizedDescription
            }
        }
        .onOpenURL { open($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .alert(String(localized: "Cannot Open"), isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .onAppear(perform: debugLaunch)
    }

    private func row(_ item: ArtItem, symbol: String) -> some View {
        NavigationLink(value: item) {
            Label(item.name, systemImage: symbol)
        }
    }

    private func open(_ url: URL) {
        do {
            selection = try library.open(url)
        } catch {
            openError = error.localizedDescription
        }
    }

    /// Verification hooks for the simulator, where nothing can be tapped: `-open <name>` shows a
    /// sample or Documents file, `-quicklook <name>` shows it in the system Quick Look viewer (which
    /// loads the preview extension), `-thumbnail <name>` asks the system for its thumbnail.
    private func debugLaunch() {
        #if DEBUG
        let arguments = UserDefaults.standard
        if let name = arguments.string(forKey: "open"), let item = library.item(named: name) {
            selection = item
            if arguments.bool(forKey: "hideSidebar") { columns = .detailOnly }
        }
        if let name = arguments.string(forKey: "quicklook"), let item = library.item(named: name) {
            DebugQuickLook.present(item.url)
        }
        if let name = arguments.string(forKey: "thumbnail"), let item = library.item(named: name) {
            DebugQuickLook.thumbnail(item.url)
        }
        #endif
    }
}
