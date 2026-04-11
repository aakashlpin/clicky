//
//  ClickyActionRouting.swift
//  leanring-buddy
//
//  Typed intent/routing models for Clicky's voice-to-action pipeline.
//

import Foundation

enum ClickyActionIntent: String, Codable, CaseIterable, Equatable {
    case reply
    case draft
    case delegate
}

enum DelegationTarget: Equatable {
    case localWorkspace
    case multica(assigneeAgentName: String)
}

struct ClickyDelegationRequest: Identifiable, Equatable {
    let id: UUID
    let transcript: String
    let screenSummary: String
    let createdAt: Date
    let target: DelegationTarget

    init(
        id: UUID,
        transcript: String,
        screenSummary: String,
        createdAt: Date,
        target: DelegationTarget = .localWorkspace
    ) {
        self.id = id
        self.transcript = transcript
        self.screenSummary = screenSummary
        self.createdAt = createdAt
        self.target = target
    }
}

struct MulticaIssueCreationRequest: Equatable {
    let title: String
    let description: String
    let attachmentFilePaths: [URL]
    let assigneeAgentName: String
    let priority: String?
}

struct MulticaIssueCreationResult: Equatable {
    let issueID: String
    let issueIdentifier: String
    let issueTitle: String
    let assignedAgentName: String
}

enum MulticaIssueCreationError: Error, Equatable {
    case multicaBinaryMissing
    case daemonNotRunning
    case badExitCode(Int32, stderr: String)
    case responseParseFailure(String)
    case noAttachmentFilesFound
}
