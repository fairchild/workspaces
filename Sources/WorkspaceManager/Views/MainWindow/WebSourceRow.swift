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
        HStack(spacing: 8) {
            WebSourceFaviconView(source: source)
                .frame(width: 18, alignment: .center)

            Text(source.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), web view")
    }
}
