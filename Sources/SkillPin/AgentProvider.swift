import Foundation

/// An agent that reads skills from a `<dot-directory>/skills` folder.
///
/// `key` is the dot-directory name without the leading dot. Agents SkillPin has
/// never heard of still appear, so a new one does not need a release here.
struct AgentProvider: Sendable, Hashable, Identifiable {
    let key: String
    let name: String
    let symbol: String
    /// Whether this agent reads a flat `<dir>/skills/<name>` folder. Hermes
    /// nests skills in category folders and Pencil ships its own, so neither is.
    let hasFlatLayout: Bool

    var id: String { key }
    var directoryName: String { ".\(key)" }

    /// The directory every conforming agent reads, whichever tool you are in.
    static let globals = AgentProvider(key: "agents", name: "Globals", symbol: "square.stack")

    /// Display names and SF Symbols for the agents we recognise. Keys follow the
    /// directory each agent actually uses; the agent names come from
    /// https://github.com/vercel/detect-agent.
    static let known: [AgentProvider] = [
        globals,
        AgentProvider(key: "claude", name: "Claude", symbol: "asterisk"),
        AgentProvider(key: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right"),
        AgentProvider(key: "cursor", name: "Cursor", symbol: "cursorarrow.rays"),
        AgentProvider(key: "copilot", name: "Copilot", symbol: "steeringwheel"),
        AgentProvider(key: "gemini", name: "Gemini", symbol: "sparkles"),
        AgentProvider(key: "kimi", name: "Kimi", symbol: "moon.stars"),
        AgentProvider(key: "grok", name: "Grok", symbol: "bolt"),
        AgentProvider(key: "opencode", name: "OpenCode", symbol: "curlybraces"),
        AgentProvider(key: "cline", name: "Cline", symbol: "terminal"),
        AgentProvider(key: "goose", name: "Goose", symbol: "bird"),
        AgentProvider(key: "hermes", name: "Hermes", symbol: "paperplane", hasFlatLayout: false),
        AgentProvider(key: "pencil", name: "Pencil", symbol: "pencil", hasFlatLayout: false),
    ]

    private static let knownByKey = Dictionary(
        uniqueKeysWithValues: known.map { ($0.key, $0) }
    )

    /// Directories that look like agent directories but are not.
    private static let ignoredKeys: Set<String> = ["Trash", "git", "build", "cache", "npm", "Trash-1000"]

    /// A provider for a directory we do not recognise: the folder name, capitalised.
    init(unknownKey key: String) {
        self.key = key
        self.name = key.prefix(1).uppercased() + key.dropFirst()
        self.symbol = "square.dashed"
        self.hasFlatLayout = false   // unknown layout; never write into it unasked
    }

    private init(key: String, name: String, symbol: String, hasFlatLayout: Bool = true) {
        self.key = key
        self.name = name
        self.symbol = symbol
        self.hasFlatLayout = hasFlatLayout
    }

    static func named(_ key: String) -> AgentProvider {
        knownByKey[key] ?? AgentProvider(unknownKey: key)
    }

    /// Every provider with a `skills` directory directly under `directory`.
    ///
    /// Known agents come first in table order, then anything else alphabetically,
    /// so the chip row does not reshuffle when a new directory appears.
    static func discovered(in directory: URL) -> [AgentProvider] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )) ?? []

        let keys = Set(
            contents.compactMap { url -> String? in
                let folder = url.lastPathComponent
                guard folder.hasPrefix("."), folder.count > 1 else { return nil }
                let key = String(folder.dropFirst())
                guard !ignoredKeys.contains(key) else { return nil }
                var isDirectory: ObjCBool = false
                let skills = url.appending(path: "skills").path
                guard FileManager.default.fileExists(atPath: skills, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }
                return key
            }
        )

        let recognised = known.filter { keys.contains($0.key) }
        let rest = keys.subtracting(recognised.map(\.key))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { AgentProvider(unknownKey: $0) }

        return recognised + rest
    }
}
