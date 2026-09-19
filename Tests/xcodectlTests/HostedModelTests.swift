//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class HostedModelTests: XCTestCase {
    func testNoKeyIsAnError() {
        XCTAssertThrowsError(try HostedModel.resolve(environment: [:]))
        XCTAssertThrowsError(try HostedModel.resolve(environment: ["OPENAI_API_KEY": ""]))
    }

    func testTheOpenRouterKeyComesBeforeTheOpenAIKey() throws {
        let both = try HostedModel.resolve(environment: keys)
        XCTAssertEqual(both.provider, .openrouter)
        XCTAssertEqual(both.place, "OpenRouter")
        XCTAssertEqual(both.keyVariable, "OPENROUTER_API_KEY")
        XCTAssertEqual(both.apiKey, "sk-or-router")
        XCTAssertEqual(both.baseURL.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertNil(both.model)

        let openai = try HostedModel.resolve(environment: ["OPENAI_API_KEY": "sk-openai"])
        XCTAssertEqual(openai.provider, .openai)
        XCTAssertEqual(openai.apiKey, "sk-openai")
        XCTAssertEqual(openai.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(openai.defaultModel, "gpt-5.6-luna")
    }

    func testTheProviderNamesItsKeyVariable() throws {
        let router = try HostedModel.resolve(environment: keys, provider: .openrouter, model: "x/y")
        XCTAssertEqual(router.apiKey, "sk-or-router")
        XCTAssertEqual(router.model, "x/y")
    }

    func testANamedKeyVariableGoesToOpenAIUnlessAProviderIsGiven() throws {
        XCTAssertEqual(try HostedModel.resolve(environment: keys, keyEnv: "MY_KEY").provider, .openai)
        let router = try HostedModel.resolve(environment: keys, keyEnv: "MY_KEY", provider: .openrouter)
        XCTAssertEqual(router.apiKey, "sk-mine")
        XCTAssertEqual(router.keyVariable, "MY_KEY")
        XCTAssertEqual(router.baseURL.absoluteString, "https://openrouter.ai/api/v1")
    }

    func testABaseURLReplacesTheOneOfTheProviderAndNeedsAModel() throws {
        let custom = try HostedModel.resolve(
            environment: keys, keyEnv: "MY_KEY", baseURL: "http://localhost:1234/v1", model: "m")
        XCTAssertEqual(custom.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(custom.place, "localhost")
        XCTAssertEqual(custom.provider, .openai)
        XCTAssertThrowsError(try HostedModel.resolve(environment: keys, baseURL: "http://localhost:1234/v1"))
        XCTAssertThrowsError(try HostedModel.resolve(environment: keys, baseURL: "not a url", model: "m"))
    }

    func testOnlyABaseURLGoesWithoutAKey() throws {
        let local = try HostedModel.resolve(environment: [:], baseURL: "http://localhost:11434/v1", model: "m")
        XCTAssertNil(local.keyVariable)
        XCTAssertEqual(local.apiKey, "")
        XCTAssertThrowsError(try HostedModel.resolve(
            environment: [:], keyEnv: "MY_KEY", baseURL: "http://localhost:11434/v1", model: "m"))
    }

    func testAnOptionWithoutItsKeyIsAnError() {
        XCTAssertThrowsError(try HostedModel.resolve(environment: [:], keyEnv: "MY_KEY"))
        XCTAssertThrowsError(try HostedModel.resolve(environment: ["OPENAI_API_KEY": "k"], provider: .openrouter))
        XCTAssertThrowsError(try HostedModel.resolve(environment: [:], model: "m"))
    }

    private let keys = ["OPENAI_API_KEY": "sk-openai", "OPENROUTER_API_KEY": "sk-or-router", "MY_KEY": "sk-mine"]
}
