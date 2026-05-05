#!/usr/bin/env swift

import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct Arguments {
    var appcastPath = ""
    var dmgPath = ""
    var publicKey = ""
    var expectedURL: String?
    var expectedVersion: String?
    var expectedShortVersion: String?
}

enum VerifyError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

func usage() -> String {
    """
    Usage: scripts/verify-sparkle-appcast.swift --appcast <appcast.xml> --dmg <WorkSpaces.dmg> --public-key <SUPublicEDKey> [options]

    Options:
      --expected-url <url>             Require the enclosure URL to match.
      --expected-version <build>       Require sparkle:version to match.
      --expected-short-version <ver>   Require sparkle:shortVersionString to match.
      --help                           Show this help.
    """
}

func parseArguments(_ raw: [String]) throws -> Arguments {
    var args = Arguments()
    var index = 0

    func requireValue(for option: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < raw.count, !raw[valueIndex].hasPrefix("--") else {
            throw VerifyError.message("\(option) requires a value")
        }
        index += 2
        return raw[valueIndex]
    }

    while index < raw.count {
        let option = raw[index]
        switch option {
        case "--appcast":
            args.appcastPath = try requireValue(for: option)
        case "--dmg":
            args.dmgPath = try requireValue(for: option)
        case "--public-key":
            args.publicKey = try requireValue(for: option)
        case "--expected-url":
            args.expectedURL = try requireValue(for: option)
        case "--expected-version":
            args.expectedVersion = try requireValue(for: option)
        case "--expected-short-version":
            args.expectedShortVersion = try requireValue(for: option)
        case "--help", "-h":
            print(usage())
            exit(0)
        default:
            throw VerifyError.message("Unknown argument: \(option)")
        }
    }

    guard !args.appcastPath.isEmpty else { throw VerifyError.message("Missing required --appcast") }
    guard !args.dmgPath.isEmpty else { throw VerifyError.message("Missing required --dmg") }
    guard !args.publicKey.isEmpty else { throw VerifyError.message("Missing required --public-key") }
    return args
}

func attribute(_ names: [String], from element: XMLElement) -> String? {
    for name in names {
        if let value = element.attribute(forName: name)?.stringValue {
            return value
        }
    }

    for attribute in element.attributes ?? [] {
        if let localName = attribute.localName, names.contains(localName),
           let value = attribute.stringValue
        {
            return value
        }
        if let name = attribute.name, names.contains(name),
           let value = attribute.stringValue
        {
            return value
        }
    }

    return nil
}

func firstText(localName: String, in document: XMLDocument) throws -> String? {
    let nodes = try document.nodes(forXPath: "//*[local-name()='\(localName)']")
    return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func requireEqual(_ actual: String?, _ expected: String?, label: String) throws {
    guard let expected else { return }
    guard actual == expected else {
        throw VerifyError.message("\(label) mismatch: expected \(expected), got \(actual ?? "<missing>")")
    }
}

func fileSize(_ url: URL) throws -> UInt64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize else {
        throw VerifyError.message("Unable to read file size for \(url.path)")
    }
    return UInt64(size)
}

func verify() throws {
    let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let appcastURL = URL(fileURLWithPath: args.appcastPath)
    let dmgURL = URL(fileURLWithPath: args.dmgPath)

    guard FileManager.default.fileExists(atPath: appcastURL.path) else {
        throw VerifyError.message("Appcast not found: \(appcastURL.path)")
    }
    guard FileManager.default.fileExists(atPath: dmgURL.path) else {
        throw VerifyError.message("DMG not found: \(dmgURL.path)")
    }

    let document = try XMLDocument(contentsOf: appcastURL, options: [])
    let enclosureNodes = try document.nodes(forXPath: "//*[local-name()='enclosure']")
    guard enclosureNodes.count == 1, let enclosure = enclosureNodes.first as? XMLElement else {
        throw VerifyError.message("Expected exactly one appcast enclosure, found \(enclosureNodes.count)")
    }

    let enclosureURL = attribute(["url"], from: enclosure)
    let signatureText = attribute(["sparkle:edSignature", "edSignature"], from: enclosure)
    let lengthText = attribute(["length", "sparkle:length"], from: enclosure)

    try requireEqual(enclosureURL, args.expectedURL, label: "enclosure URL")
    try requireEqual(try firstText(localName: "version", in: document), args.expectedVersion, label: "sparkle:version")
    try requireEqual(
        try firstText(localName: "shortVersionString", in: document),
        args.expectedShortVersion,
        label: "sparkle:shortVersionString"
    )

    guard let signatureText,
          let signature = Data(base64Encoded: signatureText)
    else {
        throw VerifyError.message("Missing or invalid sparkle:edSignature")
    }

    guard let publicKeyData = Data(base64Encoded: args.publicKey) else {
        throw VerifyError.message("SUPublicEDKey is not valid base64")
    }
    guard publicKeyData.count == 32 else {
        throw VerifyError.message("SUPublicEDKey must decode to 32 bytes, got \(publicKeyData.count)")
    }

    let actualSize = try fileSize(dmgURL)
    guard let lengthText,
          let declaredSize = UInt64(lengthText),
          declaredSize == actualSize
    else {
        throw VerifyError.message("Appcast length does not match DMG size \(actualSize)")
    }

    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let dmgData = try Data(contentsOf: dmgURL, options: [.mappedIfSafe])
    guard publicKey.isValidSignature(signature, for: dmgData) else {
        throw VerifyError.message("Sparkle EdDSA signature does not verify for \(dmgURL.path)")
    }

    print("Verified Sparkle appcast signature for \(dmgURL.lastPathComponent)")
}

do {
    try verify()
} catch {
    fputs("[verify-sparkle-appcast] ERROR: \(error)\n", stderr)
    exit(1)
}
