import Foundation

struct MulticaIssueContent: Equatable {
    let title: String
    let description: String
}

@MainActor
final class MulticaIssueContentGenerator {
    private static let workerBaseURL =
        AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL") ??
        "https://your-worker-name.your-subdomain.workers.dev"

    private static let systemPrompt = """
    You are generating a Multica issue from a spoken voice request.

    User transcript:
    <transcript>

    Screen context:
    <screenSummary>

    Workspace hint (may be empty):
    <workspaceName or "">

    Respond with ONLY a JSON object:
    {"title":"<short imperative, max 70 chars, no trailing period>","description":"<markdown body>"}

    The description must include, in this order:
    1. A "## Spoken request" section with the transcript verbatim.
    2. A "## Screen context" section with the screen summary.
    3. A "## Workspace hint" section if the workspace name is non-empty.
    """

    private lazy var classifierAPI: ClaudeAPI = {
        ClaudeAPI(
            proxyURL: "\(Self.workerBaseURL)/chat",
            model: "claude-sonnet-4-0"
        )
    }()

    func generateIssueContent(
        transcript: String,
        screenSummary: String,
        workspaceName: String?
    ) async -> MulticaIssueContent {
        do {
            let prompt = makeUserPrompt(
                transcript: transcript,
                screenSummary: screenSummary,
                workspaceName: workspaceName
            )
            let (responseText, _) = try await classifierAPI.analyzeImage(
                images: [],
                systemPrompt: Self.systemPrompt,
                userPrompt: prompt
            )
            return try parseIssueContent(from: responseText)
        } catch {
            print("🧭 Multica content generation fell back: \(error.localizedDescription)")
            return fallbackIssueContent(
                transcript: transcript,
                screenSummary: screenSummary
            )
        }
    }

    private func makeUserPrompt(
        transcript: String,
        screenSummary: String,
        workspaceName: String?
    ) -> String {
        let workspaceHint = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
        User transcript:
        \(transcript)

        Screen context:
        \(screenSummary)

        Workspace hint (may be empty):
        \(workspaceHint)
        """
    }

    private func parseIssueContent(from responseText: String) throws -> MulticaIssueContent {
        let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let responseData = trimmedResponseText.data(using: .utf8) else {
            throw MulticaIssueContentGenerationError.invalidUTF8Response
        }

        let parsedResponse = try JSONDecoder().decode(
            GeneratedIssueContentPayload.self,
            from: responseData
        )

        let validatedTitle = parsedResponse.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let validatedDescription = parsedResponse.description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !validatedTitle.isEmpty else {
            throw MulticaIssueContentGenerationError.missingTitle
        }

        guard !validatedDescription.isEmpty else {
            throw MulticaIssueContentGenerationError.missingDescription
        }

        return MulticaIssueContent(
            title: validatedTitle,
            description: validatedDescription
        )
    }

    private func fallbackIssueContent(
        transcript: String,
        screenSummary: String
    ) -> MulticaIssueContent {
        MulticaIssueContent(
            title: firstSixtyCharsOfTranscript(transcript),
            description: """
            ## Spoken request

            \(transcript)

            ## Screen context

            \(screenSummary)
            """
        )
    }

    private func firstSixtyCharsOfTranscript(_ transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return "" }

        let punctuationToTrim = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        if trimmedTranscript.count <= 60 {
            return trimmedTranscript.trimmingCharacters(in: punctuationToTrim)
        }

        let limitedTranscript = String(trimmedTranscript.prefix(60))
        let candidateWords = limitedTranscript.split(whereSeparator: \.isWhitespace)

        let truncatedAtWordBoundary: String
        if candidateWords.count > 1 {
            truncatedAtWordBoundary = candidateWords.dropLast().joined(separator: " ")
        } else {
            truncatedAtWordBoundary = limitedTranscript
        }

        let cleanedTitle = truncatedAtWordBoundary.trimmingCharacters(in: punctuationToTrim)
        if !cleanedTitle.isEmpty {
            return cleanedTitle
        }

        return limitedTranscript.trimmingCharacters(in: punctuationToTrim)
    }
}

private struct GeneratedIssueContentPayload: Decodable {
    let title: String
    let description: String
}

private enum MulticaIssueContentGenerationError: LocalizedError {
    case invalidUTF8Response
    case missingTitle
    case missingDescription

    var errorDescription: String? {
        switch self {
        case .invalidUTF8Response:
            return "response was not valid UTF-8"
        case .missingTitle:
            return "response JSON was missing a non-empty title"
        case .missingDescription:
            return "response JSON was missing a non-empty description"
        }
    }
}
