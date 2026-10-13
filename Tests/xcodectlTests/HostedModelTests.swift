//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct HostedModelTests {
    @Test func noKeyIsAnError() {
        #expect(throws: Error.self) { try HostedModel.resolve(environment: [:]) }
        #expect(throws: Error.self) { try HostedModel.resolve(environment: ["OPENAI_API_KEY": ""]) }
    }

    @Test func theOpenRouterKeyComesBeforeTheOpenAIKey() throws {
        let both = try HostedModel.resolve(environment: keys)
        #expect(both.provider == .openrouter)
        #expect(both.place == "OpenRouter")
        #expect(both.keyVariable == "OPENROUTER_API_KEY")
        #expect(both.apiKey == "sk-or-router")
        #expect(both.baseURL.absoluteString == "https://openrouter.ai/api/v1")
        #expect(both.model == nil)

        let openai = try HostedModel.resolve(environment: ["OPENAI_API_KEY": "sk-openai"])
        #expect(openai.provider == .openai)
        #expect(openai.apiKey == "sk-openai")
        #expect(openai.baseURL.absoluteString == "https://api.openai.com/v1")
        #expect(openai.defaultModel == "gpt-5.6-luna")
    }

    @Test func theGeminiKeyComesLast() throws {
        let gemini = try HostedModel.resolve(environment: ["GEMINI_API_KEY": "gm-key"])
        #expect(gemini.provider == .gemini)
        #expect(gemini.place == "Gemini")
        #expect(gemini.keyVariable == "GEMINI_API_KEY")
        #expect(gemini.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(gemini.defaultModel == "gemini-3.8-flash")
        #expect(
            try HostedModel.resolve(environment: keys.merging(["GEMINI_API_KEY": "gm-key"]) { $1 }).provider ==
                .openrouter)
        #expect(try HostedModel.resolve(
            environment: keys.merging(["GEMINI_API_KEY": "gm-key"]) { $1 },
            provider: .gemini).apiKey == "gm-key")
    }

    @Test func theProviderNamesItsKeyVariable() throws {
        let router = try HostedModel.resolve(environment: keys, provider: .openrouter, model: "x/y")
        #expect(router.apiKey == "sk-or-router")
        #expect(router.model == "x/y")
    }

    @Test func aNamedKeyVariableGoesToOpenAIUnlessAProviderIsGiven() throws {
        #expect(try HostedModel.resolve(environment: keys, keyEnv: "MY_KEY").provider == .openai)
        let router = try HostedModel.resolve(environment: keys, keyEnv: "MY_KEY", provider: .openrouter)
        #expect(router.apiKey == "sk-mine")
        #expect(router.keyVariable == "MY_KEY")
        #expect(router.baseURL.absoluteString == "https://openrouter.ai/api/v1")
    }

    @Test func aBaseURLReplacesTheOneOfTheProviderAndNeedsAModel() throws {
        let custom = try HostedModel.resolve(
            environment: keys, keyEnv: "MY_KEY", baseURL: "http://localhost:1234/v1", model: "m")
        #expect(custom.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(custom.place == "localhost")
        #expect(custom.provider == .openai)
        #expect(throws: Error.self) { try HostedModel.resolve(environment: keys, baseURL: "http://localhost:1234/v1") }
        #expect(throws: Error.self) { try HostedModel.resolve(environment: keys, baseURL: "not a url", model: "m") }
    }

    @Test func onlyABaseURLGoesWithoutAKey() throws {
        let local = try HostedModel.resolve(environment: [:], baseURL: "http://localhost:11434/v1", model: "m")
        #expect(local.keyVariable == nil)
        #expect(local.apiKey == "")
        #expect(throws: Error.self) {
            try HostedModel.resolve(
                environment: [:],
                keyEnv: "MY_KEY",
                baseURL: "http://localhost:11434/v1",
                model: "m")
        }
    }

    @Test func anOptionWithoutItsKeyIsAnError() {
        #expect(throws: Error.self) { try HostedModel.resolve(environment: [:], keyEnv: "MY_KEY") }
        #expect(throws: Error.self) {
            try HostedModel.resolve(environment: ["OPENAI_API_KEY": "k"], provider: .openrouter)
        }
        #expect(throws: Error.self) { try HostedModel.resolve(environment: [:], model: "m") }
    }

    private let keys = ["OPENAI_API_KEY": "sk-openai", "OPENROUTER_API_KEY": "sk-or-router", "MY_KEY": "sk-mine"]
}
