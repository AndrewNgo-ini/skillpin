import Foundation

enum SkillFilter: Hashable, Identifiable {
    case all
    case globals
    case projects
    case provider(AgentProvider)

    var id: String {
        switch self {
        case .all: "all"
        case .globals: "globals"
        case .projects: "projects"
        case .provider(let provider): "provider.\(provider.key)"
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .globals: "Globals"
        case .projects: "Projects"
        case .provider(let provider): provider.name
        }
    }

    static let primaryCases: [SkillFilter] = [.all, .globals, .projects]

    var isPrimary: Bool { Self.primaryCases.contains(self) }

    /// Providers that can be added as their own chip: everything installed
    /// except the globals directory, which already has a primary chip.
    static func optionalCases(for providers: [AgentProvider]) -> [SkillFilter] {
        providers.filter { $0 != .globals }.map(SkillFilter.provider)
    }

    func includes(_ pins: [DiscoveredSkillPin]) -> Bool {
        switch self {
        case .all:
            true
        case .globals:
            pins.contains { !$0.isProject && $0.provider == .globals }
        case .projects:
            pins.contains(where: \.isProject)
        case .provider(let provider):
            pins.contains { !$0.isProject && $0.provider == provider }
        }
    }
}
