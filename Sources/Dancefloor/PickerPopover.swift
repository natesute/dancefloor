import AppKit
import SwiftUI

@MainActor
protocol DancefloorController: AnyObject {
    func addDancer(from item: PickerItem) async throws
    func randomiseAll()
    func removeAllDancers()
    func openFolder()
    func closePicker()
    var syncOffset: Double { get set }
}

@MainActor
final class PickerModel: ObservableObject {
    enum Browse: Equatable {
        case term(String)
        case folder
    }

    @Published var query = ""
    @Published private(set) var browse: Browse = .folder
    @Published private(set) var items: [PickerItem] = []
    @Published private(set) var isLoading = false
    @Published var message: String?
    @Published private(set) var addingID: String?
    @Published var showSettings = false
    @Published var addingTerm = false
    @Published var newTerm = ""
    @Published var keyDraft = ""
    /// Only set when audio capture has failed; otherwise the popover shows no status.
    @Published var audioProblem: String?
    @Published private(set) var terms: [String] = []
    @Published private(set) var hasKey = false
    @Published var mode: SourceMode = .both {
        didSet { library.mode = mode }
    }
    @Published private(set) var syncMs = 0

    let library: GifLibrary
    weak var controller: DancefloorController?
    private var loadTask: Task<Void, Never>?

    init(library: GifLibrary) {
        self.library = library
        refresh()
    }

    /// Re-read settings and reload the grid. Called each time the popover opens.
    func refresh() {
        terms = library.randomTerms
        hasKey = library.giphyKey != nil
        mode = library.mode
        syncMs = Int(((controller?.syncOffset ?? 0) * 1000).rounded())
        if !hasKey {
            browse = .folder
        } else if case .folder = browse, items.isEmpty, let first = terms.first {
            browse = .term(first)
        }
        if items.isEmpty || browse == .folder { reload() }
    }

    func select(_ newBrowse: Browse) {
        browse = newBrowse
        if case .term(let t) = newBrowse, !terms.contains(t) { query = t } else { query = "" }
        reload()
    }

    func submitSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        select(.term(q))
    }

    private func reload() {
        loadTask?.cancel()
        message = nil
        switch browse {
        case .folder:
            isLoading = false
            items = library.localItems()
        case .term(let term):
            isLoading = true
            items = []
            loadTask = Task {
                do {
                    let results = try await library.giphyItems(for: term)
                    guard !Task.isCancelled else { return }
                    items = results
                } catch {
                    guard !Task.isCancelled else { return }
                    message = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    func add(_ item: PickerItem) {
        guard addingID == nil else { return }
        addingID = item.id
        controller?.closePicker()
        Task {
            do { try await controller?.addDancer(from: item) } catch { message = error.localizedDescription }
            addingID = nil
        }
    }

    func commitNewTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        newTerm = ""
        addingTerm = false
        guard !term.isEmpty else { return }
        if !terms.contains(term) { library.randomTerms = terms + [term] }
        terms = library.randomTerms
        select(.term(term))
    }

    func removeTerm(_ term: String) {
        library.randomTerms = terms.filter { $0 != term }
        terms = library.randomTerms
    }

    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        keyDraft = ""
        guard !key.isEmpty else { return }
        library.giphyKey = key
        hasKey = true
        showSettings = false
        select(.term(terms.first ?? "dance"))
    }

    func nudgeSync(_ delta: Double) {
        guard let controller else { return }
        controller.syncOffset = delta == 0 ? 0.05 : controller.syncOffset + delta
        syncMs = Int((controller.syncOffset * 1000).rounded())
    }
}

// MARK: - Views

struct PickerView: View {
    static let size = CGSize(width: 360, height: 520)
    @ObservedObject var model: PickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.audioProblem {
                Label(problem, systemImage: "speaker.slash").font(.system(size: 11)).foregroundStyle(.red)
            }
            if model.showSettings {
                SettingsPane(model: model)
            } else {
                BrowsePane(model: model)
            }
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Shuffle and settings, beside the search field (settings swaps to a back button).
@MainActor
private func toolbarButtons(model: PickerModel) -> some View {
    HStack(spacing: 10) {
        if !model.showSettings {
            Button { model.controller?.randomiseAll() } label: { Image(systemName: "shuffle") }
                .help("Randomise all dancers")
        }
        Button { model.showSettings.toggle() } label: {
            Image(systemName: model.showSettings ? "chevron.backward" : "gearshape")
        }
        .help(model.showSettings ? "Back" : "Settings")
    }
    .font(.system(size: 13))
    .buttonStyle(.borderless)
}

private struct BrowsePane: View {
    @ObservedObject var model: PickerModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        if model.hasKey {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search GIPHY", text: $model.query)
                        .textFieldStyle(.plain)
                        .onSubmit { model.submitSearch() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                toolbarButtons(model: model)
            }
            chips
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    TextField("Paste GIPHY API key", text: $model.keyDraft)
                        .textFieldStyle(.plain)
                        .onSubmit { model.saveKey() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                toolbarButtons(model: model)
            }
        }

        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                if model.isLoading {
                    ForEach(0..<9, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)).aspectRatio(1, contentMode: .fit)
                    }
                } else {
                    ForEach(model.items) { item in
                        PickerTile(item: item, isBusy: model.addingID == item.id) { model.add(item) }
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { chipRow }
        }
    }

    @ViewBuilder private var chipRow: some View {
            Chip(title: "My folder", icon: "folder", isOn: model.browse == .folder) { model.select(.folder) }
            ForEach(model.terms, id: \.self) { term in
                Chip(title: term, isOn: model.browse == .term(term)) { model.select(.term(term)) }
                    .contextMenu { Button("Remove \"\(term)\"") { model.removeTerm(term) } }
            }
            if model.addingTerm {
                TextField("new search", text: $model.newTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 90)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().stroke(Color.accentColor))
                    .onSubmit { model.commitNewTerm() }
                    .onExitCommand { model.addingTerm = false }
            } else {
                Chip(title: "", icon: "plus", isOn: false) { model.addingTerm = true }.help("Add a search")
            }
    }
}

private struct Chip: View {
    let title: String
    var icon: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                if !title.isEmpty { Text(title) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.accentColor : .secondary)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsPane: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                toolbarButtons(model: model)
            }

            row("Dancers from") {
                Picker("", selection: $model.mode) {
                    ForEach(SourceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150)
            }

            row("Sync") {
                HStack(spacing: 4) {
                    Button { model.nudgeSync(-0.02) } label: { Image(systemName: "minus") }
                    Text("\(model.syncMs) ms").monospacedDigit().frame(width: 52)
                    Button { model.nudgeSync(0.02) } label: { Image(systemName: "plus") }
                    Button("Reset") { model.nudgeSync(0) }.buttonStyle(.borderless)
                }
            }

            row("GIPHY key") {
                HStack(spacing: 4) {
                    TextField(model.hasKey ? "Saved. Paste to replace" : "Paste API key", text: $model.keyDraft)
                        .frame(width: 150)
                        .onSubmit { model.saveKey() }
                    Button("Save") { model.saveKey() }.disabled(model.keyDraft.isEmpty)
                }
            }

            Divider()
            Button("Open my GIF folder") { model.controller?.openFolder() }
            Button("Remove all dancers") { model.controller?.removeAllDancers() }
            Button("Quit Dancefloor") { NSApp.terminate(nil) }
            Spacer()
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
            Spacer()
            content().buttonStyle(.bordered)
        }
    }
}
