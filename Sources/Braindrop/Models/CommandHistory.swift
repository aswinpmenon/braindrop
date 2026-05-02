import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let query: String
    let command: String
    let timestamp: Date
    let files: [String]
}

class CommandHistory: ObservableObject {
    static let shared = CommandHistory()
    @Published var entries: [HistoryEntry] = []
    private let maxEntries = 100

    private init() { load() }

    func add(query: String, command: String, files: [String]) {
        let entry = HistoryEntry(id: UUID(), query: query, command: command, timestamp: Date(), files: files)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    func previous(before index: Int) -> HistoryEntry? {
        guard index < entries.count else { return entries.last }
        return entries[index]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: "commandHistory")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "commandHistory"),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: "commandHistory")
    }
}
