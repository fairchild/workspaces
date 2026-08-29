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
        HStack(spacing: SidebarChrome.Metrics.rowContentSpacing) {
            WebSourceFaviconView(source: source)
                .frame(width: SidebarChrome.Metrics.iconColumn, alignment: .center)

            Text(source.name)
                .font(SidebarChrome.TypeStyle.rowTitle(emphasized: isSelected))
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, SidebarChrome.Metrics.rowVerticalPadding)
        .padding(.horizontal, SidebarChrome.Metrics.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: SidebarChrome.Radius.webSourceRow, style: .continuous)
                .fill(isSelected ? SidebarChrome.Fill.rowSelection : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), web view")
    }
}
