import Foundation
import SwiftUI

/// In-process ring buffer of recent diagnostic events. Mirrors the most
/// useful log lines so the user can see what's going on without `log show`.
///
/// Sites call `DiagSink.shared.info(...)` alongside their normal `Logger`
/// calls — Logger goes to the unified log, DiagSink populates the in-app
/// Diagnostics view. Capped at 200 entries.
@MainActor
final class DiagSink: ObservableObject {
    static let shared = DiagSink()

    enum Level: Sendable {
        case info, warn, error
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 200

    func info(_ category: String, _ message: String)  { append(category, .info,  message) }
    func warn(_ category: String, _ message: String)  { append(category, .warn,  message) }
    func error(_ category: String, _ message: String) { append(category, .error, message) }

    func clear() { entries.removeAll() }

    private func append(_ category: String, _ level: Level, _ message: String) {
        entries.append(Entry(timestamp: Date(), category: category, level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
