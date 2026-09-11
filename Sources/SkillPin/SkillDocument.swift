import Foundation

/// A parsed `SKILL.md`: its YAML frontmatter fields and the Markdown beneath them.
struct SkillDocument: Sendable {
    let fields: [String: String]
    let body: String

    var name: String? { nonEmpty("name") }
    var summary: String? { nonEmpty("description") }

    static func read(at url: URL) -> SkillDocument? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SkillDocument(contents)
    }

    /// Frontmatter is the block between the first two `---` lines. A file without
    /// one is all body, which is how a skill with no metadata still reads.
    init(_ contents: String) {
        let lines = contents.components(separatedBy: .newlines)

        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            fields = [:]
            body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        fields = Self.parseFields(Array(lines[1..<end]))

        body = lines[lines.index(after: end)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enough YAML for frontmatter: `key: value`, quoted values, and the folded
    /// (`>`) and literal (`|`) block scalars that long descriptions use.
    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let separator = line.firstIndex(of: ":") else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            if let marker = value.first, marker == ">" || marker == "|" {
                var block: [String] = []
                while index < lines.count,
                      lines[index].hasPrefix(" ") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                // Folded joins the lines into one paragraph; literal keeps the breaks.
                value = marker == ">"
                    ? block.filter { !$0.isEmpty }.joined(separator: " ")
                    : block.joined(separator: "\n")
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count > 1,
                      (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }

            fields[key] = value
        }

        return fields
    }

    private func nonEmpty(_ key: String) -> String? {
        guard let value = fields[key], !value.isEmpty else { return nil }
        return value
    }
}
