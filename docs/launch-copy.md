# Launch copy

Reusable text for the repository, the landing page, and launch posts. Everything
here matches what version 0.1.0 actually does. Writing a pin is not implemented
yet, so no post below claims it is.

## One-liners

- **Short:** A native macOS menu-bar library for AI agent skills.
- **Explanatory:** SkillPin lists every agent skill installed on your Mac and shows the directories each one is available in.
- **Positioning:** Agent skills are folders with a `SKILL.md` inside, and each agent reads its own directory. SkillPin reads all of them and shows one list.

## GitHub repository settings

**About:** A native macOS menu-bar library for AI agent skills. See every skill you have installed, and where.

**Website:** https://andrewngo-ini.github.io/skillpin

**Topics:** `macos` `menubar` `swiftui` `swift` `ai-agents` `claude-code` `agent-skills` `developer-tools`

## Show HN

> **Show HN: SkillPin – a macOS menu-bar library for AI agent skills**

I use Claude Code and Codex, and my skills ended up scattered across
`~/.agents/skills`, `~/.claude/skills`, and `.claude/skills` folders inside
several repositories. To find out what I had installed I ran `ls` in four places
and opened files to read the frontmatter.

SkillPin is a small SwiftUI menu-bar app that walks those directories, parses the
`SKILL.md` frontmatter, and shows one list. Each entry is the skill; the pins
underneath it are the places that skill is currently available. Shared skills
also show the GitHub repository they were installed from, read from
`~/.agents/.skill-lock.json`.

It is version 0.1.0. Reading, searching, filtering, and scanning project folders
work. Writing a pin from the app does not yet — the sheet builds the destination
path and shows it, but does not copy the skill there. I am posting now because
the pin model is the part worth arguing about before it is settled.

macOS 14+, SwiftUI, no dependencies, MIT. Build it with
`./Scripts/package-app.sh`.

## X / Bluesky

> SkillPin: a macOS menu-bar app that lists every AI agent skill you have
> installed and the directories each one is available in.
>
> One list instead of `ls` across `~/.agents`, `~/.claude`, `~/.codex` and every
> repository you work in.
>
> SwiftUI, no dependencies, MIT.

## r/macapps

**Title:** SkillPin — free menu-bar app that shows every AI agent skill installed on your Mac

**Body:**

If you use Claude Code, Codex, or another agent that loads skills from a
`SKILL.md` folder, those folders pile up in several directories at once.
SkillPin puts them in one searchable list in the menu bar, with the locations
each skill is available in shown underneath it.

- Free and open source (MIT)
- macOS 14 or later, SwiftUI, no dependencies, no dock icon
- Version 0.1.0: browsing, search, filters, and project scanning work; writing a pin from the app is not implemented yet
- Build from source, no signed release yet

https://github.com/AndrewNgo-ini/skillpin

## Notes for whoever writes the next post

- Say "pin" only for a location where a skill is available. It is the product's own term and the interface uses it.
- Do not claim the app installs or copies skills until `pin(_:)` in `SkillPinApp.swift` does something other than reload.
- The supported directories are listed in `SkillCatalog.defaultRoots`. Check there before naming an agent in a post.
