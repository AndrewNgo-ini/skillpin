import Foundation

struct SkillRoot: Sendable {
    let label: String
    let url: URL
    let provider: AgentProvider
    let isProject: Bool
    /// The repository this root belongs to. One project has one root per format.
    let project: String?

    init(label: String? = nil, url: URL, provider: AgentProvider, isProject: Bool = false, project: String? = nil) {
        self.label = label ?? provider.name
        self.url = url
        self.provider = provider
        self.isProject = isProject
        self.project = project
    }
}

struct DiscoveredSkill: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sourceURL: URL
    let fileURL: URL
    let pins: [DiscoveredSkillPin]
}

struct DiscoveredSkillPin: Identifiable, Sendable {
    let id: String
    let label: String
    let url: URL
    let provider: AgentProvider
    let isProject: Bool
    /// The skill folder here is a symlink to a copy somewhere else.
    let isLink: Bool
    var project: String? = nil
}

struct SkillCatalog: Sendable {
    let roots: [SkillRoot]

    /// Every agent directory in the home folder that holds a `skills` folder,
    /// plus one root per Hermes profile.
    static var defaultRoots: [SkillRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = AgentProvider.discovered(in: home).map { provider in
            SkillRoot(
                url: home.appending(path: "\(provider.directoryName)/skills"),
                provider: provider
            )
        }

        let hermes = AgentProvider.named("hermes")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: home.appending(path: "\(hermes.directoryName)/profiles"),
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        roots += profiles.map {
            SkillRoot(
                label: "\(hermes.name) \($0.lastPathComponent)",
                url: $0.appending(path: "skills"),
                provider: hermes
            )
        }

        return roots
    }

    static var `default`: SkillCatalog { SkillCatalog(roots: defaultRoots) }

    func discover() -> [DiscoveredSkill] {
        var skills: [String: DiscoveredSkill] = [:]

        for root in roots {
            for fileURL in skillFiles(in: root.url) {
                guard let metadata = parseSkill(at: fileURL) else { continue }
                let folder = fileURL.deletingLastPathComponent()
                let pin = DiscoveredSkillPin(
                    id: root.label + fileURL.path,
                    label: root.label,
                    url: folder,
                    provider: root.provider,
                    isProject: root.isProject,
                    isLink: (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                    project: root.project
                )

                if var existing = skills[metadata.name] {
                    if !existing.pins.contains(where: { $0.url == pin.url }) {
                        existing = DiscoveredSkill(
                            id: existing.id,
                            name: existing.name,
                            description: existing.description,
                            sourceURL: existing.sourceURL,
                            fileURL: existing.fileURL,
                            pins: existing.pins + [pin]
                        )
                        skills[metadata.name] = existing
                    }
                } else {
                    skills[metadata.name] = DiscoveredSkill(
                        id: metadata.name,
                        name: metadata.name,
                        description: metadata.description,
                        sourceURL: fileURL.deletingLastPathComponent(),
                        fileURL: fileURL,
                        pins: [pin]
                    )
                }
            }
        }

        return skills.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Every SKILL.md under `root`, following symlinked folders. Agents that install
    /// from a shared directory symlink into their own, and FileManager's enumerator
    /// does not descend into those, so this walks by hand.
    private func skillFiles(in root: URL) -> [URL] {
        var found: [URL] = []
        var visited: Set<String> = []

        func walk(_ directory: URL) {
            let real = directory.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { return }   // symlink cycles

            // The path-based listing follows a symlinked folder; the URL-based one
            // refuses with ENOTDIR. Children keep the unresolved path so a pin
            // reports where the link is, not where it points.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

            for name in names where !name.hasPrefix(".") {
                let entry = directory.appending(path: name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(entry)
                } else if entry.lastPathComponent == "SKILL.md" {
                    found.append(entry)
                }
            }
        }

        walk(root)
        return found
    }

    private func parseSkill(at url: URL) -> (name: String, description: String)? {
        guard let document = SkillDocument.read(at: url),
              let name = document.name,
              let summary = document.summary else { return nil }
        return (name, summary)
    }
}

enum ProjectSkillRoots {
    /// The same discovery rule as the home folder, applied to a repository.
    static func roots(for projectURL: URL) -> [SkillRoot] {
        let project = projectURL.lastPathComponent
        return AgentProvider.discovered(in: projectURL).map { provider in
            // Inside a project, .agents is the unqualified location; naming it
            // "Globals" would contradict the pin being project-scoped.
            SkillRoot(
                label: provider == .globals ? project : "\(project): \(provider.name)",
                url: projectURL.appending(path: "\(provider.directoryName)/skills"),
                provider: provider,
                isProject: true,
                project: project
            )
        }
    }
}
