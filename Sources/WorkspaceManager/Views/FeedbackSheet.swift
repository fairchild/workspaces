import AppKit
import SwiftUI
import WorkspaceManagerCore

struct FeedbackSheet: View {
    private static let privacyCopy =
        "Feedback is private to the WorkSpaces team unless we choose to publish an edited "
        + "or aggregated issue."

    @Environment(\.feedbackService) private var feedbackService
    @ObservedObject var notificationCoordinator: NotificationCoordinator
    let onDismiss: () -> Void

    @State private var kind: FeedbackKind = .feedback
    @State private var message = ""
    @State private var contactEmail = ""
    @State private var includesScreenshot = false
    @State private var includesDiagnostics = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var receipt: FeedbackSubmissionReceipt?

    private var canSubmit: Bool {
        !isSubmitting && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker("Type", selection: $kind) {
                Text("Feedback").tag(FeedbackKind.feedback)
                Text("Bug").tag(FeedbackKind.bug)
                Text("Idea").tag(FeedbackKind.idea)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.headline)
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
            }

            TextField("Email (optional)", text: $contactEmail)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Attach a screenshot of the current WorkSpaces window", isOn: $includesScreenshot)
                Toggle("Attach a diagnostic report zip", isOn: $includesDiagnostics)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let receipt {
                Text("Sent. Reference: \(receipt.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(receipt == nil ? "Cancel" : "Done") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || receipt != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send Feedback")
                .font(.title2)
                .bold()
            Text(Self.privacyCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let attachments = try await FeedbackAttachmentCollector.collect(
                screenshot: includesScreenshot,
                diagnostics: includesDiagnostics
            )
            let submission = FeedbackSubmission(
                kind: kind,
                message: message,
                contactEmail: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                appVersion: Self.appVersion,
                osVersion: Self.osVersion,
                screenshot: attachments.screenshot,
                diagnostics: attachments.diagnostics
            )
            let jwt = await notificationCoordinator.jwtForFeedbackSubmission()
            receipt = try await feedbackService.submit(submission, jwt: jwt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private struct FeedbackCollectedAttachments {
    let screenshot: FeedbackAttachment?
    let diagnostics: FeedbackAttachment?
}

private enum FeedbackAttachmentCollector {
    @MainActor
    static func collect(screenshot: Bool, diagnostics: Bool) async throws -> FeedbackCollectedAttachments {
        let screenshotAttachment = screenshot ? try captureMainWindowScreenshot() : nil
        let diagnosticsAttachment = diagnostics ? try await assembleDiagnostics() : nil
        return FeedbackCollectedAttachments(
            screenshot: screenshotAttachment,
            diagnostics: diagnosticsAttachment
        )
    }

    @MainActor
    private static func captureMainWindowScreenshot() throws -> FeedbackAttachment? {
        guard
            let window = NSApp.mainWindow ?? NSApp.keyWindow,
            let contentView = window.contentView
        else { return nil }

        let bounds = contentView.bounds
        guard
            let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        contentView.cacheDisplay(in: bounds, to: representation)
        guard let bitmap = representation.representation(using: .png, properties: [:]) else { return nil }

        return FeedbackAttachment(
            filename: "screenshot.png",
            contentType: "image/png",
            data: bitmap
        )
    }

    private static func assembleDiagnostics() async throws -> FeedbackAttachment {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-feedback-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: url) }

        try await DiagnosticReportExporter.assembleReport(to: url)
        return FeedbackAttachment(
            filename: "diagnostics.zip",
            contentType: "application/zip",
            data: try Data(contentsOf: url)
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
