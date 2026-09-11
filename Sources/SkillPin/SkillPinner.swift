import Foundation

/// What pinning would write, worked out before anything is written so the
/// interface can say it first. Every pin is a copy: each agent reads its own
/// folder, and a folder you can see is a folder you can reason about.
struct PinPlan: Sendable, Equatable {
    let source: URL
    let destination: URL
}

enum PinError: LocalizedError, Equatable {
    case alreadyInstalled(URL)
    case noSource
    case notFlat(AgentProvider)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let url): "Already at \(url.abbreviatedPath)."
        case .noSource: "There is no copy of this skill to pin from."
        case .notFlat(let agent): "\(agent.name) keeps its own layout; SkillPin does not write there."
        }
    }
}

enum SkillPinner {
    /// The folder to copy from: a real folder in Globals, then any real global
    /// folder, then a project folder, then whatever a link resolves to.
    static func source(from pins: [DiscoveredSkillPin]) -> DiscoveredSkillPin? {
        let real = pins.filter { !$0.isLink }
        return real.first { !$0.isProject && $0.provider == .globals }
            ?? real.first { !$0.isProject }
            ?? real.first
            ?? pins.first
    }

    static func destination(skillName: String, at root: URL, provider: AgentProvider) -> URL {
        root.appending(path: "\(provider.directoryName)/skills/\(skillName)")
    }

    static func plan(
        skillName: String,
        pins: [DiscoveredSkillPin],
        to root: URL,
        provider: AgentProvider
    ) -> Result<PinPlan, PinError> {
        guard provider == .globals || provider.hasFlatLayout else { return .failure(.notFlat(provider)) }
        guard let source = source(from: pins) else { return .failure(.noSource) }
        let destination = destination(skillName: skillName, at: root, provider: provider)
        guard status(at: destination) == .absent else { return .failure(.alreadyInstalled(destination)) }
        return .success(PinPlan(source: source.url.resolvingSymlinksInPath(), destination: destination))
    }

    static func perform(_ plan: PinPlan) throws {
        let fileManager = FileManager.default
        guard status(at: plan.destination) == .absent else { throw PinError.alreadyInstalled(plan.destination) }
        try fileManager.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: plan.source, to: plan.destination)
    }

    /// Removes the pin at its own path. For a link that is the link alone; for a
    /// folder it is the folder and everything in it.
    static func unpin(_ pin: DiscoveredSkillPin) throws {
        try FileManager.default.removeItem(at: pin.url)
    }

    /// Links that resolve to this pin. Removing it would leave them dangling.
    static func dependents(of pin: DiscoveredSkillPin, among pins: [DiscoveredSkillPin]) -> [DiscoveredSkillPin] {
        guard !pin.isLink else { return [] }
        let target = pin.url.resolvingSymlinksInPath().path
        return pins.filter { $0.isLink && $0.id != pin.id && $0.url.resolvingSymlinksInPath().path == target }
    }

    /// What is at a pin destination right now.
    enum Status: Sendable, Equatable {
        case absent
        case folder
        case link(to: URL)
        /// A symlink whose target no longer exists.
        case brokenLink(to: URL)

        var isInstalled: Bool {
            switch self {
            case .folder, .link: true
            case .absent, .brokenLink: false
            }
        }
    }

    static func status(at url: URL) -> Status {
        let fileManager = FileManager.default
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            return fileManager.fileExists(atPath: resolved.path) ? .link(to: resolved) : .brokenLink(to: resolved)
        }
        return fileManager.fileExists(atPath: url.path) ? .folder : .absent
    }

    /// Remove whatever is at `url`: a link, a broken link, or a folder.
    static func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

extension URL {
    /// `~/.claude/skills/research` rather than the full home path.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
