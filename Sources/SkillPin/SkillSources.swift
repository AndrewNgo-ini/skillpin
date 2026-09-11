import Foundation

struct SkillSources: Sendable {
    /// Shown for skills that are not recorded in the lock file.
    static let untracked = "Local / untracked"

    let sourcesBySkill: [String: String]

    static var `default`: SkillSources {
        let lockURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".agents/.skill-lock.json")
        return load(from: lockURL)
    }

    static func load(from url: URL) -> SkillSources {
        guard let data = try? Data(contentsOf: url),
              let lock = try? JSONDecoder().decode(LockFile.self, from: data) else {
            return SkillSources(sourcesBySkill: [:])
        }

        return SkillSources(
            sourcesBySkill: lock.skills.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.source ?? untracked
            }
        )
    }

    /// Source repositories in reading order, with the fallback bucket last.
    static func ordered(_ names: Set<String>) -> [String] {
        names.sorted {
            if ($0 == untracked) != ($1 == untracked) { return $1 == untracked }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private struct LockFile: Decodable {
        let skills: [String: LockEntry]
    }

    private struct LockEntry: Decodable {
        let source: String?
    }
}
