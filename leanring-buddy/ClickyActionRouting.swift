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

struct ClickyDelegationRequest: Identifiable, Equatable {
    let id: UUID
    let transcript: String
    let screenSummary: String
    let createdAt: Date
}
