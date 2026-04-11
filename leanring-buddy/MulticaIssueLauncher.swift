//
//  MulticaIssueLauncher.swift
//  leanring-buddy
//
//  Files Multica issues by shelling out to the local `multica` CLI.
//

import Foundation

@MainActor
final class MulticaIssueLauncher {
    private let fileManager = FileManager.default
    private var cachedMulticaBinaryURL: URL? = nil

    func createIssue(_ request: MulticaIssueCreationRequest) async throws -> MulticaIssueCreationResult {
        let multicaBinaryURL = try await resolveMulticaBinaryURL()
        let existingAttachmentFileURLs = try validateAttachmentFileURLs(request.attachmentFilePaths)
        let processEnvironment = makeProcessEnvironment()
        let processArguments = makeIssueCreateArguments(
            request: request,
            attachmentFileURLs: existingAttachmentFileURLs
        )

        let processResult = await Task.detached(priority: .userInitiated) {
            Self.runProcess(
                executableURL: multicaBinaryURL,
                arguments: processArguments,
                environment: processEnvironment
            )
        }.value

        guard processResult.exitCode == 0 else {
            let trimmedStandardError = processResult.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedStandardError.localizedCaseInsensitiveContains("daemon") {
                throw MulticaIssueCreationError.daemonNotRunning
            }

            throw MulticaIssueCreationError.badExitCode(
                processResult.exitCode,
                stderr: trimmedStandardError
            )
        }

        do {
            return try Self.parseCreationResult(
                from: processResult.standardOutput,
                requestedAssigneeAgentName: request.assigneeAgentName
            )
        } catch let error as MulticaIssueCreationError {
            throw error
        } catch {
            throw MulticaIssueCreationError.responseParseFailure(processResult.standardOutput)
        }
    }

    private func resolveMulticaBinaryURL() async throws -> URL {
        if let cachedMulticaBinaryURL,
           fileManager.isExecutableFile(atPath: cachedMulticaBinaryURL.path) {
            return cachedMulticaBinaryURL
        }

        let explicitCandidateURLs = [
            URL(fileURLWithPath: "/opt/homebrew/bin/multica"),
            URL(fileURLWithPath: "/usr/local/bin/multica")
        ]

        if let resolvedExplicitURL = explicitCandidateURLs.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            cachedMulticaBinaryURL = resolvedExplicitURL
            return resolvedExplicitURL
        }

        let processEnvironment = makeProcessEnvironment()
        let whichResolvedURL = await Task.detached(priority: .userInitiated) {
            Self.resolveMulticaBinaryURLUsingWhich(environment: processEnvironment)
        }.value

        if let whichResolvedURL {
            cachedMulticaBinaryURL = whichResolvedURL
            return whichResolvedURL
        }

        throw MulticaIssueCreationError.multicaBinaryMissing
    }

    private func validateAttachmentFileURLs(_ attachmentFileURLs: [URL]) throws -> [URL] {
        let existingAttachmentFileURLs = attachmentFileURLs.filter { attachmentFileURL in
            fileManager.fileExists(atPath: attachmentFileURL.path)
        }

        if !attachmentFileURLs.isEmpty && existingAttachmentFileURLs.isEmpty {
            throw MulticaIssueCreationError.noAttachmentFilesFound
        }

        return existingAttachmentFileURLs
    }

    private func makeIssueCreateArguments(
        request: MulticaIssueCreationRequest,
        attachmentFileURLs: [URL]
    ) -> [String] {
        var processArguments = [
            "issue",
            "create",
            "--title",
            request.title,
            "--description",
            request.description,
            "--assignee",
            request.assigneeAgentName,
            "--output",
            "json"
        ]

        for attachmentFileURL in attachmentFileURLs {
            processArguments.append("--attachment")
            processArguments.append(attachmentFileURL.path)
        }

        if let priority = request.priority {
            processArguments.append("--priority")
            processArguments.append(priority)
        }

        return processArguments
    }

    private func makeProcessEnvironment() -> [String: String] {
        let homeDirectoryPath = NSHomeDirectory()
        var environment = ProcessInfo.processInfo.environment
        let candidatePathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
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

    nonisolated private static func resolveMulticaBinaryURLUsingWhich(environment: [String: String]) -> URL? {
        let processResult = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", "multica"],
            environment: environment
        )

        guard processResult.exitCode == 0 else {
            return nil
        }

        let resolvedPath = processResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !resolvedPath.isEmpty else {
            return nil
        }

        let resolvedURL = URL(fileURLWithPath: resolvedPath)
        return FileManager.default.isExecutableFile(atPath: resolvedURL.path) ? resolvedURL : nil
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

    nonisolated private static func parseCreationResult(
        from standardOutput: String,
        requestedAssigneeAgentName: String
    ) throws -> MulticaIssueCreationResult {
        guard let standardOutputData = standardOutput.data(using: .utf8) else {
            throw MulticaIssueCreationError.responseParseFailure(standardOutput)
        }

        do {
            let createdIssuePayload = try JSONDecoder().decode(
                DecodableCreatedIssuePayload.self,
                from: standardOutputData
            )

            return MulticaIssueCreationResult(
                issueID: createdIssuePayload.id,
                issueIdentifier: createdIssuePayload.identifier,
                issueTitle: createdIssuePayload.title,
                assignedAgentName: requestedAssigneeAgentName
            )
        } catch {
            throw MulticaIssueCreationError.responseParseFailure(standardOutput)
        }
    }
}

private struct ProcessExecutionResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private struct DecodableCreatedIssuePayload: Decodable {
    let id: String
    let identifier: String
    let title: String
}

#if DEBUG
@MainActor
enum MulticaIssueLauncherDebugFixture {
    static func verifyParser() throws -> MulticaIssueCreationResult {
        let fixtureJSON = """
        {
          "id": "ec5dea4d-002c-4212-934c-a6a64c80da7a",
          "identifier": "AAK-1",
          "title": "Multica routing integration (Shape B)",
          "assignee_id": null
        }
        """

        return try MulticaIssueLauncher.parseCreationResult(
            from: fixtureJSON,
            requestedAssigneeAgentName: "Worker Agent"
        )
    }
}
#endif
