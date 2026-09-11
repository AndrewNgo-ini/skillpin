import AppKit
import SwiftUI

@main
struct SkillPinApp: App {
    var body: some Scene {
        MenuBarExtra("SkillPin", systemImage: "pin.fill") {
            SkillLibraryView()
                .frame(width: 440, height: 620)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct Skill: Identifiable {
    let id: String
    let name: String
    let summary: String
    let sourceURL: URL
    let fileURL: URL
    let origin: String?
    var pins: [Pin]
    let discoveredPins: [DiscoveredSkillPin]

    /// More than one real folder means copies exist that can disagree.
    var hasCopies: Bool { discoveredPins.filter { !$0.isLink }.count > 1 }

    /// Attach drift states to the pins. Hashes every real folder, so callers
    /// run it off the main thread and only for an expanded row.
    func withDrift(_ states: [String: SkillDrift.State]) -> Skill {
        var copy = self
        for index in copy.pins.indices {
            copy.pins[index].drift = states[copy.pins[index].id]
        }
        return copy
    }

    init(_ discovered: DiscoveredSkill, sources: SkillSources) {
        id = discovered.id
        name = discovered.name
        summary = discovered.description
        sourceURL = discovered.sourceURL
        fileURL = discovered.fileURL
        origin = discovered.pins.contains { !$0.isProject && $0.provider == .globals }
            ? sources.sourcesBySkill[discovered.name] ?? SkillSources.untracked
            : nil
        discoveredPins = discovered.pins

        // Resolve each link to the pin it points at, so the row can say
        // "Claude → Globals" instead of leaving the reader to infer it.
        var resolved = discovered.pins.map(Pin.init)
        let byRealPath = Dictionary(
            resolved.filter { !$0.isLink }.map { ($0.url.resolvingSymlinksInPath().path, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in resolved.indices where resolved[index].isLink {
            resolved[index].linkedTo = byRealPath[resolved[index].url.resolvingSymlinksInPath().path]
        }
        pins = resolved
    }
}

private struct Pin: Identifiable {
    let id: String
    let label: String
    let url: URL
    let provider: AgentProvider
    let isProject: Bool
    let isLink: Bool
    let project: String?
    /// For a symlink, the label of the pin it resolves to, when that is one of ours.
    var linkedTo: String?
    /// For a copy, whether it still matches the canonical folder. Nil until checked.
    var drift: SkillDrift.State?

    init(_ discovered: DiscoveredSkillPin) {
        id = discovered.id
        label = discovered.label
        url = discovered.url
        provider = discovered.provider
        isProject = discovered.isProject
        isLink = discovered.isLink
        project = discovered.project
    }

    var displayPath: String { url.abbreviatedPath }
}

private struct DriftKey: Equatable {
    let skill: String?
    let generation: Int
}

private struct ProjectSkillGroup: Identifiable {
    let id: String
    let skills: [Skill]
}

private struct SkillOriginGroup: Identifiable {
    let id: String
    let skills: [Skill]
}

private struct SkillLibraryView: View {
    @State private var search = ""
    @State private var filter: SkillFilter = .all
    @State private var visibleFilters = SkillFilter.primaryCases
    @State private var expandedSkill: String?
    @State private var expandedProjects: Set<String> = []
    @State private var expandedOrigins: Set<String> = []
    @State private var skills: [Skill] = []
    @State private var providers: [AgentProvider] = []
    /// Bumped on every reload so the drift check re-runs after a write.
    @State private var reloadGeneration = 0
    @State private var projectPaths = UserDefaults.standard.stringArray(forKey: "projectPaths") ?? []

    private var filteredSkills: [Skill] {
        skills.filter { skill in
            let matchesSearch = search.isEmpty ||
                skill.name.localizedCaseInsensitiveContains(search) ||
                skill.summary.localizedCaseInsensitiveContains(search)
            return matchesSearch && filter.includes(skill.discoveredPins)
        }
    }

    /// One group per repository, whatever mix of formats it holds.
    private var projectGroups: [ProjectSkillGroup] {
        let projects = Set(skills.flatMap(\.pins).compactMap(\.project))
        return projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { project in
            ProjectSkillGroup(
                id: project,
                skills: skills.filter { $0.pins.contains { $0.project == project } }
            )
        }
    }

    private var originGroups: [SkillOriginGroup] {
        let sourceNames = Set(filteredSkills.compactMap(\.origin))
        return SkillSources.ordered(sourceNames).map { source in
            SkillOriginGroup(
                id: source,
                skills: filteredSkills.filter { $0.origin == source }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            filterBar
            skillList
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { reloadSkills() }
        .task(id: DriftKey(skill: expandedSkill, generation: reloadGeneration)) {
            guard let id = expandedSkill, let skill = skills.first(where: { $0.id == id }) else { return }
            await checkDrift(of: skill)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Color(red: 0.80, green: 0.93, blue: 0.41), in: RoundedRectangle(cornerRadius: 7))

            Text("Skills")
                .font(.system(size: 14, weight: .semibold))
            Text("\(skills.count) available")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: reloadSkills) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh skills")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search skills", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleFilters) { option in
                    filterChip(option)
                }
                Menu {
                    ForEach(SkillFilter.optionalCases(for: providers).filter { !visibleFilters.contains($0) }) { option in
                        Button(option.title) {
                            visibleFilters.append(option)
                            filter = option
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 21, height: 21)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Add a filter")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
    }

    @ViewBuilder
    private func filterChip(_ option: SkillFilter) -> some View {
        if option == .projects {
            filterLabel(option)
        } else if !option.isPrimary {
            HStack(spacing: 0) {
                filterLabel(option)
                Button(action: { removeFilter(option) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: 23)
                }
                .buttonStyle(.plain)
                .help("Remove \(option.title) filter")
            }
            .background(filter == option ? Color(red: 0.92, green: 0.97, blue: 0.77) : .clear, in: RoundedRectangle(cornerRadius: 6))
        } else {
            filterLabel(option)
        }
    }

    private func filterLabel(_ option: SkillFilter) -> some View {
        Button(option.title) { selectFilter(option) }
            .font(.system(size: 11, weight: filter == option ? .semibold : .regular))
            .foregroundStyle(filter == option ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .buttonStyle(.plain)
            .background(
                option == .projects || !option.isPrimary
                    ? .clear
                    : (filter == option ? Color(red: 0.92, green: 0.97, blue: 0.77) : .clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if filteredSkills.isEmpty {
                    emptyState
                } else if filter == .projects {
                    groupToolbar(ids: projectGroups.map(\.id), expanded: $expandedProjects) {
                        Button(action: chooseProject) {
                            Label("Add project", systemImage: "plus")
                        }
                    }

                    ForEach(projectGroups) { group in
                        groupSection(
                            id: group.id,
                            title: group.id,
                            skills: group.skills,
                            expanded: $expandedProjects
                        )
                    }
                } else if filter == .globals {
                    groupToolbar(ids: originGroups.map(\.id), expanded: $expandedOrigins) { EmptyView() }

                    ForEach(originGroups) { group in
                        groupSection(
                            id: group.id,
                            title: group.id,
                            skills: group.skills,
                            expanded: $expandedOrigins
                        )
                    }
                } else {
                    ForEach(filteredSkills) { skill in
                        SkillRow(
                            skill: expandedSkill == skill.id ? skill.withDrift(driftStates) : skill,
                            providers: providers,
                            projectPaths: projectPaths,
                            isExpanded: expandedSkill == skill.id,
                            onTap: { toggle(skill) },
                            onToggle: { root, isProject, provider in
                                togglePin(at: root, isProject: isProject, provider: provider, of: skill)
                            },
                            outcome: expandedSkill == skill.id ? lastOutcome : nil
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line above a grouped list: optional leading control, and a toggle that
    /// opens every group or closes them, so the list can be read flat.
    private func groupToolbar<Leading: View>(
        ids: [String],
        expanded: Binding<Set<String>>,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        let allOpen = !ids.isEmpty && ids.allSatisfy { expanded.wrappedValue.contains($0) }
        return HStack(spacing: 14) {
            leading()
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if allOpen {
                        expanded.wrappedValue.subtract(ids)
                    } else {
                        expanded.wrappedValue.formUnion(ids)
                    }
                }
            } label: {
                Label(allOpen ? "Collapse all" : "Expand all",
                      systemImage: allOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .help(allOpen ? "Close every group" : "Show every skill in every group")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func groupSection(
        id: String,
        title: String,
        skills: [Skill],
        expanded: Binding<Set<String>>
    ) -> some View {
        let isExpanded = expanded.wrappedValue.contains(id)

        return VStack(alignment: .leading, spacing: 5) {
            Button {
                if isExpanded {
                    expanded.wrappedValue.remove(id)
                } else {
                    expanded.wrappedValue.insert(id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(title)
                    Spacer()
                    Text("\(skills.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(skills) { skill in
                    SkillRow(
                        skill: expandedSkill == skill.id ? skill.withDrift(driftStates) : skill,
                        providers: providers,
                        projectPaths: projectPaths,
                        isExpanded: expandedSkill == skill.id,
                        onTap: { toggle(skill) },
                        onToggle: { root, isProject, provider in
                            togglePin(at: root, isProject: isProject, provider: provider, of: skill)
                        },
                        outcome: expandedSkill == skill.id ? lastOutcome : nil
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(filter == .projects ? "No project skills yet" : "No matching skills")
                .font(.system(size: 13, weight: .medium))
            if filter == .projects {
                Text("Choose a project folder to scan its local skills.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Choose project folder…", action: chooseProject)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }

    private var footer: some View {
        HStack {
            Text("Every pin is a copy. Copies that drift are marked.")
            Spacer()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .monospacedDigit()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                .help("Quit SkillPin (⌘Q)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.45))
        .overlay(alignment: .top) { Divider() }
    }

    private func toggle(_ skill: Skill) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedSkill = expandedSkill == skill.id ? nil : skill.id
        }
        lastOutcome = nil
    }

    /// Result of the last write, shown under the pin controls until another row opens.
    @State private var lastOutcome: PinOutcome?
    /// Drift states for the expanded skill, keyed by pin id. Recomputed on every reload.
    @State private var driftStates: [String: SkillDrift.State] = [:]

    private func checkDrift(of skill: Skill) async {
        guard skill.hasCopies else { driftStates = [:]; return }
        let pins = skill.discoveredPins
        let states = await Task.detached(priority: .utility) { SkillDrift.states(for: pins) }.value
        driftStates = states
    }

    /// The menu is the action: choosing a location where the skill is absent
    /// pins it there, choosing one where it is present removes it.
    /// The Pin menu is the action for one cell: a place and a format. Absent
    /// there → copy it in; present → remove it.
    private func togglePin(at root: URL, isProject: Bool, provider: AgentProvider, of skill: Skill) {
        if isProject { rememberProject(root) }
        let existing = skill.discoveredPins.first { pin in
            pin.provider == provider && pin.isProject == isProject
                && (!isProject || pin.url.path.hasPrefix(root.path + "/"))
        }
        let flat = SkillPinner.destination(skillName: skill.name, at: root, provider: provider)
        let outcome: PinOutcome
        do {
            if let existing {
                if !existing.isLink {
                    let dependents = SkillPinner.dependents(of: existing, among: skill.discoveredPins)
                    let drifted = driftStates[existing.id] == .drifted
                    switch confirmRemoval(of: [existing.url], links: 0, dependents: dependents, drifted: drifted) {
                    case .cancel:
                        return
                    case .replace:
                        guard let canonical = SkillDrift.canonical(among: skill.discoveredPins) else { return }
                        try SkillDrift.update(existing, from: canonical)
                        lastOutcome = .init(text: "Replaced \(existing.url.abbreviatedPath) from \(canonical.label)", isError: false)
                        reloadSkills()
                        return
                    case .remove:
                        break
                    }
                }
                try SkillPinner.unpin(existing)
                outcome = .init(text: "Removed \(existing.isLink ? "link" : "folder") \(existing.url.abbreviatedPath)", isError: false)
            } else if case .brokenLink = SkillPinner.status(at: flat) {
                try SkillPinner.remove(at: flat)
                outcome = .init(text: "Removed broken link \(flat.abbreviatedPath)", isError: false)
            } else {
                let plan = try SkillPinner.plan(skillName: skill.name, pins: skill.discoveredPins, to: root, provider: provider).get()
                try SkillPinner.perform(plan)
                outcome = .init(text: "Copied to \(plan.destination.abbreviatedPath)", isError: false)
            }
        } catch {
            outcome = .init(text: error.localizedDescription, isError: true)
        }
        lastOutcome = outcome
        reloadSkills()
    }

    private enum RemovalChoice { case remove, replace, cancel }

    /// Deleting a real folder is the one destructive step, so it asks. A drifted
    /// copy gets a third way out: take the canonical contents instead of deleting.
    private func confirmRemoval(of folders: [URL], links: Int, dependents: [DiscoveredSkillPin], drifted: Bool) -> RemovalChoice {
        let alert = NSAlert()
        alert.messageText = folders.count == 1 ? "Delete this copy?" : "Delete these \(folders.count) copies?"
        var detail = folders.map(\.abbreviatedPath).joined(separator: "\n")
        if links > 0 { detail += "\n\nand \(links) link\(links == 1 ? "" : "s") to it here." }
        if drifted { detail += "\n\nA copy here differs from the canonical one; those differences are lost." }
        if !dependents.isEmpty {
            detail += "\n\n\(dependents.count) link\(dependents.count == 1 ? "" : "s") elsewhere point here and would break: "
                + dependents.map(\.label).joined(separator: ", ") + "."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if drifted { alert.addButton(withTitle: "Replace with canonical") }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .remove
        case .alertThirdButtonReturn: return .replace
        default: return .cancel
        }
    }

    private func reloadSkills() {
        let projectRoots = projectPaths.flatMap {
            ProjectSkillRoots.roots(for: URL(fileURLWithPath: $0))
        }
        let sources = SkillSources.default
        providers = AgentProvider.discovered(in: FileManager.default.homeDirectoryForCurrentUser)
        skills = SkillCatalog(roots: SkillCatalog.defaultRoots + projectRoots)
            .discover()
            .map { Skill($0, sources: sources) }
        reloadGeneration += 1
    }

    private func chooseProject() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Add project"
            panel.level = .modalPanel

            guard panel.runModal() == .OK, let url = panel.url else { return }
            addProject(url)
        }
    }

    private func addProject(_ url: URL) {
        rememberProject(url)
        filter = .projects
        reloadSkills()
    }

    private func rememberProject(_ url: URL) {
        guard !projectPaths.contains(url.path) else { return }
        projectPaths.append(url.path)
        UserDefaults.standard.set(projectPaths, forKey: "projectPaths")
    }

    private func selectFilter(_ option: SkillFilter) {
        if option == .projects && projectPaths.isEmpty {
            chooseProject()
        } else {
            filter = option
        }
    }

    private func removeFilter(_ option: SkillFilter) {
        guard !option.isPrimary else { return }
        visibleFilters.removeAll { $0 == option }
        if filter == option {
            filter = .all
        }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let providers: [AgentProvider]
    let projectPaths: [String]
    let isExpanded: Bool
    let onTap: () -> Void
    let onToggle: (URL, Bool, AgentProvider) -> Void
    let outcome: PinOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "circle.dashed")
                    .frame(width: 29, height: 29)
                    .background(isExpanded ? Color(red: 0.92, green: 0.97, blue: 0.77) : Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold))
                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                Spacer(minLength: 6)
                PinMenu(
                    skill: skill,
                    providers: providers,
                    projectPaths: projectPaths,
                    onToggle: onToggle
                )
            }

            if !skill.pins.isEmpty {
                HStack(spacing: 5) {
                    ForEach(skill.pins) { pin in
                        PinTag(pin: pin)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 39)
            }

            if isExpanded {
                SkillContentView(fileURL: skill.fileURL)
                    .padding(.top, 13)
                    .padding(.leading, 39)

                if let outcome {
                    Label(outcome.text, systemImage: outcome.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(outcome.isError ? .red : .secondary)
                        .lineLimit(2)
                        .padding(.top, 10)
                        .padding(.leading, 39)
                }
            }
        }
        .padding(12)
        .background(isExpanded ? Color(red: 0.985, green: 0.99, blue: 0.96) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isExpanded ? Color(red: 0.85, green: 0.89, blue: 0.74) : .clear))
    }
}

/// The Markdown body of a skill, under its frontmatter. Collapsed until asked for.
private struct SkillContentView: View {
    let fileURL: URL
    @State private var isOpen = false
    @State private var text: AttributedString?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("SKILL.MD")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(fileURL.path)
            }

            if isOpen {
                ScrollView {
                    Group {
                        if let text {
                            Text(text)
                        } else if failed {
                            Text("This skill could not be read.").foregroundStyle(.secondary)
                        } else {
                            Text("Reading…").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .task(id: isOpen) {
            guard isOpen, text == nil, !failed else { return }
            await load()
        }
    }

    private func load() async {
        let url = fileURL
        let document = await Task.detached(priority: .userInitiated) {
            SkillDocument.read(at: url)
        }.value

        guard let document else {
            failed = true
            return
        }

        // Inline-only keeps the author's line breaks; block syntax would collapse them.
        text = (try? AttributedString(
            markdown: document.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(document.body)
    }
}

private struct PinTag: View {
    let pin: Pin

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pin.provider.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pin.isProject ? .secondary : .primary)
            Text(pin.label)
                .lineLimit(1)
            if pin.isLink {
                Image(systemName: "link")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Symlink to \(pin.linkedTo ?? "another copy")")
            } else if pin.drift == .drifted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("This copy differs from the canonical folder")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(pin.isProject ? Color(nsColor: .quaternaryLabelColor).opacity(0.12) : Color(red: 0.91, green: 0.96, blue: 0.78), in: RoundedRectangle(cornerRadius: 5))
        .help(pin.displayPath)
    }
}

/// One line under the menus: what the last write did, or why it failed, and
/// optionally one thing to do next.
struct PinOutcome: Equatable {
    let text: String
    let isError: Bool
}

/// One Pin menu over the whole grid: a submenu per place, a row per format,
/// `.agents` first. A tick is presence in that cell; choosing a row toggles it.
/// The place row carries a checkmark and a count when any format holds the skill.
private struct PinMenu: View {
    let skill: Skill
    let providers: [AgentProvider]
    let projectPaths: [String]
    let onToggle: (URL, Bool, AgentProvider) -> Void

    private struct Location: Identifiable {
        let id: String
        let title: String
        let root: URL
        let isProject: Bool
    }

    private var locations: [Location] {
        [Location(id: "global", title: "Global", root: FileManager.default.homeDirectoryForCurrentUser, isProject: false)]
            + projectPaths.map { path in
                let url = URL(fileURLWithPath: path)
                return Location(id: path, title: url.lastPathComponent, root: url, isProject: true)
            }
    }

    /// `.agents` leads; the rest keep discovery order.
    private var formats: [AgentProvider] {
        providers.filter { $0 == .globals } + providers.filter { $0 != .globals }
    }

    private func isPresent(at location: Location, in format: AgentProvider) -> Bool {
        skill.discoveredPins.contains { pin in
            pin.provider == format && pin.isProject == location.isProject
                && (!location.isProject || pin.url.path.hasPrefix(location.root.path + "/"))
        }
    }

    var body: some View {
            Menu {
                ForEach(locations) { location in
                    // One submenu per place keeps the top level to a few rows; the
                    // count in the title says how many formats hold the skill there.
                    let present = formats.filter { isPresent(at: location, in: $0) }.count
                    Menu {
                        ForEach(formats) { format in
                            Toggle(isOn: Binding(
                                get: { isPresent(at: location, in: format) },
                                set: { _ in onToggle(location.root, location.isProject, format) }
                            )) {
                                Label("\(format.name) (\(format.directoryName))", systemImage: format.symbol)
                            }
                        }
                    } label: {
                        Label(
                            present == 0 ? location.title : "\(location.title)  ·  \(present)",
                            systemImage: present == 0 ? (location.isProject ? "folder" : "house") : "checkmark"
                        )
                    }
                }
                Divider()
                Button("Choose project…", action: chooseFolder)
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .font(.system(size: 11))
            .help("Where this skill is installed, and where to copy it")
    }

    /// A new project gets the skill in `.agents`; other formats are one more click.
    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Pin to project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onToggle(url, true, .globals)
    }
}
