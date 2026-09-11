import Foundation
import Testing
@testable import SkillPin

@Suite("Pin plans")
struct SkillPinnerTests {
    private func pin(_ key: String, at url: URL, isProject: Bool = false, isLink: Bool = false) -> DiscoveredSkillPin {
        let provider = AgentProvider.named(key)
        return DiscoveredSkillPin(id: url.path, label: provider.name, url: url, provider: provider, isProject: isProject, isLink: isLink)
    }
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: ".agents/skills/research"), withIntermediateDirectories: true)
        try "---\nname: research\ndescription: d\n---\nBody".write(
            to: url.appending(path: ".agents/skills/research/SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    @Test("Every pin is a copy, from the real Globals folder when there is one")
    func plansCopy() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let src = pin("agents", at: home.appending(path: ".agents/skills/research"))
        let link = pin("claude", at: home.appending(path: ".claude/skills/research"), isLink: true)

        let plan = try SkillPinner.plan(skillName: "research", pins: [link, src], to: home, provider: .named("codex")).get()

        #expect(plan.source.path == src.url.resolvingSymlinksInPath().path)
        #expect(plan.destination.path == home.appending(path: ".codex/skills/research").path)
    }

    @Test("Agents with a nested or private layout are refused with the reason")
    func refusesNonFlat() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let src = pin("agents", at: home.appending(path: ".agents/skills/research"))

        #expect(SkillPinner.plan(skillName: "research", pins: [src], to: home, provider: .named("hermes")) == .failure(.notFlat(.named("hermes"))))
        #expect(SkillPinner.plan(skillName: "research", pins: [src], to: home, provider: .named("pencil")) == .failure(.notFlat(.named("pencil"))))
    }

    @Test("A destination that already exists is refused, even as a dangling link")
    func refusesExisting() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let dest = home.appending(path: ".claude/skills/research")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dest, withDestinationURL: home.appending(path: "nowhere"))
        let src = pin("agents", at: home.appending(path: ".agents/skills/research"))

        #expect(SkillPinner.plan(skillName: "research", pins: [src], to: home, provider: .named("claude")) == .failure(.alreadyInstalled(dest)))
    }

    @Test("Performing copies the folder; the copy is a real folder and independent of the source")
    func performCopies() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let src = pin("agents", at: home.appending(path: ".agents/skills/research"))
        let plan = try SkillPinner.plan(skillName: "research", pins: [src], to: home.appending(path: "repo"), provider: .globals).get()

        try SkillPinner.perform(plan)
        try "changed".write(to: plan.source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        #expect(SkillPinner.status(at: plan.destination) == .folder)
        let copied = try String(contentsOf: plan.destination.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(copied.hasPrefix("---"), "the copy must not follow the source")
        #expect(SkillPinner.plan(skillName: "research", pins: [src], to: home.appending(path: "repo"), provider: .globals) == .failure(.alreadyInstalled(plan.destination)))
    }

    @Test("Unpinning a link removes only the link; dependents of a folder are reported")
    func unpinAndDependents() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.appending(path: ".agents/skills/research")
        let link = home.appending(path: ".claude/skills/research")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: canonical)
        let pins = [pin("agents", at: canonical), pin("claude", at: link, isLink: true)]

        #expect(SkillPinner.dependents(of: pins[0], among: pins).map(\.label) == ["Claude"])
        #expect(SkillPinner.dependents(of: pins[1], among: pins).isEmpty)

        try SkillPinner.unpin(pins[1])

        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: canonical.appending(path: "SKILL.md").path), "the canonical copy survives")
    }
}

@Suite("Destination status")
struct DestinationStatusTests {
    @Test("Absent, folder, link and broken link are told apart")
    func statuses() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appending(path: "folder")
        let target = root.appending(path: "target")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appending(path: "good"), withDestinationURL: target)
        try fm.createSymbolicLink(at: root.appending(path: "bad"), withDestinationURL: root.appending(path: "gone"))

        #expect(SkillPinner.status(at: root.appending(path: "nothing")) == .absent)
        #expect(SkillPinner.status(at: folder) == .folder)
        #expect(SkillPinner.status(at: root.appending(path: "good")) == .link(to: target.standardizedFileURL))
        #expect(SkillPinner.status(at: root.appending(path: "bad")) == .brokenLink(to: root.appending(path: "gone").standardizedFileURL))
        #expect(!SkillPinner.status(at: root.appending(path: "bad")).isInstalled, "a broken link is not an install")
    }

    @Test("A broken link at the destination still blocks a pin until it is removed")
    func brokenLinkBlocksThenClears() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let source = home.appending(path: ".agents/skills/research")
        let dest = home.appending(path: ".claude/skills/research")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dest, withDestinationURL: home.appending(path: "gone"))
        let pin = DiscoveredSkillPin(id: "s", label: "Globals", url: source, provider: .globals, isProject: false, isLink: false)

        #expect(SkillPinner.plan(skillName: "research", pins: [pin], to: home, provider: .named("claude")) == .failure(.alreadyInstalled(dest)))

        try SkillPinner.remove(at: dest)

        #expect(SkillPinner.status(at: dest) == .absent)
        #expect((try? SkillPinner.plan(skillName: "research", pins: [pin], to: home, provider: .named("claude")).get())?.destination == dest)
    }
}

@Suite("Drift")
struct SkillDriftTests {
    private func folder(_ files: [String: String], hidden: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "drift-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        if hidden { try "junk".write(to: url.appending(path: ".DS_Store"), atomically: true, encoding: .utf8) }
        return url
    }

    private func pin(_ key: String, at url: URL, isProject: Bool = false, isLink: Bool = false) -> DiscoveredSkillPin {
        let provider = AgentProvider.named(key)
        return DiscoveredSkillPin(id: url.path, label: provider.name, url: url, provider: provider, isProject: isProject, isLink: isLink)
    }

    @Test("Same contents give the same digest; hidden files and creation order do not matter")
    func digestIsContentOnly() throws {
        let a = try folder(["SKILL.md": "x", "ref/one.md": "1", "ref/two.md": "2"])
        let b = try folder(["ref/two.md": "2", "SKILL.md": "x", "ref/one.md": "1"], hidden: true)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        #expect(SkillDrift.digest(of: a) == SkillDrift.digest(of: b))
    }

    @Test("A changed byte or a renamed file changes the digest")
    func digestSeesChanges() throws {
        let a = try folder(["SKILL.md": "x", "ref/one.md": "1"])
        let b = try folder(["SKILL.md": "x", "ref/one.md": "2"])
        let c = try folder(["SKILL.md": "x", "ref/uno.md": "1"])
        defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }

        #expect(SkillDrift.digest(of: a) != SkillDrift.digest(of: b))
        #expect(SkillDrift.digest(of: a) != SkillDrift.digest(of: c))
    }

    @Test("Globals is canonical; a matching copy is in sync, a changed one has drifted, links are exempt")
    func states() throws {
        let globals = try folder(["SKILL.md": "v2"])
        let project = try folder(["SKILL.md": "v1"])
        let claude = try folder(["SKILL.md": "v2"])
        let link = globals.deletingLastPathComponent().appending(path: "link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: globals)
        defer { for u in [globals, project, claude, link] { try? FileManager.default.removeItem(at: u) } }

        let pins = [
            pin("agents", at: globals),
            pin("agents", at: project, isProject: true),
            pin("claude", at: claude),
            pin("codex", at: link, isLink: true),
        ]
        let states = SkillDrift.states(for: pins)

        #expect(SkillDrift.canonical(among: pins)?.url == globals)
        #expect(states[pins[0].id] == .notApplicable)
        #expect(states[pins[1].id] == .drifted)
        #expect(states[pins[2].id] == .inSync)
        #expect(states[pins[3].id] == .notApplicable)
    }

    @Test("With one real folder nothing is hashed and everything is not applicable")
    func singleCopyIsCheap() throws {
        let globals = try folder(["SKILL.md": "x"])
        defer { try? FileManager.default.removeItem(at: globals) }
        let pins = [pin("agents", at: globals)]

        #expect(SkillDrift.states(for: pins).values.allSatisfy { $0 == .notApplicable })
    }

    @Test("Update replaces the drifted copy with the canonical contents and removes stale files")
    func updateReplaces() throws {
        let globals = try folder(["SKILL.md": "v2", "ref/new.md": "n"])
        let project = try folder(["SKILL.md": "v1", "ref/old.md": "o"])
        defer { try? FileManager.default.removeItem(at: globals); try? FileManager.default.removeItem(at: project) }
        let canonical = pin("agents", at: globals)
        let target = pin("agents", at: project, isProject: true)

        try SkillDrift.update(target, from: canonical)

        let value1 = try String(contentsOf: project.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(value1 == "v2")
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "ref/new.md").path))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "ref/old.md").path), "stale files go too")
        #expect(SkillDrift.digest(of: project) == SkillDrift.digest(of: globals))
        #expect(!FileManager.default.fileExists(atPath: project.deletingLastPathComponent().appending(path: ".\(project.lastPathComponent).skillpin-update").path), "no staging folder left behind")
    }
}

@Suite("Skill documents")
struct SkillDocumentTests {
    @Test("Frontmatter is split from the body")
    func splitsFrontmatter() {
        let document = SkillDocument("""
        ---
        name: writing
        description: "Prose style guidance"
        ---
        # Writing

        Say what you mean.
        """)

        #expect(document.name == "writing")
        #expect(document.summary == "Prose style guidance")
        #expect(document.body == "# Writing\n\nSay what you mean.")
    }

    @Test("A file with no frontmatter is all body")
    func noFrontmatter() {
        let document = SkillDocument("Just notes.\n")

        #expect(document.name == nil)
        #expect(document.summary == nil)
        #expect(document.body == "Just notes.")
    }

    @Test("An empty description is treated as absent, so the skill is skipped")
    func emptyFieldsAreAbsent() {
        let document = SkillDocument("---\nname: writing\ndescription:\n---\nBody")

        #expect(document.name == "writing")
        #expect(document.summary == nil)
    }

    @Test("A folded block scalar becomes one paragraph")
    func foldedBlockScalar() {
        let document = SkillDocument("""
        ---
        name: backend-engineering
        description: >-
          A skill for backend engineering, including Python and FastAPI.
          Use when working on server-side tasks.
        ---
        # Backend
        """)

        #expect(document.name == "backend-engineering")
        #expect(document.summary == "A skill for backend engineering, including Python and FastAPI. Use when working on server-side tasks.")
        #expect(document.body == "# Backend")
    }

    @Test("A literal block scalar keeps its line breaks")
    func literalBlockScalar() {
        let document = SkillDocument("---\nname: a\ndescription: |\n  one\n  two\n---\nBody")

        #expect(document.summary == "one\ntwo")
    }

    @Test("A lone quote character is not stripped into a crash")
    func loneQuote() {
        let document = SkillDocument(#"---\#nname: a\#ndescription: "\#n---\#nBody"#)

        #expect(document.fields["description"] == "\"")
    }

    @Test("A body containing --- is not mistaken for the frontmatter end")
    func bodyKeepsItsRules() {
        let document = SkillDocument("---\nname: a\ndescription: b\n---\nOne\n\n---\n\nTwo")

        #expect(document.body == "One\n\n---\n\nTwo")
    }
}

@Suite("Skill discovery")
struct SkillCatalogTests {
    @Test("A project with two formats is still one project")
    func projectRootsShareTheProject() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: repo) }
        for path in [".agents/skills/a", ".claude/skills/b"] {
            try fm.createDirectory(at: repo.appending(path: path), withIntermediateDirectories: true)
            try "---\nname: \(path.suffix(1))\ndescription: d\n---\n".write(to: repo.appending(path: path + "/SKILL.md"), atomically: true, encoding: .utf8)
        }

        let roots = ProjectSkillRoots.roots(for: repo)
        let pins = SkillCatalog(roots: roots).discover().flatMap(\.pins)

        #expect(roots.count == 2)
        #expect(Set(roots.compactMap(\.project)) == [repo.lastPathComponent])
        #expect(Set(pins.compactMap(\.project)).count == 1, "both pins name the same project")
        #expect(pins.map(\.label).sorted() == [repo.lastPathComponent, "\(repo.lastPathComponent): Claude"], "labels still tell the formats apart")
    }

    @Test("Skills reached through a symlinked folder are found and marked as links")
    func followsSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let canonical = root.appending(path: ".agents/skills/research")
        let claude = root.appending(path: ".claude/skills")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try "---\nname: research\ndescription: Look things up.\n---\nBody"
            .write(to: canonical.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: claude.appending(path: "research"), withDestinationURL: canonical)

        let catalog = SkillCatalog(roots: [
            SkillRoot(url: root.appending(path: ".agents/skills"), provider: .globals),
            SkillRoot(url: claude, provider: .named("claude")),
        ])
        let skills = catalog.discover()

        #expect(skills.count == 1)
        let pins = try #require(skills.first?.pins)
        #expect(pins.count == 2)
        #expect(pins.first { $0.provider == .globals }?.isLink == false)
        #expect(pins.first { $0.provider.key == "claude" }?.isLink == true)
    }
}

@Suite("Agent providers")
struct AgentProviderTests {
    @Test("Known agents carry a name and their own symbol")
    func knownAgents() {
        #expect(AgentProvider.named("claude").name == "Claude")
        #expect(AgentProvider.named("claude").symbol == "asterisk")
        #expect(AgentProvider.named("codex").name == "Codex")
        #expect(AgentProvider.globals.name == "Globals")

        let symbols = AgentProvider.known.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "every known agent needs its own symbol")
    }

    @Test("An unknown directory becomes a capitalised provider")
    func unknownAgent() {
        let provider = AgentProvider.named("windsurf")

        #expect(provider.name == "Windsurf")
        #expect(provider.directoryName == ".windsurf")
        #expect(provider.symbol == "square.dashed")
    }

    @Test("Discovery finds any dot-directory holding a skills folder")
    func discovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "providers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for path in [".claude/skills", ".agents/skills", ".windsurf/skills", ".Trash/skills", ".config"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: path),
                withIntermediateDirectories: true
            )
        }

        let found = AgentProvider.discovered(in: root).map(\.key)

        #expect(found == ["agents", "claude", "windsurf"], "known agents first, then the rest")
        #expect(!found.contains("Trash"))
        #expect(!found.contains("config"), "a dot-directory without a skills folder is not a provider")
    }
}

@Suite("Filters")
struct SkillFilterTests {
    private func pin(_ key: String, isProject: Bool = false) -> DiscoveredSkillPin {
        let provider = AgentProvider.named(key)
        return DiscoveredSkillPin(
            id: key,
            label: provider.name,
            url: URL(fileURLWithPath: "/tmp/\(key)"),
            provider: provider,
            isProject: isProject,
            isLink: false
        )
    }

    @Test("A provider filter matches only that agent's global pins")
    func providerFilter() {
        let pins = [pin("agents"), pin("claude", isProject: true)]

        #expect(SkillFilter.provider(.named("agents")).includes(pins))
        #expect(!SkillFilter.provider(.named("claude")).includes(pins), "a project pin is not a global one")
        #expect(SkillFilter.projects.includes(pins))
        #expect(SkillFilter.globals.includes(pins))
        #expect(SkillFilter.all.includes(pins))
    }

    @Test("Globals has its own chip, so it is not offered again as an optional one")
    func optionalChips() {
        let optional = SkillFilter.optionalCases(for: [.globals, .named("claude")])

        #expect(optional == [.provider(.named("claude"))])
    }
}

@Suite("Skill sources")
struct SkillSourcesTests {
    @Test("Skills without a recorded source fall back to the untracked bucket")
    func missingSourceIsUntracked() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "skill-lock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("""
        {"skills": {
          "research": {"source": "mattpocock/skills"},
          "handoff": {}
        }}
        """.utf8).write(to: url)

        let sources = SkillSources.load(from: url)

        #expect(sources.sourcesBySkill["research"] == "mattpocock/skills")
        #expect(sources.sourcesBySkill["handoff"] == SkillSources.untracked)
    }

    @Test("A missing or unreadable lock file yields no sources")
    func missingLockFile() {
        let url = FileManager.default.temporaryDirectory.appending(path: "no-such-lock.json")

        #expect(SkillSources.load(from: url).sourcesBySkill.isEmpty)
    }

    @Test("Repositories sort alphabetically, with the untracked bucket last")
    func untrackedSortsLast() {
        let ordered = SkillSources.ordered([
            "mattpocock/skills",
            SkillSources.untracked,
            "Leonxlnx/taste-skill",
            "AndrewNgo-ini/contextbox-company",
        ])

        #expect(ordered == [
            "AndrewNgo-ini/contextbox-company",
            "Leonxlnx/taste-skill",
            "mattpocock/skills",
            SkillSources.untracked,
        ])
    }
}
