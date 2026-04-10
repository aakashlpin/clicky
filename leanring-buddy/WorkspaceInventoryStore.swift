//
//  WorkspaceInventoryStore.swift
//  leanring-buddy
//
//  Persists the user-approved list of code workspaces that Clicky is allowed
//  to delegate coding tasks into. Stored in Application Support so it remains
//  editable and deterministic across app launches.
//

import Combine
import Foundation

@MainActor
final class WorkspaceInventoryStore: ObservableObject {
    enum WorkspaceInventoryError: LocalizedError {
        case duplicatePath

        var errorDescription: String? {
            switch self {
            case .duplicatePath:
                return "This workspace folder is already in Flowee's inventory."
            }
        }
    }

    struct WorkspaceRecord: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var path: String
        var workspaceDescription: String
        var isEnabled: Bool
        var lastUsedDelegationRuntimeID: DelegationAgentRuntimeID?
    }

    enum WorkspaceValidationStatus: Equatable {
        case valid
        case missingDirectory
        case notCodeWorkspace

        var userFacingDescription: String? {
            switch self {
            case .valid:
                return nil
            case .missingDirectory:
                return "Folder missing"
            case .notCodeWorkspace:
                return "Doesn't look like a code workspace"
            }
        }
    }

    @Published private(set) var workspaces: [WorkspaceRecord] = []

    var enabledWorkspaces: [WorkspaceRecord] {
        workspaces.filter(\.isEnabled)
    }

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadWorkspacesFromDisk()
    }

    func addWorkspace(
        name: String,
        path: String,
        workspaceDescription: String,
        isEnabled: Bool = true,
        lastUsedDelegationRuntimeID: DelegationAgentRuntimeID? = nil
    ) throws {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = normalizeWorkspacePath(trimmedPath)

        guard !workspaces.contains(where: { $0.path == normalizedPath }) else {
            throw WorkspaceInventoryError.duplicatePath
        }

        let newWorkspace = WorkspaceRecord(
            id: UUID(),
            name: trimmedName.isEmpty ? URL(fileURLWithPath: normalizedPath).lastPathComponent : trimmedName,
            path: normalizedPath,
            workspaceDescription: workspaceDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: isEnabled,
            lastUsedDelegationRuntimeID: lastUsedDelegationRuntimeID
        )

        workspaces.append(newWorkspace)
        try saveWorkspacesToDisk()
    }

    func updateWorkspace(
        workspaceID: UUID,
        name: String,
        path: String,
        workspaceDescription: String,
        isEnabled: Bool,
        lastUsedDelegationRuntimeID: DelegationAgentRuntimeID?
    ) throws {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }

        let normalizedPath = normalizeWorkspacePath(path)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !workspaces.contains(where: { $0.id != workspaceID && $0.path == normalizedPath }) else {
            throw WorkspaceInventoryError.duplicatePath
        }

        workspaces[workspaceIndex].name = trimmedName.isEmpty
            ? URL(fileURLWithPath: normalizedPath).lastPathComponent
            : trimmedName
        workspaces[workspaceIndex].path = normalizedPath
        workspaces[workspaceIndex].workspaceDescription = workspaceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[workspaceIndex].isEnabled = isEnabled
        workspaces[workspaceIndex].lastUsedDelegationRuntimeID = lastUsedDelegationRuntimeID

        try saveWorkspacesToDisk()
    }

    func markLastUsedDelegationRuntime(
        workspaceID: UUID,
        runtimeID: DelegationAgentRuntimeID
    ) throws {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[workspaceIndex].lastUsedDelegationRuntimeID = runtimeID
        try saveWorkspacesToDisk()
    }

    func removeWorkspace(workspaceID: UUID) throws {
        workspaces.removeAll { $0.id == workspaceID }
        try saveWorkspacesToDisk()
    }

    func validationStatus(for workspace: WorkspaceRecord) -> WorkspaceValidationStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missingDirectory
        }

        return Self.looksLikeCodeWorkspace(at: workspace.path) ? .valid : .notCodeWorkspace
    }

    private func loadWorkspacesFromDisk() {
        guard let inventoryFileURL = try? inventoryFileURL() else {
            workspaces = []
            return
        }

        guard fileManager.fileExists(atPath: inventoryFileURL.path) else {
            workspaces = []
            return
        }

        do {
            let data = try Data(contentsOf: inventoryFileURL)
            let inventoryFile = try decoder.decode(WorkspaceInventoryFile.self, from: data)
            workspaces = inventoryFile.workspaces
        } catch {
            print("⚠️ Workspace inventory: failed to load \(error)")
            workspaces = []
        }
    }

    private func saveWorkspacesToDisk() throws {
        let inventoryFile = WorkspaceInventoryFile(workspaces: workspaces)
        let encodedInventory = try encoder.encode(inventoryFile)
        let inventoryFileURL = try inventoryFileURL()
        try fileManager.createDirectory(
            at: inventoryFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try encodedInventory.write(to: inventoryFileURL, options: .atomic)
    }

    private func inventoryFileURL() throws -> URL {
        let applicationSupportDirectoryURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupportDirectoryURL
            .appendingPathComponent("Flowee", isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }

    private func normalizeWorkspacePath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func looksLikeCodeWorkspace(at path: String) -> Bool {
        let fileManager = FileManager.default
        let workspaceURL = URL(fileURLWithPath: path, isDirectory: true)
        let commonWorkspaceMarkers = [
            ".git",
            "package.json",
            "Package.swift",
            "pyproject.toml",
            "go.mod",
            "Cargo.toml",
            "Gemfile",
            "Podfile"
        ]

        for markerName in commonWorkspaceMarkers {
            let markerURL = workspaceURL.appendingPathComponent(markerName)
            if fileManager.fileExists(atPath: markerURL.path) {
                return true
            }
        }

        if let directoryEnumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in directoryEnumerator {
                let fileExtension = fileURL.pathExtension.lowercased()
                if fileExtension == "xcodeproj" || fileExtension == "xcworkspace" {
                    return true
                }
            }
        }

        return false
    }
}

private struct WorkspaceInventoryFile: Codable {
    let workspaces: [WorkspaceInventoryStore.WorkspaceRecord]
}
