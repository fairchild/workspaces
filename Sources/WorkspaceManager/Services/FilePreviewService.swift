//
//  FilePreviewService.swift
//  WorkspaceManager
//
//  File loading + syntax highlighting for source previews and guarded editing.
//

import AppKit
import Foundation

enum CodePreviewDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["WORKSPACES_DEBUG_PREVIEW"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[CodePreview] %@", message())
    }
}

struct CodePreviewPayload: Sendable {
    let text: String
    let language: CodeSyntaxLanguage
    let spans: [HighlightSpan]
    let isTruncated: Bool
}

enum CodePreviewLoader {
    static let maxPreviewBytes = 1_500_000
    static let maxHighlightCharacters = 250_000

    static func load(fileURL: URL) async throws -> CodePreviewPayload {
        try await Task.detached(priority: .userInitiated) {
            CodePreviewDiagnostics.log("load begin file=\(fileURL.path)")
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            if data.contains(0) {
                CodePreviewDiagnostics.log("load rejected binary file=\(fileURL.path)")
                throw CodePreviewError.binaryFile
            }

            let isTruncated = data.count > maxPreviewBytes
            let previewData = isTruncated ? data.prefix(maxPreviewBytes) : data[...]
            let previewBytes = Data(previewData)

            let text: String
            if isTruncated {
                text = String(decoding: previewData, as: UTF8.self)
            } else if let decodedText = String(data: previewBytes, encoding: .utf8) {
                text = decodedText
            } else {
                CodePreviewDiagnostics.log("load rejected unsupported encoding file=\(fileURL.path)")
                throw CodePreviewError.unsupportedEncoding
            }
            let language = CodeSyntaxLanguage(fileExtension: fileURL.pathExtension)
            let spans = CodeSyntaxHighlighter.highlightSpans(
                in: text,
                language: language,
                maxCharacters: maxHighlightCharacters
            )
            CodePreviewDiagnostics.log(
                "load complete file=\(fileURL.path) chars=\(text.count) spans=\(spans.count) truncated=\(isTruncated)"
            )

            return CodePreviewPayload(
                text: text,
                language: language,
                spans: spans,
                isTruncated: isTruncated
            )
        }
        .value
    }
}

enum CodePreviewError: LocalizedError {
    case binaryFile
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .binaryFile:
            return "Binary files are not previewed in this pane."
        case .unsupportedEncoding:
            return "This file is not UTF-8 text. Open it externally to edit it."
        }
    }
}

enum CodeSyntaxLanguage: Equatable, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case markdown
    case shell
    case plain

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "swift":
            self = .swift
        case "js", "jsx", "mjs", "cjs":
            self = .javascript
        case "ts", "tsx":
            self = .typescript
        case "py":
            self = .python
        case "json":
            self = .json
        case "md", "markdown":
            self = .markdown
        case "sh", "bash", "zsh":
            self = .shell
        default:
            self = .plain
        }
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .plain: return "Plain Text"
        }
    }
}

enum HighlightToken: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case typeName
}

struct HighlightSpan: Equatable, Sendable {
    let location: Int
    let length: Int
    let token: HighlightToken
}

enum CodeSyntaxHighlighter {
    static func makeAttributedText(from payload: CodePreviewPayload) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]

        let text = NSMutableAttributedString(
            string: payload.text,
            attributes: baseAttributes
        )

        for span in payload.spans where span.length > 0 {
            let range = NSRange(location: span.location, length: span.length)
            text.addAttributes(attributes(for: span.token), range: range)
        }

        return text
    }

    static func highlightSpans(
        in text: String,
        language: CodeSyntaxLanguage,
        maxCharacters: Int
    ) -> [HighlightSpan] {
        let nsText = text as NSString
        guard nsText.length <= maxCharacters else {
            return []
        }

        var spans: [HighlightSpan] = []
        let fullRange = NSRange(location: 0, length: nsText.length)

        func addMatches(
            pattern: String,
            options: NSRegularExpression.Options = [],
            token: HighlightToken
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return
            }

            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let range = match?.range, range.length > 0 else { return }
                spans.append(
                    HighlightSpan(
                        location: range.location,
                        length: range.length,
                        token: token
                    )
                )
            }
        }

        switch language {
        case .swift:
            addMatches(pattern: #""(?:\\.|[^"\\])*""#, token: .string)
            addMatches(pattern: #"//.*$"#, options: [.anchorsMatchLines], token: .comment)
            addMatches(pattern: #"/\*[\s\S]*?\*/"#, token: .comment)
            addMatches(pattern: keywordPattern(swiftKeywords), token: .keyword)
            addMatches(pattern: #"\b\d+(?:\.\d+)?\b"#, token: .number)
            addMatches(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, token: .typeName)

        case .javascript, .typescript:
            addMatches(pattern: #""(?:\\.|[^"\\])*""#, token: .string)
            addMatches(pattern: #"'(?:\\.|[^'\\])*'"#, token: .string)
            addMatches(pattern: #"//.*$"#, options: [.anchorsMatchLines], token: .comment)
            addMatches(pattern: #"/\*[\s\S]*?\*/"#, token: .comment)
            addMatches(pattern: keywordPattern(jsKeywords), token: .keyword)
            addMatches(pattern: #"\b\d+(?:\.\d+)?\b"#, token: .number)

        case .python:
            addMatches(pattern: #""(?:\\.|[^"\\])*""#, token: .string)
            addMatches(pattern: #"'(?:\\.|[^'\\])*'"#, token: .string)
            addMatches(pattern: #"#.*$"#, options: [.anchorsMatchLines], token: .comment)
            addMatches(pattern: keywordPattern(pythonKeywords), token: .keyword)
            addMatches(pattern: #"\b\d+(?:\.\d+)?\b"#, token: .number)

        case .json:
            addMatches(pattern: #""(?:\\.|[^"\\])*""#, token: .string)
            addMatches(pattern: #""(?:\\.|[^"\\])*"\s*:"#, token: .typeName)
            addMatches(pattern: #"\b(?:true|false|null)\b"#, token: .keyword)
            addMatches(pattern: #"\b\d+(?:\.\d+)?\b"#, token: .number)

        case .markdown:
            addMatches(pattern: #"^#{1,6}\s.+$"#, options: [.anchorsMatchLines], token: .keyword)
            addMatches(pattern: #"`[^`]+`"#, token: .string)
            addMatches(pattern: #"^>\s.+$"#, options: [.anchorsMatchLines], token: .comment)

        case .shell:
            addMatches(pattern: #"#.*$"#, options: [.anchorsMatchLines], token: .comment)
            addMatches(pattern: #""(?:\\.|[^"\\])*""#, token: .string)
            addMatches(pattern: #"'(?:\\.|[^'\\])*'"#, token: .string)
            addMatches(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#, token: .typeName)
            addMatches(pattern: keywordPattern(shellKeywords), token: .keyword)

        case .plain:
            break
        }

        return spans
    }

    private static func attributes(for token: HighlightToken) -> [NSAttributedString.Key: Any] {
        switch token {
        case .keyword:
            return [.foregroundColor: NSColor.systemPurple]
        case .string:
            return [.foregroundColor: NSColor.systemRed]
        case .comment:
            return [.foregroundColor: NSColor.systemGreen]
        case .number:
            return [.foregroundColor: NSColor.systemOrange]
        case .typeName:
            return [.foregroundColor: NSColor.systemBlue]
        }
    }

    private static func keywordPattern(_ keywords: [String]) -> String {
        let escaped = keywords.map(NSRegularExpression.escapedPattern(for:))
        return #"\b(?:"# + escaped.joined(separator: "|") + #")\b"#
    }

    private static let swiftKeywords = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "do", "else", "enum", "extension", "fallthrough", "false", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "let", "nil", "operator", "private", "protocol",
        "public", "repeat", "return", "self", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "var", "where", "while",
    ]

    private static let jsKeywords = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function",
        "if", "import", "in", "instanceof", "interface", "let", "new", "null", "return", "static", "super",
        "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while",
    ]

    private static let pythonKeywords = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while",
        "with", "yield",
    ]

    private static let shellKeywords = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "until",
        "while",
    ]
}
