//
//  WebSourceRow.swift
//  WorkspaceManager
//
//  Row view for URL sources shown in the sidebar.
//

import SwiftUI
import WorkspaceManagerCore

struct WebSourceRow: View {
    let source: WebSource
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            WebSourceFaviconView(source: source)

            Text(source.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), web source")
    }
}
