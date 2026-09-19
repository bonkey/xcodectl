//
// Copyright (c) 2026 Daniel Bauke
//

import ArgumentParser
import Foundation

// MARK: - Provider

/// In the order their keys are looked up.
enum Provider: String, ExpressibleByArgument, CaseIterable {
    case openrouter
    case openai

    /// The default model is cheap, fast and follows the brief of the summary.
    var api: (name: String, baseURL: URL, keyVariable: String, defaultModel: String) {
        switch self {
        case .openai:
            ("OpenAI", URL(string: "https://api.openai.com/v1")!, "OPENAI_API_KEY", "gpt-5.6-luna")

        case .openrouter:
            ("OpenRouter", URL(string: "https://openrouter.ai/api/v1")!, "OPENROUTER_API_KEY", "openai/gpt-5.6-luna")
        }
    }
}

// MARK: - HostedModel

/// A model behind an OpenAI-compatible API: a provider paid with the user's own key, or a server of
/// the user's own, such as Ollama.
struct HostedModel: Equatable {
    let provider: Provider
    /// What messages call the API: the provider, or the host of a custom base URL.
    let place: String
    let baseURL: URL
    /// The environment variable `apiKey` comes from; nil without a key.
    let keyVariable: String?
    let apiKey: String
    /// nil: `defaultModel`.
    let model: String?
    let defaultModel: String

    /// The key comes from `keyEnv`, else from the variable of `provider`, else from the first provider
    /// whose variable is set. Only a custom base URL goes without a key.
    static func resolve(
        environment: [String: String], keyEnv: String? = nil, provider: Provider? = nil, baseURL: String? = nil,
        model: String? = nil) throws
        -> HostedModel
    {
        let custom = try baseURL.map { text -> URL in
            guard let url = URL(string: text), url.scheme != nil, url.host != nil else {
                throw Fail("--base-url is not a URL: \(text)")
            }
            return url
        }
        guard custom == nil || model != nil else {
            throw Fail("--base-url needs --model")
        }
        let candidates = provider.map { [$0] } ?? Provider.allCases
        let variables = keyEnv.map { [$0] } ?? candidates.map(\.api.keyVariable)
        let variable = variables.first { environment[$0]?.isEmpty == false }
        guard variable != nil || (custom != nil && keyEnv == nil) else {
            throw Fail("""
            no API key: \(variables.joined(separator: " or ")) is not set. --key-env names another variable; \
            a server of your own, such as Ollama, takes --base-url and --model
            """)
        }
        let provider = provider ?? candidates.first { $0.api.keyVariable == variable } ?? .openai
        return HostedModel(
            provider: provider, place: custom?.host ?? provider.api.name, baseURL: custom ?? provider.api.baseURL,
            keyVariable: variable, apiKey: variable.flatMap { environment[$0] } ?? "", model: model,
            defaultModel: provider.api.defaultModel)
    }
}
