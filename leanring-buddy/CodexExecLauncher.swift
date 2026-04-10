//
//  CodexExecLauncher.swift
//  leanring-buddy
//
//  Shared launcher for supported local coding-agent CLIs. The filename is
//  legacy, but the implementation now handles Codex, Claude Code, and
//  OpenCode delegation runs.
//

import Foundation

struct DelegationAgentLaunchConfiguration {
    let workspacePath: String
    let prompt: String
    let runtime: InstalledDelegationAgentRuntime
    let modelIdentifier: String?
}

struct DelegationAgentLaunchResult {
    let processIdentifier: Int32
    let logFileURL: URL
    let runtimeID: DelegationAgentRuntimeID
    let runtimeDisplayName: String
    let baseBranchName: String
    let workingBranchName: String
    let comparePullRequestURL: URL?
}

private struct GitCommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private struct GitBranchContext {
    let baseBranchName: String
    let workingBranchName: String
    let comparePullRequestURL: URL?
}

enum DelegationAgentLaunchError: LocalizedError {
    case runtimeBinaryUnavailable(String)
    case failedToLaunch(String)
    case gitCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeBinaryUnavailable(let runtimeName):
            return "Could not find the \(runtimeName) CLI on this machine."
        case .failedToLaunch(let reason):
            return "Failed to launch the delegated agent: \(reason)"
        case .gitCommandFailed(let reason):
            return "Git command failed: \(reason)"
        }
    }
}

final class DelegationAgentLauncher {
    private let fileManager = FileManager.default

    func launch(configuration: DelegationAgentLaunchConfiguration) async throws -> DelegationAgentLaunchResult {
        guard fileManager.isExecutableFile(atPath: configuration.runtime.binaryPath) else {
            throw DelegationAgentLaunchError.runtimeBinaryUnavailable(configuration.runtime.displayName)
        }

        let gitBranchContext = try await createGitBranchContext(forWorkspacePath: configuration.workspacePath)
        let logFileURL = try makeLogFileURL(
            forWorkspacePath: configuration.workspacePath,
            runtimeID: configuration.runtime.runtimeID,
            baseBranchName: gitBranchContext.baseBranchName,
            workingBranchName: gitBranchContext.workingBranchName
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.runtime.binaryPath)
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workspacePath, isDirectory: true)
        process.arguments = makeArguments(
            for: configuration,
            gitBranchContext: gitBranchContext
        )
        process.environment = makeProcessEnvironment()

        let standardInputPipe = Pipe()
        process.standardInput = standardInputPipe
        standardInputPipe.fileHandleForWriting.closeFile()

        fileManager.createFile(atPath: logFileURL.path, contents: nil)
        let logFileHandle = try FileHandle(forWritingTo: logFileURL)
        process.standardOutput = logFileHandle
        process.standardError = logFileHandle

        do {
            try process.run()
            logFileHandle.closeFile()
        } catch {
            logFileHandle.closeFile()
            throw DelegationAgentLaunchError.failedToLaunch(error.localizedDescription)
        }

        return DelegationAgentLaunchResult(
            processIdentifier: process.processIdentifier,
            logFileURL: logFileURL,
            runtimeID: configuration.runtime.runtimeID,
            runtimeDisplayName: configuration.runtime.displayName,
            baseBranchName: gitBranchContext.baseBranchName,
            workingBranchName: gitBranchContext.workingBranchName,
            comparePullRequestURL: gitBranchContext.comparePullRequestURL
        )
    }

    private func createGitBranchContext(forWorkspacePath workspacePath: String) async throws -> GitBranchContext {
        let baseBranchName = try await resolveCurrentGitBranchName(in: workspacePath)
        let workingBranchName = makeDelegationBranchName(
            workspacePath: workspacePath,
            baseBranchName: baseBranchName
        )

        let checkoutResult = try await runGitCommand(
            arguments: ["checkout", "-b", workingBranchName, baseBranchName],
            in: workspacePath
        )

        guard checkoutResult.exitCode == 0 else {
            let trimmedErrorText = checkoutResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DelegationAgentLaunchError.gitCommandFailed(
                trimmedErrorText.isEmpty
                    ? "git checkout -b \(workingBranchName) \(baseBranchName) exited with status \(checkoutResult.exitCode)"
                    : trimmedErrorText
            )
        }

        let comparePullRequestURL = makeComparePullRequestURL(
            workspacePath: workspacePath,
            baseBranchName: baseBranchName,
            workingBranchName: workingBranchName
        )

        return GitBranchContext(
            baseBranchName: baseBranchName,
            workingBranchName: workingBranchName,
            comparePullRequestURL: comparePullRequestURL
        )
    }

    private func makeArguments(
        for configuration: DelegationAgentLaunchConfiguration,
        gitBranchContext: GitBranchContext
    ) -> [String] {
        let promptWithBranchInstructions = """
        \(configuration.prompt)

        Branch instructions:
        - You are already on a freshly created branch named \(gitBranchContext.workingBranchName).
        - The base branch for the eventual pull request is \(gitBranchContext.baseBranchName).
        - Keep all changes on the current branch.
        - Do not switch branches.
        - Finish with a summary that makes it easy to open a pull request from \(gitBranchContext.workingBranchName) into \(gitBranchContext.baseBranchName).
        """

        switch configuration.runtime.runtimeID {
        case .codex:
            var arguments = ["exec", "--full-auto", "-C", configuration.workspacePath]
            if let modelIdentifier = configuration.modelIdentifier, !modelIdentifier.isEmpty {
                arguments.append(contentsOf: ["--model", modelIdentifier])
            }
            arguments.append(promptWithBranchInstructions)
            return arguments

        case .claude:
            var arguments = ["--print", "--output-format", "text", "--permission-mode", "dontAsk", "--add-dir", configuration.workspacePath]
            if let modelIdentifier = configuration.modelIdentifier, !modelIdentifier.isEmpty {
                arguments.append(contentsOf: ["--model", modelIdentifier])
            }
            arguments.append(promptWithBranchInstructions)
            return arguments

        case .opencode:
            var arguments = ["run", "--dir", configuration.workspacePath, "--format", "default"]
            if let modelIdentifier = configuration.modelIdentifier, !modelIdentifier.isEmpty {
                arguments.append(contentsOf: ["--model", modelIdentifier])
            }
            arguments.append(promptWithBranchInstructions)
            return arguments
        }
    }

    private func makeProcessEnvironment() -> [String: String] {
        let homeDirectoryPath = NSHomeDirectory()
        var environment = ProcessInfo.processInfo.environment

        let candidatePathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectoryPath)/.npm-global/bin",
            "\(homeDirectoryPath)/.local/bin",
            "\(homeDirectoryPath)/.opencode/bin",
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

    private func makeLogFileURL(
        forWorkspacePath workspacePath: String,
        runtimeID: DelegationAgentRuntimeID,
        baseBranchName: String,
        workingBranchName: String
    ) throws -> URL {
        let applicationSupportDirectoryURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let logsDirectoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("Flowee", isDirectory: true)
            .appendingPathComponent("Delegation Logs", isDirectory: true)

        try fileManager.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let workspaceFolderName = URL(fileURLWithPath: workspacePath).lastPathComponent
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestampText = timestampFormatter.string(from: Date())
        let branchSummary = "\(sanitizeBranchComponent(baseBranchName))-to-\(sanitizeBranchComponent(workingBranchName))"

        return logsDirectoryURL.appendingPathComponent(
            "\(runtimeID.rawValue)-\(workspaceFolderName)-\(branchSummary)-\(timestampText).log",
            isDirectory: false
        )
    }

    private func resolveCurrentGitBranchName(in workspacePath: String) async throws -> String {
        let currentBranchResult = try await runGitCommand(
            arguments: ["branch", "--show-current"],
            in: workspacePath
        )

        let currentBranchName = currentBranchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentBranchName.isEmpty {
            return currentBranchName
        }

        let detachedHeadResult = try await runGitCommand(
            arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: workspacePath
        )
        let remoteHeadBranchName = detachedHeadResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedRemoteHeadBranchName = remoteHeadBranchName.split(separator: "/").last {
            return String(resolvedRemoteHeadBranchName)
        }

        let localBranchesResult = try await runGitCommand(
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: workspacePath
        )

        let localBranchNames = localBranchesResult.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if localBranchNames.contains("main") {
            return "main"
        }
        if localBranchNames.contains("master") {
            return "master"
        }
        if let firstLocalBranchName = localBranchNames.first {
            return firstLocalBranchName
        }

        throw DelegationAgentLaunchError.gitCommandFailed("Could not determine a base git branch in \(workspacePath)")
    }

    private func makeDelegationBranchName(workspacePath: String, baseBranchName: String) -> String {
        let workspaceSlug = sanitizeBranchComponent(URL(fileURLWithPath: workspacePath).lastPathComponent)
        let baseBranchSlug = sanitizeBranchComponent(baseBranchName)
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestampText = timestampFormatter.string(from: Date())
        let randomSuffix = UUID().uuidString.prefix(6).lowercased()
        return "flowee/\(workspaceSlug)-\(baseBranchSlug)-\(timestampText)-\(randomSuffix)"
    }

    private func sanitizeBranchComponent(_ text: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = text.unicodeScalars.map { allowedCharacters.contains($0) ? Character($0) : "-" }
        let collapsed = String(sanitized).replacingOccurrences(of: "--", with: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    }

    private func makeComparePullRequestURL(
        workspacePath: String,
        baseBranchName: String,
        workingBranchName: String
    ) -> URL? {
        guard let remoteOriginURL = try? runGitCommandSync(
            arguments: ["remote", "get-url", "origin"],
            in: workspacePath
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteOriginURL.isEmpty,
              let repositoryWebURL = repositoryWebURL(fromGitRemoteURL: remoteOriginURL) else {
            return nil
        }

        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?"))
        let encodedBaseBranchName = baseBranchName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? baseBranchName
        let encodedWorkingBranchName = workingBranchName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? workingBranchName

        return repositoryWebURL.appendingPathComponent("compare/\(encodedBaseBranchName)...\(encodedWorkingBranchName)?expand=1")
    }

    private func repositoryWebURL(fromGitRemoteURL remoteOriginURL: String) -> URL? {
        if remoteOriginURL.hasPrefix("git@github.com:") {
            let repositoryPath = remoteOriginURL
                .replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
            return URL(string: "https://github.com/\(repositoryPath)")
        }

        if remoteOriginURL.hasPrefix("https://github.com/") {
            let repositoryPath = remoteOriginURL
                .replacingOccurrences(of: "https://github.com/", with: "")
                .replacingOccurrences(of: ".git", with: "")
            return URL(string: "https://github.com/\(repositoryPath)")
        }

        return nil
    }

    private func runGitCommand(
        arguments: [String],
        in workspacePath: String
    ) async throws -> GitCommandResult {
        let gitBinaryURL = try resolveGitBinaryURL()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = gitBinaryURL
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
            process.arguments = arguments
            process.environment = makeProcessEnvironment()

            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            process.standardOutput = standardOutputPipe
            process.standardError = standardErrorPipe

            process.terminationHandler = { _ in
                let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
                let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

                continuation.resume(
                    returning: GitCommandResult(
                        exitCode: process.terminationStatus,
                        standardOutput: String(data: standardOutputData, encoding: .utf8) ?? "",
                        standardError: String(data: standardErrorData, encoding: .utf8) ?? ""
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: DelegationAgentLaunchError.failedToLaunch(error.localizedDescription))
            }
        }
    }

    private func runGitCommandSync(
        arguments: [String],
        in workspacePath: String
    ) throws -> GitCommandResult {
        let gitBinaryURL = try resolveGitBinaryURL()
        let process = Process()
        process.executableURL = gitBinaryURL
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        process.arguments = arguments
        process.environment = makeProcessEnvironment()

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        process.waitUntilExit()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        return GitCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: standardOutputData, encoding: .utf8) ?? "",
            standardError: String(data: standardErrorData, encoding: .utf8) ?? ""
        )
    }

    private func resolveGitBinaryURL() throws -> URL {
        let candidatePaths = makeGitCandidatePaths()
        for candidatePath in candidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return URL(fileURLWithPath: candidatePath)
        }

        throw DelegationAgentLaunchError.gitCommandFailed("Could not find git on this machine.")
    }

    private func makeGitCandidatePaths() -> [String] {
        let homeDirectoryPath = NSHomeDirectory()
        var candidatePaths: [String] = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "\(homeDirectoryPath)/.npm-global/bin/git",
            "\(homeDirectoryPath)/.local/bin/git"
        ]

        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirectories = pathEnvironment.split(separator: ":").map(String.init)
            candidatePaths.append(contentsOf: pathDirectories.map { "\($0)/git" })
        }

        return Array(Set(candidatePaths))
    }
}
