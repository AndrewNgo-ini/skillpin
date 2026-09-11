import CryptoKit
import Foundation

/// Whether a real copy of a skill still matches the canonical one.
///
/// Links cannot drift: they resolve to whatever the target holds. Copies can,
/// and nothing on the system tells you when they have, so this hashes every
/// file in each real folder and compares.
enum SkillDrift {
    enum State: Sendable, Equatable {
        /// A link, or the canonical folder itself.
        case notApplicable
        /// Byte-for-byte the same as the canonical folder.
        case inSync
        /// Differs from the canonical folder.
        case drifted
    }

    /// One digest for a whole folder: relative path and bytes of every regular
    /// file, sorted, so two folders with the same contents agree regardless of
    /// creation order. Hidden files (.DS_Store) are skipped.
    static func digest(of folder: URL) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        var files: [(String, URL)] = []
        func walk(_ directory: URL, prefix: String) {
            for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasPrefix(".") {
                let url = directory.appending(path: name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    walk(url, prefix: prefix + name + "/")
                } else {
                    files.append((prefix + name, url))
                }
            }
        }
        walk(folder, prefix: "")

        var hasher = SHA256()
        for (relativePath, url) in files.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The pin the others are compared against: the real Globals folder when
    /// there is one, otherwise the first real folder in discovery order.
    static func canonical(among pins: [DiscoveredSkillPin]) -> DiscoveredSkillPin? {
        let real = pins.filter { !$0.isLink }
        return real.first { !$0.isProject && $0.provider == .globals } ?? real.first
    }

    /// Drift state per pin id. Cheap when there is at most one real folder:
    /// nothing is read from disk.
    static func states(for pins: [DiscoveredSkillPin]) -> [String: State] {
        var result: [String: State] = [:]
        for pin in pins { result[pin.id] = .notApplicable }

        let real = pins.filter { !$0.isLink }
        guard real.count > 1, let canonical = canonical(among: pins),
              let canonicalDigest = digest(of: canonical.url) else { return result }

        for pin in real where pin.id != canonical.id {
            result[pin.id] = digest(of: pin.url) == canonicalDigest ? .inSync : .drifted
        }
        return result
    }

    /// Replace `target`'s folder with the canonical one's contents.
    static func update(_ target: DiscoveredSkillPin, from canonical: DiscoveredSkillPin) throws {
        let fileManager = FileManager.default
        let staging = target.url.deletingLastPathComponent()
            .appending(path: ".\(target.url.lastPathComponent).skillpin-update")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: canonical.url.resolvingSymlinksInPath(), to: staging)
        // Copy first, then swap, so a failure mid-copy leaves the old copy intact.
        _ = try fileManager.replaceItemAt(target.url, withItemAt: staging)
    }
}
