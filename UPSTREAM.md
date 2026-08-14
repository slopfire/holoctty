# Living on Ghostty

Holoctty is a Ghostty fork. The emulator, renderer, and `libghostty` stay
Ghostty's. This file is the contract for keeping that cheap.

Do not open issues or pull requests against `ghostty-org/ghostty` for
Holoctty chrome. Do not invent `ghostty-org/holoctty` URLs.

## Identity vs voice

Change **runtime identity**. Leave **Ghostty's voice** in shared files.

Keep (product):

- Binary name `holoctty`
- GTK app id `com.sfire.holoctty` (`com.sfire.holoctty-debug` in debug)
  in `src/apprt/gtk/build/info.zig` — Plasma looks up the taskbar icon
  from this id
- Config / state / crash paths under `holoctty`
- Desktop, Flatpak, Snap, icons
- User-visible strings: About, window title, `+version`
- New GTK widgets and fork-only config keys

Do not sed in files Ghostty owns:

- Comments, examples, and history notes (`Ghostty 1.2 renamed…`)
- GObject type names for widgets that exist upstream (`GhosttyWindow`,
  `GhosttyTab`, Blueprint `$GhosttySurface`, …)
- `po/` and the pot filename `po/com.mitchellh.ghostty.pot`
- GitHub vouch / milestone / release workflows
- `HACKING.md` / `CONTRIBUTING.md` body (banners at the top are enough)

Fork-only GObject types stay `Holoctty*` (`HolocttySession`,
`HolocttyVerticalTab`, …).

gettext: source pot is Ghostty's name so translations rebase. Installed
`.mo` and runtime `textdomain` stay `com.sfire.holoctty` (the bundle id).

## Where new work goes

| Kind | Put it here |
| --- | --- |
| Sessions, vertical tabs, process icons | New files under `src/apprt/gtk/` plus a small attach site |
| Config keys | Additive fields in `src/config/Config.zig`, no comment rewrites |
| Keybinds / palette | Additive actions in `Binding.zig` / `command.zig` |
| Chrome fill policy | Keep the renderer hook tiny; GTK decides `extend-full` |
| Docs | `README.md`, this file, `.agents/skills/gtk-ui` |

Mark remaining core hunks with `// holoctty:` so the next rebase can see
them.

## Sync (local only)

`upstream` is `github.com/ghostty-org/ghostty`. This does not push, and
it does not open PRs.

```sh
./scripts/sync-upstream.sh          # ahead/behind only
./scripts/sync-upstream.sh --rebase # fetch + rebase onto upstream/main
```

After a rebase:

```sh
zig build -Demit-macos-app=false
zig build test -Dtest-filter='gtk tabs location'
zig build test -Dtest-filter='gtk session'
zig build test -Dtest-filter='window-padding-color parses extend-full'
```

Linux GUI checks use isolated `virt-shot`, not the live desktop.

Keep the fork as a short patch series (branding, vertical tabs, sessions,
icons, extend-full, docs). Do not squash it into one commit.
