import Foundation

/// Talks to OpenAI's API — the only network calls anywhere in this app.
/// Both calls use a cheap, vision-capable model. Nothing here runs unless
/// an API key has been set via KeychainStore (see AICron).
enum OpenAIClient {
    /// Cheap and vision-capable — good enough for "what is this a
    /// screenshot of" and for summarizing a day's activity log.
    static let model = "gpt-4o-mini"

    enum ClientError: Error { case noAPIKey, badResponse, httpError(Int, String) }

    /// Looks at one screenshot plus the block's current (auto-generated or
    /// already-renamed) title and asks for a short, specific task title
    /// and a one-sentence description of what's actually happening.
    static func classifyScreenshot(
        currentTitle: String, appName: String, autoTitle: String, imageData: Data
    ) async throws -> (title: String, description: String) {
        guard let key = KeychainStore.getAPIKey(), !key.isEmpty else { throw ClientError.noAPIKey }

        let prompt = """
        This screenshot was taken during a tracked work block. It's currently \
        labeled "\(currentTitle)" (app: \(appName); original auto-generated \
        label: "\(autoTitle)"). Look at the screenshot and identify the SPECIFIC \
        task the person is doing — not just the app name, but what they're \
        actually working on (e.g. "Fixing login bug" rather than "Using Xcode").

        Respond with ONLY a JSON object, no other text:
        {"title": "3-6 word specific task title", "description": "one concise sentence describing what's being done"}
        """

        let base64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                ]
            ]],
            "max_tokens": 200,
            "response_format": ["type": "json_object"]
        ]

        let content = try await chatCompletion(apiKey: key, body: body)
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else {
            throw ClientError.badResponse
        }
        let description = obj["description"] as? String ?? ""
        return (title, description)
    }

    /// Sends a full text log of a day's tasks/blocks/switches and asks for
    /// concrete workflow-improvement recommendations.
    static func workflowRecommendations(logText: String) async throws -> String {
        guard let key = KeychainStore.getAPIKey(), !key.isEmpty else { throw ClientError.noAPIKey }

        let prompt = """
        Below is an automatically tracked log of one workday: every task, \
        every app/site switch, down to the second.

        \(logText)

        Based on this log, give 3-6 concrete, specific recommendations for \
        improving this workflow — e.g. reducing context-switching, batching \
        similar activity, noticing time sinks. Be specific to what's actually \
        in the log, not generic productivity advice. Plain text, short \
        numbered list, no preamble.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 700
        ]
        return try await chatCompletion(apiKey: key, body: body)
    }

    private static func chatCompletion(apiKey: String, body: [String: Any]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "(no body)"
            throw ClientError.httpError(http.statusCode, text)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClientError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
