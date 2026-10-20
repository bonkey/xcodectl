//
// Copyright (c) 2026 Daniel Bauke
//

import ArgumentParser
import Foundation

// MARK: - TOMLValue

/// A value the config file can hold.
enum TOMLValue: Equatable {
    case bool(Bool)
    case string(String)

    /// The value as the file spells it.
    var literal: String {
        switch self {
        case let .bool(value):
            String(value)

        case let .string(value):
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}

// MARK: - Config

/// Defaults for flags and options: a `[table]` per command with keys named like its flags, and keys
/// before the first table shared by every command that has them.
struct Config: Equatable {
    /// The configurable commands in the order `xcodectl --help` lists them, with their keys.
    static let schema: [(table: String, keys: [ConfigKey])] = configurables.map { ($0.configTable, $0.configKeys) }

    /// `XCODECTL_CONFIG`, else `~/.config/xcodectl/config.toml`.
    static var path: URL {
        if let custom = ProcessInfo.processInfo.environment["XCODECTL_CONFIG"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return Paths.home.appendingPathComponent(".config/xcodectl/config.toml")
    }

    var shared: [String: TOMLValue] = [:]
    var tables: [String: [String: TOMLValue]] = [:]

    /// The file at `path`, or nil when there is none.
    static func load() throws -> Config? {
        guard let data = FileManager.default.contents(atPath: path.path) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Fail("\(path.path) is not UTF-8")
        }
        return try parse(text, file: path.path)
    }

    /// The TOML subset the file uses: `[table]` headers, `key = true|false|"string"` and `#` comments.
    static func parse(_ text: String, file: String) throws -> Config {
        var config = Config()
        var table: String?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            func fail(_ message: String) -> Fail {
                Fail("\(file):\(index + 1): \(message)")
            }
            guard !line.isEmpty else {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw fail("a table header is [name]")
                }
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                guard isBareKey(name, allowingDots: true) else {
                    throw fail("a table name holds letters, digits, - and _")
                }
                guard config.tables[name] == nil else {
                    throw fail("[\(name)] appears twice")
                }
                config.tables[name] = [:]
                table = name
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw fail("expected key = value")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key, allowingDots: false) else {
                throw fail("a key holds letters, digits, - and _")
            }
            let value = try parseValue(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces), fail)
            if let table {
                guard config.tables[table]?[key] == nil else {
                    throw fail("\(key) appears twice in [\(table)]")
                }
                config.tables[table]?[key] = value
            } else {
                guard config.shared[key] == nil else {
                    throw fail("\(key) appears twice")
                }
                config.shared[key] = value
            }
        }
        return config
    }

    /// The file `config init` writes: every key commented out, flags at their default, options with an example.
    static func template() -> String {
        var lines = [
            "# xcodectl defaults: one table per command, keys named like its flags without `--`.",
            "# A flag typed on the command line wins over its [command] table, which wins over the",
            "# shared keys above the first table. A value that does not fit the run, such as",
            "# `clt = false` for `install ios`, is ignored. An unknown key or table fails every command.",
            "# Uncomment a line to set it. A flag shows its default, an option an example;",
            "# `xcodectl <command> --help` explains them. `xcodectl config check` reads the file back.",
            "",
            "# Shared by every command below that has the key.",
        ]
        var seen: [String: (count: Int, example: String)] = [:]
        for key in schema.flatMap(\.keys) {
            seen[key.name, default: (0, key.example)].count += 1
        }
        for (name, entry) in seen.sorted(by: { $0.key < $1.key }) where entry.count > 1 {
            lines.append("# \(name) = \(entry.example)")
        }
        for entry in schema {
            lines.append("")
            lines.append("[\(entry.table)]")
            lines += entry.keys.map { "# \($0.name) = \($0.example)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The table's value, else the shared one.
    func value(_ key: String, in table: String) -> TOMLValue? {
        tables[table]?[key] ?? shared[key]
    }

    /// Everything no command reads or accepts, one line each; empty when the file is sound.
    func problems() -> [String] {
        var problems: [String] = []
        for (key, value) in shared.sorted(by: { $0.key < $1.key }) {
            let owners = Config.schema.flatMap(\.keys).filter { $0.name == key }
            guard !owners.isEmpty else {
                problems.append("\(key): no command has this key")
                continue
            }
            if let problem = owners.lazy.compactMap({ $0.problem(value) }).first {
                problems.append("\(key): \(problem)")
            }
        }
        for (table, values) in tables.sorted(by: { $0.key < $1.key }) {
            guard let keys = Config.schema.first(where: { $0.table == table })?.keys else {
                problems.append("[\(table)]: no such command")
                continue
            }
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                guard let known = keys.first(where: { $0.name == key }) else {
                    problems.append("[\(table)] \(key): unknown key")
                    continue
                }
                if let problem = known.problem(value) {
                    problems.append("[\(table)] \(key): \(problem)")
                }
            }
        }
        return problems
    }

    /// Every value a command would read, as `table.key = value`, in command order.
    func effectiveSettings() -> [String] {
        Config.schema.flatMap { entry in
            entry.keys.compactMap { key in
                value(key.name, in: entry.table).map { "\(entry.table).\(key.name) = \($0.literal)" }
            }
        }
    }

    private static let configurables: [any Configurable.Type] = collect(XcodeCtl.self)

    private static func collect(_ command: ParsableCommand.Type) -> [any Configurable.Type] {
        let own: [any Configurable.Type] = (command as? any Configurable.Type).map { [$0] } ?? []
        return own + command.configuration.subcommands.flatMap(collect)
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                escaped = true

            case "\"":
                inString.toggle()

            case "#" where !inString:
                return String(line[..<index])

            default:
                break
            }
        }
        return line
    }

    private static func isBareKey(_ text: some StringProtocol, allowingDots: Bool) -> Bool {
        !text.isEmpty && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || (allowingDots && $0 == "."))
        }
    }

    private static func parseValue(_ text: String, _ fail: (String) -> Fail) throws -> TOMLValue {
        switch text {
        case "true":
            return .bool(true)

        case "false":
            return .bool(false)

        default:
            break
        }
        guard text.hasPrefix("\"") else {
            throw fail("a value is true, false or a \"quoted string\"")
        }
        var result = ""
        var escaped = false
        var closed = false
        for character in text.dropFirst() {
            guard !closed else {
                throw fail("text after the closing quote")
            }
            if escaped {
                guard character == "\"" || character == "\\" else {
                    throw fail("unsupported escape \\\(character)")
                }
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                closed = true
            } else {
                result.append(character)
            }
        }
        guard closed else {
            throw fail("unterminated string")
        }
        return .string(result)
    }
}

// MARK: - ConfigKey

/// One key as `config init` and `config check` see it.
struct ConfigKey {
    let name: String
    /// The template line's value: a flag's default, an option's example.
    let example: String
    /// Why the value does not fit, or nil when it does.
    let problem: (TOMLValue) -> String?
}

// MARK: - ConfigSetting

/// One key of a command: how it is checked and how it lands in the parsed command.
struct ConfigSetting<Command> {
    let key: ConfigKey
    /// Sets the field when it is still nil and the value fits; false otherwise.
    let apply: (inout Command, TOMLValue) -> Bool

    static func flag(_ name: String, _ path: WritableKeyPath<Command, Bool?>, default: Bool) -> Self {
        Self(
            key: ConfigKey(name: name, example: String(`default`)) { value in
                if case .bool = value {
                    nil
                } else {
                    "expects true or false"
                }
            },
            apply: { command, value in
                guard case let .bool(flag) = value, command[keyPath: path] == nil else {
                    return false
                }
                command[keyPath: path] = flag
                return true
            })
    }

    static func option<Value>(
        _ name: String,
        _ path: WritableKeyPath<Command, Value?>,
        example: String,
        values: [String] = [],
        parse: @escaping (String) -> Value?)
        -> Self
    {
        Self(
            key: ConfigKey(name: name, example: TOMLValue.string(example).literal) { value in
                guard case let .string(text) = value else {
                    return "expects a \"quoted string\""
                }
                guard parse(text) == nil else {
                    return nil
                }
                return values.isEmpty
                    ? "\"\(text)\" is not a valid value"
                    : "\"\(text)\" is not one of \(values.joined(separator: ", "))"
            },
            apply: { command, value in
                guard case let .string(text) = value, command[keyPath: path] == nil, let parsed = parse(text) else {
                    return false
                }
                command[keyPath: path] = parsed
                return true
            })
    }

    static func option<Value: ExpressibleByArgument>(
        _ name: String,
        _ path: WritableKeyPath<Command, Value?>,
        example: String)
        -> Self
    {
        option(name, path, example: example, values: Value.allValueStrings, parse: Value.init(argument:))
    }
}

// MARK: - Configurable

/// A command whose flags and options the config file can preset.
protocol Configurable: ParsableCommand {
    /// The `[table]` name; the command name unless nested.
    static var configTable: String { get }
    static var settings: [ConfigSetting<Self>] { get }
}

extension Configurable {
    static var configTable: String {
        _commandName
    }

    static var configKeys: [ConfigKey] {
        settings.map(\.key)
    }

    /// Fills in what the command line left out. A value the command's own `validate()` rejects next to
    /// what was typed, such as `clt = false` for a runtime install, is skipped.
    mutating func applyConfig(_ config: Config) {
        for setting in Self.settings {
            guard let value = config.value(setting.key.name, in: Self.configTable) else {
                continue
            }
            var candidate = self
            guard setting.apply(&candidate, value), (try? candidate.validate()) != nil else {
                continue
            }
            self = candidate
        }
    }
}

extension XcodeCtl {
    /// `parseAsRoot`, then the config file fills in whatever the command line left out.
    static func parseConfigured(_ arguments: [String]? = nil, config: Config? = nil) throws -> ParsableCommand {
        let command = try parseAsRoot(arguments)
        guard var configurable = command as? any Configurable, let config = try config ?? Config.load() else {
            return command
        }
        let problems = config.problems()
        guard problems.isEmpty else {
            let more = problems.count > 1 ? " (+\(problems.count - 1) more; `xcodectl config check` lists them)" : ""
            throw Fail("\(Config.path.path): \(problems[0])\(more)")
        }
        configurable.applyConfig(config)
        return configurable
    }
}

// MARK: - AuthCommand.Status + Configurable

extension AuthCommand.Status: Configurable {
    static let configTable = "auth.status"
    static let settings: [ConfigSetting<AuthCommand.Status>] = [
        .flag("json", \.json, default: false),
        .flag("login", \.login, default: true),
    ]
}

// MARK: - AuthCommand.Export + Configurable

extension AuthCommand.Export: Configurable {
    static let configTable = "auth.export"
    static let settings: [ConfigSetting<AuthCommand.Export>] = [
        .flag("login", \.login, default: true),
        .flag("copy", \.copy, default: false),
    ]
}

// MARK: - AuthCommand.Import + Configurable

extension AuthCommand.Import: Configurable {
    static let configTable = "auth.import"
    static let settings: [ConfigSetting<AuthCommand.Import>] = [
        .flag("paste", \.paste, default: false),
    ]
}

// MARK: - List + Configurable

extension List: Configurable {
    static let settings: [ConfigSetting<List>] = [
        .flag("stable", \.stable, default: false),
        .flag("beta", \.beta, default: false),
        .flag("all", \.all, default: false),
        .flag("json", \.json, default: false),
        .option("order", \.order, example: "by-version", values: ["by-version", "by-date"]) {
            ["by-version": .byVersion, "by-date": .byDate][$0]
        },
    ]
}

// MARK: - ListInstalled + Configurable

extension ListInstalled: Configurable {
    static let settings: [ConfigSetting<ListInstalled>] = [
        .flag("size", \.size, default: true),
        .flag("json", \.json, default: false),
    ]
}

// MARK: - ReleaseNotesCommand + Configurable

extension ReleaseNotesCommand: Configurable {
    static let settings: [ConfigSetting<ReleaseNotesCommand>] = [
        .flag("markdown", \.markdown, default: false),
        .flag("plain", \.plain, default: false),
        .flag("abridged", \.abridged, default: false),
        .option("key-env", \.keyEnv, example: "OPENROUTER_API_KEY"),
        .option("provider", \.provider, example: "openai"),
        .option("base-url", \.baseURL, example: "http://localhost:11434/v1"),
        .option("model", \.model, example: "gpt-5.6-luna"),
    ]
}

// MARK: - Install + Configurable

extension Install: Configurable {
    static let settings: [ConfigSetting<Install>] = [
        .flag("approve", \.approve, default: true),
        .flag("select", \.select, default: false),
        .flag("clt", \.clt, default: true),
        .flag("login", \.autologin, default: true),
        .option("runtimes", \.runtimeSelection, example: "all"),
    ]
}

// MARK: - Upgrade + Configurable

extension Upgrade: Configurable {
    static let settings: [ConfigSetting<Upgrade>] = [
        .flag("minor", \.minor, default: false),
        .flag("keep", \.keep, default: false),
        .flag("beta", \.beta, default: false),
        .flag("approve", \.approve, default: true),
        .flag("clt", \.clt, default: true),
        .flag("login", \.autologin, default: true),
        .option("runtimes", \.runtimeSelection, example: "ios,watchos"),
    ]
}

// MARK: - Remove + Configurable

extension Remove: Configurable {
    static let settings: [ConfigSetting<Remove>] = [
        .flag("keep-runtimes", \.keepRuntimes, default: false),
    ]
}

// MARK: - Prune + Configurable
