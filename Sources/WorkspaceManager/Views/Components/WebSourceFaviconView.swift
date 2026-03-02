//
//  WebSourceFaviconView.swift
//  WorkspaceManager
//
//  Sidebar icon view that loads and caches per-host favicons.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

@MainActor
private enum WebSourceFaviconCache {
    static let images = NSCache<NSString, NSImage>()
    static var failedUntil: [NSString: Date] = [:]
    static let failureCooldown: TimeInterval = 300
    static let maxFailureEntries = 256

    static func pruneFailures(now: Date = Date()) {
        failedUntil = failedUntil.filter { $0.value > now }

        if failedUntil.count <= maxFailureEntries { return }
        let sortedByRetry = failedUntil.sorted { $0.value < $1.value }
        let excessCount = failedUntil.count - maxFailureEntries
        for (key, _) in sortedByRetry.prefix(excessCount) {
            failedUntil.removeValue(forKey: key)
        }
    }
}

struct WebSourceFaviconView: View {
    let source: WebSource

    @State private var favicon: NSImage?

    var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.cyan)
            }
        }
        .frame(width: 18, height: 18, alignment: .leading)
        .clipShape(.rect(cornerRadius: 3))
        .task(id: source.baseURLString) {
            await loadFavicon()
        }
    }

    @MainActor
    private func loadFavicon() async {
        guard let baseURL = source.baseURL,
            let faviconURL = WebSourceValidation.faviconURL(baseURL: baseURL)
        else {
            favicon = nil
            return
        }
        let cacheKey = faviconURL.absoluteString as NSString

        if let cached = WebSourceFaviconCache.images.object(forKey: cacheKey) {
            favicon = cached
            return
        }

        let now = Date()
        WebSourceFaviconCache.pruneFailures(now: now)
        if let retryAfter = WebSourceFaviconCache.failedUntil[cacheKey], retryAfter > now {
            favicon = nil
            return
        }
        WebSourceFaviconCache.failedUntil[cacheKey] = nil
        favicon = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: faviconURL)
            guard let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let loaded = NSImage(data: data),
                loaded.isValid
            else {
                WebSourceFaviconCache.failedUntil[cacheKey] = Date().addingTimeInterval(
                    WebSourceFaviconCache.failureCooldown
                )
                WebSourceFaviconCache.pruneFailures()
                return
            }

            WebSourceFaviconCache.images.setObject(loaded, forKey: cacheKey)
            WebSourceFaviconCache.failedUntil[cacheKey] = nil
            favicon = loaded
        } catch is CancellationError {
            return
        } catch {
            WebSourceFaviconCache.failedUntil[cacheKey] = Date().addingTimeInterval(
                WebSourceFaviconCache.failureCooldown
            )
            WebSourceFaviconCache.pruneFailures()
            return
        }
    }
}
