//
//  MulticaAgentRegistry.swift
//  leanring-buddy
//
//  Local cache for Multica agent metadata exposed by the `multica` CLI.
//
//  The Multica CLI scopes `agent list` to a single currently-watched
//  workspace (set via `~/.multica/config.json` or the `--workspace-id`
//  global flag). Clicky users can have multiple Multica workspaces (e.g.
//  a Personal workspace and a work workspace) with agents in each, and
//  the menu bar picker needs to show ALL of them normalized so the user
//  can pick a specific one before triggering a delegation.
//
//  This registry walks `multica workspace list` and then re-invokes
//  `multica --workspace-id <uuid> agent list --output json` once per
//  workspace, aggregating the results and tagging every agent with the
//  workspace it came from. The display name Clicky shows in the picker
//  is "<workspaceName>-<agentName>" so two agents named "Claude" living
//  in different workspaces stay disambiguated.
//

import Combine
import Foundation

struct MulticaAgent: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let status: String
    /// Workspace this agent belongs to. Required when filing an issue
    /// because `multica issue create` targets whichever workspace the
    /// CLI is currently watching; Clicky passes this explicitly via
    /// `--workspace-id` so the user's pick is always honored.
    let workspaceID: UUID
    /// Human-readable name of the workspace this agent belongs to, as
    /// reported by `multica workspace list`. Used in the normalized
    /// display name the picker shows to the user.
    let workspaceName: String

    /// Picker label: "<workspaceName>-<agentName>" (e.g. "Personal-Worker").
    /// This is the normalized name the user selects from; we keep the
    /// original `name` field around because Multica's `issue create`
    /// command expects the raw agent name, not the normalized one.
    var displayName: String {
        "\(workspaceName)-\(name)"
    }
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
            Self.loadAgentsAcrossAllWorkspaces(
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

    nonisolated private static func loadAgentsAcrossAllWorkspaces(
        executablePath: String,
        environment: [String: String]
    ) -> AgentRefreshResult {
        // Step 1: ask the CLI which workspaces this user belongs to. The
        // `workspace list` command does NOT support `--output json` today
        // (it's table-only), so we parse the fixed-width table output.
        let workspaceListProcessResult = runProcess(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: ["workspace", "list"],
            environment: environment
        )

        guard workspaceListProcessResult.exitCode == 0 else {
            let trimmedStandardErrorText = workspaceListProcessResult.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedStandardErrorText.isEmpty {
                return .failure(trimmedStandardErrorText)
            }

            return .failure("Multica workspace list failed.")
        }

        let parsedWorkspaceRows = parseMulticaWorkspaceListTable(
            workspaceListProcessResult.standardOutput
        )

        guard !parsedWorkspaceRows.isEmpty else {
            return .failure("Multica returned no workspaces.")
        }

        // Step 2: for each workspace, ask the CLI for its agents with an
        // explicit `--workspace-id` override so we don't rely on whichever
        // workspace happens to be the "currently watched" one. Tag each
        // returned agent with its workspace so the picker can show
        // normalized "<workspaceName>-<agentName>" labels and the issue
        // launcher knows which workspace to file into.
        var aggregatedAgents: [MulticaAgent] = []
        var perWorkspaceFailureMessages: [String] = []

        for parsedWorkspaceRow in parsedWorkspaceRows {
            let perWorkspaceAgentLoadResult = loadAgentsForSingleWorkspace(
                executablePath: executablePath,
                environment: environment,
                workspaceID: parsedWorkspaceRow.id,
                workspaceName: parsedWorkspaceRow.name
            )

            switch perWorkspaceAgentLoadResult {
            case .success(let perWorkspaceAgents):
                aggregatedAgents.append(contentsOf: perWorkspaceAgents)
            case .failure(let perWorkspaceFailureReason):
                perWorkspaceFailureMessages.append(
                    "\(parsedWorkspaceRow.name): \(perWorkspaceFailureReason)"
                )
            }
        }

        // If literally every workspace failed we propagate the combined
        // error. If at least one workspace returned agents we still
        // return success so the user isn't blocked by a single flaky
        // workspace — a partially-populated picker is better than an
        // empty one.
        if aggregatedAgents.isEmpty, !perWorkspaceFailureMessages.isEmpty {
            return .failure(perWorkspaceFailureMessages.joined(separator: "; "))
        }

        let sortedAgents = aggregatedAgents.sorted { leftAgent, rightAgent in
            leftAgent.displayName.localizedCaseInsensitiveCompare(rightAgent.displayName) == .orderedAscending
        }

        return .success(sortedAgents)
    }

    nonisolated private static func loadAgentsForSingleWorkspace(
        executablePath: String,
        environment: [String: String],
        workspaceID: UUID,
        workspaceName: String
    ) -> AgentRefreshResult {
        let agentListProcessResult = runProcess(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: [
                "--workspace-id",
                workspaceID.uuidString,
                "agent",
                "list",
                "--output",
                "json"
            ],
            environment: environment
        )

        guard agentListProcessResult.exitCode == 0 else {
            let trimmedStandardErrorText = agentListProcessResult.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedStandardErrorText.isEmpty {
                return .failure(trimmedStandardErrorText)
            }

            return .failure("Multica agent list failed.")
        }

        guard let agentListStandardOutputData = agentListProcessResult.standardOutput.data(using: .utf8) else {
            return .failure("Multica returned invalid agent data.")
        }

        do {
            let decodedAgentPayloads = try JSONDecoder().decode(
                [DecodableAgentPayload].self,
                from: agentListStandardOutputData
            )
            let decodedAgents = try decodedAgentPayloads.map { decodedAgentPayload in
                try decodedAgentPayload.makeMulticaAgent(
                    workspaceID: workspaceID,
                    workspaceName: workspaceName
                )
            }
            return .success(decodedAgents)
        } catch DecodableAgentPayload.DecodingError.invalidIdentifier {
            return .failure("Multica returned an invalid agent ID.")
        } catch {
            return .failure("Multica returned invalid agent data.")
        }
    }

    /// Parse the fixed-width table emitted by `multica workspace list`.
    /// The header row is `ID  NAME  WATCHING` and each subsequent row
    /// starts with a 36-character UUID. The `WATCHING` column is a
    /// trailing `*` marker that may or may not be present. Any row that
    /// does not start with a valid UUID (the header itself, blank lines,
    /// error banners) is silently skipped.
    nonisolated private static func parseMulticaWorkspaceListTable(
        _ rawTableOutput: String
    ) -> [(id: UUID, name: String)] {
        var parsedWorkspaceRows: [(id: UUID, name: String)] = []

        for rawTableLine in rawTableOutput.split(whereSeparator: { $0.isNewline }) {
            let rawLineString = String(rawTableLine)
            guard rawLineString.count >= 36 else { continue }

            let uuidPrefixSubstring = String(rawLineString.prefix(36))
            guard let parsedWorkspaceIdentifier = UUID(uuidString: uuidPrefixSubstring) else {
                continue
            }

            // After stripping the UUID prefix, what remains is
            // "<name>  *" or "<name>" (possibly with padding whitespace
            // on either side).
            var remainderAfterUuidPrefix = String(rawLineString.dropFirst(36))
                .trimmingCharacters(in: .whitespaces)

            if remainderAfterUuidPrefix.hasSuffix("*") {
                remainderAfterUuidPrefix = String(remainderAfterUuidPrefix.dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }

            // Collapse any interior multi-space padding down to a single
            // space. In practice workspace names are single words so this
            // is a no-op, but it keeps multi-word names readable without
            // dragging in column padding.
            let collapsedWorkspaceName = remainderAfterUuidPrefix
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")

            guard !collapsedWorkspaceName.isEmpty else { continue }

            parsedWorkspaceRows.append(
                (id: parsedWorkspaceIdentifier, name: collapsedWorkspaceName)
            )
        }

        return parsedWorkspaceRows
    }

    nonisolated private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) -> ProcessExecutionResult {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            return ProcessExecutionResult(
                exitCode: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        process.waitUntilExit()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessExecutionResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: standardOutputData, encoding: .utf8) ?? "",
            standardError: String(data: standardErrorData, encoding: .utf8) ?? ""
        )
    }
}

private struct ProcessExecutionResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private struct DecodableAgentPayload: Decodable {
    let id: String
    let name: String
    let description: String
    let status: String

    func makeMulticaAgent(
        workspaceID: UUID,
        workspaceName: String
    ) throws -> MulticaAgent {
        guard let identifier = UUID(uuidString: id) else {
            throw DecodingError.invalidIdentifier
        }

        return MulticaAgent(
            id: identifier,
            name: name,
            description: description,
            status: status,
            workspaceID: workspaceID,
            workspaceName: workspaceName
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
