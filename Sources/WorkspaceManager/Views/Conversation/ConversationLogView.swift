//
//  ConversationLogView.swift
//  WorkspaceManager
//
//  Opt-in surface: a sidebar context-menu action on a host session ("Show
//  conversation log") opens this view. Renders the transcript as a scrollable
//  list. Unknown record types render as collapsed JSON.
//
//  Conversation log view for the transcript JSONL reader.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

public struct ConversationLogView: View {
    public let transcriptPath: URL

    @State private var records: [IdentifiedRecord] = []
    @State private var isLoading = true
    @State private var loadError: String?

    public init(transcriptPath: URL) {
        self.transcriptPath = transcriptPath
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: transcriptPath) {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Conversation log")
                .font(.headline)
            Spacer()
            Text(transcriptPath.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .help(transcriptPath.path)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if records.isEmpty {
            Text("No transcript records.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(records) { item in
                        TranscriptRecordCard(record: item.record)
                            .id(item.id)
                    }
                }
                .padding(16)
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        let path = transcriptPath
        let collected = await Task.detached { () -> Result<[TranscriptRecord], Error> in
            var out: [TranscriptRecord] = []
            for await record in TranscriptReader(transcriptPath: path).tail() {
                out.append(record)
                if Task.isCancelled { break }
            }
            return .success(out)
        }.value

        switch collected {
        case .success(let recs):
            self.records = recs.enumerated().map { IdentifiedRecord(id: $0.offset, record: $0.element) }
        case .failure(let err):
            self.loadError = "Failed to read transcript: \(err.localizedDescription)"
        }
        self.isLoading = false
    }

    fileprivate struct IdentifiedRecord: Identifiable {
        let id: Int
        let record: TranscriptRecord
    }
}

struct TranscriptRecordCard: View {
    let record: TranscriptRecord

    var body: some View {
        switch record {
        case .user(let u):
            recordContainer(role: "User", tint: .accentColor) {
                Text(u.text.isEmpty ? "(empty)" : u.text)
                    .textSelection(.enabled)
            }
        case .assistant(let a):
            recordContainer(role: a.model.map { "Assistant — \($0)" } ?? "Assistant", tint: .blue) {
                Text(a.text.isEmpty ? "(empty)" : a.text)
                    .textSelection(.enabled)
            }
        case .toolUse(let t):
            recordContainer(role: "Tool: \(t.toolName)", tint: .orange) {
                if let summary = t.inputSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        case .toolResult(let r):
            recordContainer(
                role: r.isError ? "Tool error" : "Tool result",
                tint: r.isError ? .red : .green
            ) {
                if let summary = r.outputSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                if let ms = r.durationMS {
                    Text("\(ms) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .summary(let s):
            recordContainer(role: "Summary", tint: .gray) {
                Text(s.summary).textSelection(.enabled)
            }
        case .opaque(let typeName, let raw):
            OpaqueRecordView(typeName: typeName, rawJSON: raw)
        }
    }

    @ViewBuilder
    private func recordContainer<Body: View>(
        role: String,
        tint: Color,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            body()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Collapsed JSON fallback for unrecognised transcript record types.
struct OpaqueRecordView: View {
    let typeName: String
    let rawJSON: Data

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                Text("Unknown record: \(typeName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                Text(prettyJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var prettyJSON: String {
        if let obj = try? JSONSerialization.jsonObject(with: rawJSON),
            let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let s = String(data: pretty, encoding: .utf8)
        {
            return s
        }
        return String(data: rawJSON, encoding: .utf8) ?? "(unreadable)"
    }
}
