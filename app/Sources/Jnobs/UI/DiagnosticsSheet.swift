import SwiftUI

/// Sheet showing the last ~200 diagnostic events captured by `DiagSink`.
/// Replaces the need to dig through Console.app / `log show`. Auto-scrolls
/// to the newest entry.
struct DiagnosticsSheet: View {
    @ObservedObject var sink: DiagSink
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var search: String = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case warn = "Warnings"
        case error = "Errors"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Jn.stroke)
            toolbar
            Divider().overlay(Jn.stroke)
            list
            Divider().overlay(Jn.stroke)
            footer
        }
        .frame(width: 600, height: 540)
        .jnPanelBackground()
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            SectionCaption(text: "Diagnostics", symbol: "doc.text.magnifyingglass")
            Spacer()
            Text("\(filtered.count) events")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Jn.inkFaint)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

            Button("Clear") { sink.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Jn.inkMute)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { e in
                        DiagEntryRow(entry: e).id(e.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: sink.entries.count) { _, _ in
                if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("In-app ring buffer — last 200 events. Full history is in the unified log under subsystem 'net.jfound.jnobs'.")
                .font(.caption2)
                .foregroundStyle(Jn.inkFaint)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .foregroundStyle(Jn.ink)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Jn.cardHi.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Jn.stroke, lineWidth: 1)
                        )
                )
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var filtered: [DiagSink.Entry] {
        sink.entries.filter { e in
            let levelOK: Bool = {
                switch filter {
                case .all: return true
                case .warn: return e.level == .warn || e.level == .error
                case .error: return e.level == .error
                }
            }()
            let searchOK = search.isEmpty
                || e.message.localizedCaseInsensitiveContains(search)
                || e.category.localizedCaseInsensitiveContains(search)
            return levelOK && searchOK
        }
    }
}

private struct DiagEntryRow: View {
    let entry: DiagSink.Entry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)
                .offset(y: 1)
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Jn.inkFaint)
                .frame(width: 86, alignment: .leading)
            Text(entry.category)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Jn.inkMute)
                .frame(width: 80, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:  return Jn.mintDim
        case .warn:  return Color.orange
        case .error: return Color.red.opacity(0.85)
        }
    }
    private var messageColor: Color {
        switch entry.level {
        case .info:  return Jn.ink
        case .warn:  return Color.orange.opacity(0.9)
        case .error: return Color.red.opacity(0.9)
        }
    }
}
