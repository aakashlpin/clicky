//
//  DelegationAgentRuntimeRegistry.swift
//  leanring-buddy
//
//  Deterministic local registry for supported coding-agent CLIs that Flowee
//  can delegate into.
//

import Combine
import Foundation

enum DelegationAgentRuntimeID: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .opencode:
            return "OpenCode"
        }
    }

    var shortLabel: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .opencode:
            return "OpenCode"
        }
    }

    var binaryName: String {
        rawValue
    }

    var launchDescription: String {
        switch self {
        case .codex:
            return "OpenAI local coding agent"
        case .claude:
            return "Anthropic Claude Code CLI"
        case .opencode:
            return "OpenCode local coding runtime"
        }
    }
}

struct InstalledDelegationAgentRuntime: Identifiable, Equatable {
    let runtimeID: DelegationAgentRuntimeID
    let binaryPath: String

    var id: DelegationAgentRuntimeID { runtimeID }
    var displayName: String { runtimeID.displayName }
    var shortLabel: String { runtimeID.shortLabel }
    var launchDescription: String { runtimeID.launchDescription }
}

@MainActor
final class DelegationAgentRuntimeRegistry: ObservableObject {
    @Published private(set) var installedRuntimes: [InstalledDelegationAgentRuntime] = []

    private let fileManager = FileManager.default

    init() {
        refreshInstalledRuntimes()
    }

    func refreshInstalledRuntimes() {
        installedRuntimes = DelegationAgentRuntimeID.allCases.compactMap { runtimeID in
            guard let binaryPath = resolveInstalledBinaryPath(for: runtimeID) else {
                return nil
            }

            return InstalledDelegationAgentRuntime(
                runtimeID: runtimeID,
                binaryPath: binaryPath
            )
        }
    }

    func installedRuntime(for runtimeID: DelegationAgentRuntimeID?) -> InstalledDelegationAgentRuntime? {
        guard let runtimeID else { return nil }
        return installedRuntimes.first(where: { $0.runtimeID == runtimeID })
    }

    private func resolveInstalledBinaryPath(for runtimeID: DelegationAgentRuntimeID) -> String? {
        let candidatePaths = makeCandidateBinaryPaths(for: runtimeID)
        for candidatePath in candidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }

        return nil
    }

    private func makeCandidateBinaryPaths(for runtimeID: DelegationAgentRuntimeID) -> [String] {
        let homeDirectoryPath = NSHomeDirectory()
        let binaryName = runtimeID.binaryName

        var candidatePaths: [String] = [
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "\(homeDirectoryPath)/.npm-global/bin/\(binaryName)",
            "\(homeDirectoryPath)/.local/bin/\(binaryName)",
            "\(homeDirectoryPath)/.opencode/bin/\(binaryName)",
            "/usr/bin/\(binaryName)",
            "/bin/\(binaryName)"
        ]

        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirectories = pathEnvironment.split(separator: ":").map(String.init)
            candidatePaths.append(contentsOf: pathDirectories.map { "\($0)/\(binaryName)" })
        }

        return Array(NSOrderedSet(array: candidatePaths)) as? [String] ?? candidatePaths
    }
}
