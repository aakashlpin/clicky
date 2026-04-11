//
//  MulticaAgentRegistry.swift
//  leanring-buddy
//
//  stub — full implementation in Unit 1.2 (AAK-4)
//

import Combine
import Foundation

enum DelegationTarget: String, CaseIterable, Identifiable {
    case localWorkspace = "localWorkspace"
    case multica = "multica"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .localWorkspace:
            return "Local workspace"
        case .multica:
            return "Multica"
        }
    }
}

struct MulticaAgentListEntry: Identifiable, Equatable {
    let name: String

    var id: String { name }
}

@MainActor
final class MulticaAgentRegistry: ObservableObject {
    @Published var availableAgents: [MulticaAgentListEntry] = []
}
