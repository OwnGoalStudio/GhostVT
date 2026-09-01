//
//  LogViewerView.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Settings ▸ Advanced ▸ Logs: the app's journal or the helper's file, one
/// row per entry, newest at the bottom. The ⋯ menu picks the source (and,
/// for the app, the launch), filters by level and tag, refreshes, shares
/// the file, and trims the journal; the search field narrows the rows to
/// the ones containing the text. Reads are `LogReader`'s; nothing here
/// writes a log line.
struct LogViewerView: View {
    @StateObject private var model = LogViewerModel()
    @State private var window: UIWindow?

    var body: some View {
        content
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            // Placement left to the platform: the drawer variant sat under
            // the title at half again the field's height on the iPad.
            .searchable(text: $model.searchText, prompt: Text("Search Logs"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    menu
                }
            }
            .background(WindowReader(window: $window))
            .onAppear(perform: model.reload)
    }

    @ViewBuilder
    private var content: some View {
        let entries = model.visibleEntries
        if entries.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(entries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    } header: {
                        header(count: entries.count)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    scrollToEnd(proxy)
                }
                .onChange(of: model.document.readAt) { _ in
                    scrollToEnd(proxy)
                }
            }
        }
    }

    /// The file's name and how many rows are showing, above the first row.
    private func header(count: Int) -> some View {
        HStack(spacing: DS.Padding.s) {
            Image(systemName: "doc.text")
            Text(verbatim: model.fileName)
            Text(String.localizedStringWithFormat(
                NSLocalizedString("%lld entries", comment: "A log entry count"),
                count
            ))
            .foregroundColor(Color.secondary.opacity(0.7))
        }
        .font(DS.Font.caption)
        .foregroundColor(.secondary)
        .textCase(nil)
    }

    /// Nothing to show: still reading, an empty log, or no file at all.
    private var emptyState: some View {
        VStack(spacing: DS.Padding.m) {
            if model.isLoading {
                ProgressView()
            } else {
                Image(systemName: model.document.unreadable ? "doc.text.magnifyingglass" : "doc.text")
                    .font(DS.Font.heroSymbol)
                    .foregroundColor(.secondary)
                if model.document.unreadable {
                    Text("The log file could not be read.")
                        .font(DS.Font.body)
                        .foregroundColor(.secondary)
                } else {
                    Text("No log entries.")
                        .font(DS.Font.body)
                        .foregroundColor(.secondary)
                }
                Text(verbatim: model.document.location)
                    .font(DS.Font.codeCaption)
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Padding.xl)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.visibleEntries.last else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var menu: some View {
        Menu {
            Picker("Source", selection: $model.source) {
                Label("App", systemImage: "app")
                    .tag(LogSource.app)
                Label("Terminal Helper", systemImage: "terminal")
                    .tag(LogSource.daemon)
            }
            if model.source == .app {
                if !model.olderLaunches.isEmpty {
                    Menu {
                        Picker("Launch", selection: $model.launch) {
                            Text("Current Launch")
                                .tag(URL?.none)
                            ForEach(model.olderLaunches) { launch in
                                Text(verbatim: model.title(of: launch))
                                    .tag(Optional(launch.url))
                            }
                        }
                    } label: {
                        Label("Launch", systemImage: "clock")
                    }
                }
                // The helper's lines carry no level; the filter would only
                // hide everything.
                Menu {
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Toggle(isOn: model.binding(for: level)) {
                            Text(level.title)
                        }
                    }
                } label: {
                    Label("Level", systemImage: "slider.horizontal.3")
                }
            }
            if !model.document.categories.isEmpty {
                Menu {
                    Toggle(isOn: model.allCategoriesBinding) {
                        Text("All Categories")
                    }
                    Divider()
                    ForEach(model.document.categories, id: \.self) { category in
                        Toggle(isOn: model.binding(for: category)) {
                            Text(verbatim: category)
                        }
                    }
                } label: {
                    Label("Category", systemImage: "tag")
                }
            }
            Divider()
            Button(action: model.reload) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button(action: share) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if model.source == .app, !model.olderLaunches.isEmpty {
                Divider()
                Button(role: .destructive, action: model.deleteOlderLaunches) {
                    Label("Delete Older Logs", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func share() {
        guard let url = LogReader.exportFile(model.source, launch: model.launch) else { return }
        ShareSheet.present(url, in: window)
    }
}

/// One entry: the message in monospace, the stamp and tag beneath, the
/// level in the colour — and, for trouble, a tint under the row.
private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Padding.xs) {
            Text(verbatim: entry.message)
                .font(DS.Font.code)
                .foregroundColor(messageColor)
            HStack(spacing: DS.Padding.xs) {
                if !entry.timestamp.isEmpty {
                    Text(verbatim: entry.timestamp)
                    Text(verbatim: "·")
                }
                Text(verbatim: entry.category)
                if entry.level != .info {
                    Text(verbatim: "·")
                    Text(entry.level.title)
                }
            }
            .font(DS.Font.codeCaption)
            .foregroundColor(metaColor)
        }
        .padding(.vertical, DS.Padding.xs)
        .listRowBackground(rowBackground)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.message
            } label: {
                Label("Copy Message", systemImage: "text.quote")
            }
        }
    }

    private var messageColor: Color {
        switch entry.level {
        case .verbose: .secondary
        case .info: .primary
        case .warning: .orange
        case .error, .critical: .red
        }
    }

    private var metaColor: Color {
        switch entry.level {
        case .warning: Color.orange.opacity(0.8)
        case .error, .critical: Color.red.opacity(0.8)
        default: Color.secondary.opacity(0.7)
        }
    }

    private var rowBackground: Color? {
        switch entry.level {
        case .warning: Color.orange.opacity(0.06)
        case .error, .critical: Color.red.opacity(0.06)
        default: nil
        }
    }
}

extension LogEntry.Level {
    var title: LocalizedStringKey {
        switch self {
        case .verbose: "Verbose"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        case .critical: "Critical"
        }
    }
}

/// The viewer's state: which log, which launch, the filters, and the last
/// read. Reads happen off the main actor and land back on it, so a large
/// journal never stalls the sheet.
@MainActor
final class LogViewerModel: ObservableObject {
    @Published var source: LogSource = .app {
        didSet { if source != oldValue { reload() } }
    }

    /// The journal file to read; nil is this launch's.
    @Published var launch: URL? {
        didSet { if launch != oldValue { reload() } }
    }

    @Published var levels: Set<LogEntry.Level> = Set(LogEntry.Level.allCases)
    /// Empty means every tag.
    @Published var categories: Set<String> = []
    @Published var searchText = ""
    @Published private(set) var document = LogDocument()
    @Published private(set) var launches: [LogLaunch] = []
    @Published private(set) var isLoading = false

    /// Every launch but this one, newest first.
    var olderLaunches: [LogLaunch] {
        let current = AppLog.currentFile?.standardizedFileURL
        return launches.filter { $0.url.standardizedFileURL != current }
    }

    var fileName: String {
        (document.location as NSString).lastPathComponent
    }

    var visibleEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.entries.filter { entry in
            (source == .daemon || levels.contains(entry.level))
                && (categories.isEmpty || categories.contains(entry.category))
                && (query.isEmpty || entry.text.localizedCaseInsensitiveContains(query))
        }
    }

    func reload() {
        let source = source
        let launch = launch
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let launches = LogReader.launches()
            let document = LogReader.read(source, launch: launch)
            await MainActor.run { [weak self] in
                guard let self, self.source == source, self.launch == launch else { return }
                self.launches = launches
                self.document = document
                self.isLoading = false
            }
        }
    }

    func deleteOlderLaunches() {
        LogReader.deleteOlderLaunches()
        if launch != nil {
            launch = nil // reloads
        } else {
            reload()
        }
    }

    func title(of launch: LogLaunch) -> String {
        guard let date = launch.date else { return launch.url.lastPathComponent }
        return Self.launchTitleFormatter.string(from: date)
    }

    private static let launchTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func binding(for level: LogEntry.Level) -> Binding<Bool> {
        Binding(
            get: { self.levels.contains(level) },
            set: { on in
                if on {
                    self.levels.insert(level)
                } else {
                    self.levels.remove(level)
                }
            }
        )
    }

    func binding(for category: String) -> Binding<Bool> {
        Binding(
            get: { self.categories.contains(category) },
            set: { on in
                if on {
                    self.categories.insert(category)
                } else {
                    self.categories.remove(category)
                }
            }
        )
    }

    var allCategoriesBinding: Binding<Bool> {
        Binding(
            get: { self.categories.isEmpty },
            set: { on in
                if on {
                    self.categories = []
                }
            }
        )
    }
}
