//
//  MulticaAgentRegistry.swift
//  leanring-buddy
//
//  Local cache for Multica agent metadata exposed by the `multica` CLI.
//

import Combine
import Foundation

struct MulticaAgent: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let status: String
}

@MainActor
final class MulticaAgentRegistry: ObservableObject {
    @Published private(set) var availableAgents: [MulticaAgent] = []
    @Published private(set) var lastRefreshFailureReason: String? = nil

    private let fileManager = FileManager.default

    func refreshAvailableAgents() async {
        guard let multicaBinaryPath = resolveMulticaBinaryPath() else {
            lastRefreshFailureReason = "Multica CLI not found."
            return
        }

        let processEnvironment = makeProcessEnvironment()
        let refreshTask = Task.detached(priority: .userInitiated) {
            Self.loadAgents(
                executablePath: multicaBinaryPath,
                environment: processEnvironment
            )
        }
        let refreshResult = await refreshTask.value

        switch refreshResult {
        case .success(let agents):
            availableAgents = agents
            lastRefreshFailureReason = nil
        case .failure(let reason):
            lastRefreshFailureReason = reason
        }
    }

    private func resolveMulticaBinaryPath() -> String? {
        for candidatePath in makeMulticaCandidatePaths() where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }

        return nil
    }

    private func makeMulticaCandidatePaths() -> [String] {
        let homeDirectoryPath = NSHomeDirectory()
        var candidatePaths = [
            "/opt/homebrew/bin/multica",
            "/usr/local/bin/multica",
            "\(homeDirectoryPath)/.npm-global/bin/multica",
            "\(homeDirectoryPath)/.local/bin/multica",
            "/usr/bin/multica",
            "/bin/multica"
        ]

        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirectories = pathEnvironment.split(separator: ":").map(String.init)
            candidatePaths.append(contentsOf: pathDirectories.map { "\($0)/multica" })
        }

        return Array(NSOrderedSet(array: candidatePaths)) as? [String] ?? candidatePaths
    }

    private func makeProcessEnvironment() -> [String: String] {
        let homeDirectoryPath = NSHomeDirectory()
        var environment = ProcessInfo.processInfo.environment

        let candidatePathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectoryPath)/.npm-global/bin",
            "\(homeDirectoryPath)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let existingPathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let mergedPathEntries = Array(NSOrderedSet(array: candidatePathEntries + existingPathEntries)) as? [String] ?? candidatePathEntries

        environment["HOME"] = homeDirectoryPath
        environment["PATH"] = mergedPathEntries.joined(separator: ":")
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "en_US.UTF-8"

        return environment
    }

    nonisolated private static func loadAgents(
        executablePath: String,
        environment: [String: String]
    ) -> AgentRefreshResult {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["agent", "list", "--output", "json"]
        process.environment = environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            return .failure("Unable to start Multica.")
        }

        process.waitUntilExit()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let standardErrorText = String(data: standardErrorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let standardErrorText, !standardErrorText.isEmpty {
                return .failure(standardErrorText)
            }

            return .failure("Multica agent list failed.")
        }

        do {
            let payloads = try JSONDecoder().decode([DecodableAgentPayload].self, from: standardOutputData)
            let agents = try payloads.map { try $0.makeMulticaAgent() }
            return .success(agents)
        } catch DecodableAgentPayload.DecodingError.invalidIdentifier {
            return .failure("Multica returned an invalid agent ID.")
        } catch {
            return .failure("Multica returned invalid agent data.")
        }
    }
}

private struct DecodableAgentPayload: Decodable {
    let id: String
    let name: String
    let description: String
    let status: String

    func makeMulticaAgent() throws -> MulticaAgent {
        guard let identifier = UUID(uuidString: id) else {
            throw DecodingError.invalidIdentifier
        }

        return MulticaAgent(
            id: identifier,
            name: name,
            description: description,
            status: status
        )
    }

    enum DecodingError: Error {
        case invalidIdentifier
    }
}

private enum AgentRefreshResult {
    case success([MulticaAgent])
    case failure(String)
}
