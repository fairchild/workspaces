//
//  GhosttySurfaceForegroundProcessTests.swift
//  WorkspaceManagerAppTests
//
//  #892 asks libghostty for a way to attribute a process to one surface. The C API has
//  carried `ghostty_surface_foreground_pid` and `ghostty_surface_tty_name` since before
//  the 492300ca pin; this pins that each names its own surface's process and terminal,
//  even for two surfaces in the same working directory.
//

import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("Ghostty surface foreground process", .serialized)
@MainActor
struct GhosttySurfaceForegroundProcessTests {
    @Test("Two surfaces in one directory each report their own foreground process and terminal")
    func surfacesReportTheirOwnProcess() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }
        let directory = FileManager.default.temporaryDirectory.path

        let sleeper = try harness.makeSurface(BareSurfaceConfig(command: "/bin/sleep 600", workingDirectory: directory))
        let reader = try harness.makeSurface(BareSurfaceConfig(command: "/bin/cat", workingDirectory: directory))
        let sleeperSurface = try #require(harness.surface(for: sleeper))
        let readerSurface = try #require(harness.surface(for: reader))

        let named = await BareGhosttyApp.poll(timeout: 60) {
            Self.processNames(under: sleeperSurface).contains("sleep")
                && Self.processNames(under: readerSurface).contains("cat")
        }
        #expect(
            named,
            "sleeper: \(Self.processNames(under: sleeperSurface)) reader: \(Self.processNames(under: readerSurface))")
        #expect(!Self.processNames(under: sleeperSurface).contains("cat"))
        #expect(!Self.processNames(under: readerSurface).contains("sleep"))

        let sleeperTTY = Self.ttyName(sleeperSurface)
        let readerTTY = Self.ttyName(readerSurface)
        #expect(sleeperTTY.hasPrefix("/dev/tty"), "\(sleeperTTY)")
        #expect(sleeperTTY != readerTTY)
    }

    /// The surface's foreground process group leader and everything under it.
    private static func processNames(under surface: ghostty_surface_t) -> Set<String> {
        let pid = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard pid > 0 else { return [] }
        return Set(ProcessTree.descendants(of: pid).union([pid]).map(ProcessTree.name))
    }

    private static func ttyName(_ surface: ghostty_surface_t) -> String {
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let pointer = name.ptr, name.len > 0 else { return "" }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(name.len)), as: UTF8.self)
    }
}
