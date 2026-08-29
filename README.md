<!-- LOGO -->
<h1>
<p align="center">
  <img src="images/icons/icon_128.png" alt="Holoctty" width="128">
  <br>Holoctty
</h1>
  <p align="center">
    A <a href="https://github.com/ghostty-org/ghostty">Ghostty</a> fork for Linux
    with vertical tabs, named tab groups, persistent sessions, and process-aware chrome.
    <br />
    Same terminal engine. Different GTK app.
    <br />
    <a href="#about">About</a>
    ·
    <a href="#changes-from-ghostty">Changes</a>
    ·
    <a href="#build-and-install">Install</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="https://ghostty.org/docs">Upstream docs</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

<p align="center">
  <img src="images/screenshot.jpg" alt="Holoctty on Linux with named tab groups, git status on vertical tabs, a compact session bar, and the recolored +boo easter egg" width="900">
</p>

## About

Holoctty is a low-effort slopfork of [Ghostty](https://github.com/ghostty-org/ghostty)
focused on the Linux GTK application. It keeps Ghostty's terminal emulator,
renderer, and `libghostty` core, and changes the window chrome: tabs live
in a resizable sidebar, related terminals are grouped into sessions, tabs
inside a session can be clustered into named color groups, and the sidebar
shows the running process plus git dirty, staged, ahead, and behind counts.

PRs extending and fixing icon support are appreciated

The binary is `holoctty`. The GTK application id is `com.sfire.holoctty`
(debug builds use `com.sfire.holoctty-debug`). Configuration lives at
`~/.config/holoctty/config.holoctty`.

Everything that is not listed under [Changes from Ghostty](#changes-from-ghostty)
is inherited from upstream. Use the
[Ghostty documentation](https://ghostty.org/docs) for terminal sequences,
fonts, keybinds, shell integration, and the rest of the shared config.

## Changes from Ghostty

These are the fork-only changes on top of Ghostty. They apply to the GTK
(Linux / FreeBSD) app unless noted.

### Vertical tab sidebar

`gtk-tabs-location` accepts `left` and `right` in addition to Ghostty's
`top` and `bottom`. Vertical tabs are a resizable sidebar of cards, not
a rotated tab strip.

Each card shows:

- The foreground process name and a symbolic icon (agent, TUI, or shell)
- Working directory, with a git icon when the directory is inside a repo
- Git status tokens, colored from the GTK scheme: `*14` dirty, `+3`
  staged, `↑183` ahead of upstream, `↓27` behind. Zero counts are omitted.
- SSH host and a remote-server icon when the tab is a remote session
- How long the tab has been open

Right-click a vertical tab and choose **Set Folder Icon…** to override its
location icon. The picker has folder, Git, and server icons in eight colors,
plus a system theme icon, an image URL, or a local file. An assignment covers
that directory and its descendants. Rules are stored in
`$XDG_STATE_HOME/holoctty/folder-icons.json` (normally
`~/.local/state/holoctty/folder-icons.json`).

Remote tabs offer **Set Remote Icon…** instead. The assignment is stored by
SSH or Mosh host and reused the next time that host appears.

The sidebar width is remembered in XDG state (`~/.local/state/holoctty`)
and restored for new windows. Dragging snaps to device pixels so
fractional scaling does not leave a ragged edge. Tabs can be reordered
by dragging.

Vertical tabs force the `native` titlebar style, because Ghostty's
`tabs` titlebar only works with a horizontal tab bar.

### Persistent sessions

A session is a live group of tabs. Switching sessions keeps the other
groups running; closing or dragging a session moves every tab it owns.
Sessions can be dragged between windows the same way tabs can.

The compact session bar starts on the top edge. Move it with
`gtk-session-bar-location` (`top`, `bottom`, `left`, `right`). Left and right
bars stay narrow instead of stretching to the tab sidebar.

Each session has a color dot. Right-click a session to pick one of the eight
palette colors. Named snapshots keep that color.

Side bars show only the color and process icons unless you set
`gtk-session-sidebar-label` to `number` or `title`. Set
`gtk-session-sidebar-icon-layout = grid` to pack those icons into a grid.
`gtk-session-sidebar-tab-flow` is `top`, `center`, `bottom`, or `fill`. `fill`
gives every session the same height and keeps the new-session button at the
bottom.

Each session shows process icons from the tabs inside it, plus a number or the
active tab title on top and bottom bars. The bar appears automatically once
there is more than one session.

Sessions follow the selected tab's title, so the session bar and the
window title stay in sync with the current terminal.

The saved-session palette stores named snapshots of the current session. A
snapshot keeps its tabs, tab groups, splits, titles, focused panes, and working
directories. Restore creates a new session in the current window. Bind
`toggle_session_palette` to open the palette. There is no default shortcut.

Set `gtk-session-save-command = true` to save each pane's foreground command
on Linux. The restore screen preselects live foreground commands and lets you
edit or skip each one. Restore starts the configured shell, then sends the
saved command through that shell so its startup environment and shell
integration apply. Idle panes remain fresh shells. On other GTK platforms,
the original pane launch command is saved when available. Snapshots are stored in
`$XDG_STATE_HOME/holoctty/session-snapshots.json` (normally
`~/.local/state/holoctty/session-snapshots.json`).

### Tab groups

Tab groups are colored chips that cluster contiguous tabs inside one
session's vertical sidebar. They are only meaningful with
`gtk-tabs-location = left` or `right`, where the group header renders
above its members.

- Right-click a vertical tab and choose **Add Tab to New Group** to
  create a group around that tab.
- When other groups exist, right-click a tab and choose
  **Add to \<name\>** to put it in an existing group.
- **New Tab Group…** in the window menu, **New Tab Group** in the GTK
  command palette, or the `new_tab_group` action (default
  `ctrl+shift+g`) groups the current tab and opens the name dialog.
- The header chip label is the custom name, or the color name when the
  group is unnamed (`Grey`, `Blue`, `Red`, `Yellow`, `Green`, `Pink`,
  `Purple`, `Cyan`).
- Click the header title to collapse or expand the group. Collapsed
  members use compact cards that hide the meta and footer rows.
- The header **+** opens a new tab in that group.
- Right-click the header for **Name this group…**, **New Tab in
  Group**, the color swatches, **Ungroup**, and **Close group**.
- Drag the header to reorder groups, or drag it off the window to tear
  the whole group into a new window.
- Drag a tab onto a header to add it to that group. Inserting a tab
  between two members of the same group joins that group.
- Right-click a grouped tab and choose **Remove From Group**.
- Tab groups are not sessions. Closing a session still closes every
  tab it owns, including grouped ones.

To group the tabs in the active session, open the command palette with
`ctrl+shift+p` and choose **Auto-Group Tabs**, or bind `auto_group_tabs`.
The method is `gtk-tab-group-auto-method`: `local` or `ai`.

When the configured method is `ai`, the palette also lists **Group Tabs
Locally**. That runs local grouping once and leaves the config alone. The
entry is omitted when local is already the configured method. Bind the same
thing with `auto_group_tabs_local`.

The `local` method runs inside Holoctty. It compares tab titles and working
directories. Repository roots only decide which tabs are allowed to match.
On Linux it also compares foreground commands and SSH hosts from the process
detector. It does not run an agent, call a network service, or read terminal
contents.

A local group needs at least two tabs, and every member has to match every
other member. A chain of weak matches cannot pull a whole repository into one
group. Tabs without enough evidence stay ungrouped. Names come from the shared
subdirectory, title keywords, foreground command, SSH host, or repository
name, in that order.

If local grouping finds at least one group, it replaces the session's current
groups. Tabs left out of the result become ungrouped. If it finds nothing, it
leaves the existing groups alone.

The default `ai` method uses an agent or an OpenAI-compatible API. The
request has tab titles, tooltips, working directories, foreground process
names, and remote hosts. It never has terminal contents. The built-in prompt
treats a shared directory as weak context and favors task, process, and host
evidence, so one repository does not become a catch-all group.

### Process icons

Vertical tabs and the session bar share one process detector
(`src/apprt/gtk/cli_process.zig`). It walks the foreground process tree,
unwraps SSH (`holoctty +ssh`), versioned Python, `uv`, `pipx`, and
common npm / share install paths, and only treats a shell as idle when
it is not running a command.

Recognized processes include:

| Kind | Examples |
| --- | --- |
| Agents | Codex, Claude, Gemini, OpenCode (including `opencode2`), Grok, Cursor, Copilot, Amp, Pi, OMP, Devin, Aider, Goose, Crush, Cline, Droid, Kilo, Kimi, Qwen, Auggie, Hermes, Plandex, OpenHands, Continue, Amazon Q |
| TUIs | Neovim, Vim, Helix, Lazygit, GitUI, Tig, Lazydocker, Docker, btop, Kubernetes tools, Yazi, Ranger, Superfile, Glow |
| Shells | Bash, Zsh, Fish, Nushell, PowerShell |
| Remote | SSH and other remote clients |

Idle shells do not occupy session-bar slots. TUI and shell icons can be
hidden independently.

### Chrome that follows the terminal

`window-padding-color = extend-full` paints the session bar and vertical
tab sidebar with the live terminal background:

- A full-screen TUI fill (for example Grok, OSC 11, or a painted
  viewport) is copied onto the chrome
- Partial fills such as diff rows and large interior highlights are
  ignored so they do not tint the chrome or drop it back to the
  translucent config background
- Processes listed in `window-padding-extend-full-ignore` stay on the
  default surface background (useful for TUIs such as OMP that paint
  enough cells to look full-screen but do not look good on chrome)
- A default or transparent surface uses the same background color and
  `background-opacity` as the GL terminal
- Switching tabs or sessions updates chrome to the focused surface

This overrides `gtk-vertical-tab-opacity`. Separators and the wide
`GtkPaned` handle use the same chrome color so a translucent window does
not punch a bright line through the sidebar.

### Branding and packaging

Ghostty names are replaced in the Linux app, not in `libghostty`:

- Binary and resources: `holoctty`
- Desktop / D-Bus / Flatpak / Snap id: `com.sfire.holoctty`
- Config, state, and crash directories: `holoctty`
- App icon is the red ghost used in this repo

`holoctty +boo` is the upstream Ghostty easter egg, recolored to match
the icon.

### New configuration

All of these are GTK-only. Defaults match Ghostty's horizontal tabs
until you opt in.

| Key | Values | Default | What it does |
| --- | --- | --- | --- |
| `gtk-tabs-location` | `top`, `bottom`, `left`, `right` | `top` | `left` / `right` enable the vertical sidebar |
| `gtk-session-bar` | `auto`, `always`, `never` | `auto` | When the compact session bar is shown |
| `gtk-session-bar-location` | `top`, `bottom`, `left`, `right` | `top` | Edge that holds the compact session bar |
| `gtk-session-label` | `none`, `number`, `title` | `number` | Session label on top and bottom bars; the title stays on the tooltip |
| `gtk-session-sidebar-label` | `none`, `number`, `title` | `none` | Session label on left and right bars |
| `gtk-session-sidebar-tab-flow` | `top`, `center`, `bottom`, `fill` | `top` | Vertical placement of tabs in left and right session bars |
| `gtk-session-tui-icons` | `true`, `false` | `true` | Neovim, Lazygit, btop, and other TUI icons in the session bar |
| `gtk-session-shell-icons` | `true`, `false` | `true` | Idle-shell icons in the session bar |
| `gtk-session-sidebar-icon-layout` | `row`, `grid` | `row` | Process icon arrangement in side session bars |
| `gtk-session-sidebar-icon-grid-width` | `1`–`4` | `2` | Number of icon columns in a side session bar |
| `gtk-session-sidebar-icon-grid-height` | `1`–`8` | `2` | Number of icon rows in a side session bar |
| `gtk-session-save-command` | `true`, `false` | `false` | Store foreground pane commands for review and shell replay during restore |
| `gtk-tab-group-auto-method` | `ai`, `local` | `ai` | Method used by `auto_group_tabs` |
| `gtk-tab-group-local-max-groups` | `1`–`32` | `4` | Maximum groups created by the local method |
| `gtk-tab-group-ai-provider` | `off`, `agent`, `openai` | `off` | Backend used when the auto-group method is `ai` |
| `gtk-tab-group-ai-fallback-provider` | `off`, `agent`, `openai` | `off` | Backend tried after the primary fails, times out, or returns invalid output |
| `gtk-tab-group-ai-agent` | command | unset | Agent command; reads the prompt from stdin and writes JSON to stdout |
| `gtk-tab-group-ai-endpoint` | URL | OpenAI chat completions | OpenAI-compatible endpoint |
| `gtk-tab-group-ai-model` | model name | `gpt-4.1-mini` | Model sent to the API |
| `gtk-tab-group-ai-api-key-env` | environment variable | `OPENAI_API_KEY` | Environment variable holding the API key |
| `gtk-tab-group-ai-fallback-agent` | command | primary agent | Agent command used by the fallback |
| `gtk-tab-group-ai-fallback-endpoint` | URL | primary endpoint | OpenAI-compatible fallback endpoint |
| `gtk-tab-group-ai-fallback-model` | model name | primary model | Model sent to the fallback API |
| `gtk-tab-group-ai-fallback-api-key-env` | environment variable | primary key variable | Environment variable holding the fallback API key |
| `gtk-tab-group-ai-max-groups` | `1`–`32` | `8` | Maximum groups accepted from one response |
| `gtk-tab-group-ai-timeout` | `5`–`300` seconds | `30` | Agent or API request timeout |
| `gtk-tab-group-ai-instructions` | text | unset | Extra naming and grouping rules |
| `gtk-vertical-tab-opacity` | `0`–`1` | `0.08` | Sidebar background opacity; ignored with `extend-full` |
| `gtk-vertical-tab-title-lines` | `1`–`8` | `2` | Wrapped lines for the middle title row; paths stay on one line |
| `window-padding-color` | Ghostty values plus `extend-full` | `background` | `extend-full` extends the live TUI into GTK chrome |
| `window-padding-extend-full-ignore` | `[omp,codex]` or a name | unset | Skip chrome fill for those TUIs |

Example that matches the screenshot:

```
gtk-tabs-location = left
window-padding-color = extend-full
window-padding-extend-full-ignore = [omp,codex]
```

Local auto-grouping example:

```ini
gtk-tab-group-auto-method = local
gtk-tab-group-local-max-groups = 4
```

Run `auto_group_tabs` from the command palette, or bind it to a key.

Agent example:

```ini
gtk-tab-group-ai-provider = agent
gtk-tab-group-ai-agent = direct:codex exec --model gpt-5.6-luna --sandbox read-only --ephemeral -
gtk-tab-group-ai-fallback-provider = agent
gtk-tab-group-ai-fallback-agent = direct:omp -p --model google-antigravity/gemini-3.7-flash --no-session --no-tools --no-lsp --no-rules --no-skills --mode text --thinking low
gtk-tab-group-ai-instructions = Keep production and development servers separate
```

OpenAI-compatible API example:

```ini
gtk-tab-group-ai-provider = openai
gtk-tab-group-ai-model = gpt-4.1-mini
gtk-tab-group-ai-api-key-env = OPENAI_API_KEY
```

Set the named environment variable before starting Holoctty. The API key
does not appear in the config file or the child process command line. The
OpenAI-compatible provider uses `curl`; the agent provider has no `curl`
dependency.

### New actions and keybinds

| Action | Default | Notes |
| --- | --- | --- |
| `goto_session:N` | `ctrl+shift+1` … `ctrl+shift+9` | Selects session N; missing sessions are created up to N |
| `new_session` | none | Command palette **New Session**, or bind it |
| `close_session` | none | Closes the session and every tab it contains |
| `new_tab_group` | `ctrl+shift+g` | Groups the current tab and opens the name dialog |
| `auto_group_tabs` | none | Runs the selected local or AI auto-group method |
| `auto_group_tabs_local` | none | Always runs local deterministic auto-grouping |
| `toggle_session_palette` | none | Opens the separate palette for saving, updating, renaming, deleting, and restoring named sessions |

`new_session`, `close_session`, `auto_group_tabs`, and sessions 1–9 are
also in the GTK command palette. Choose **Saved Sessions** there to open the
saved-session palette. **Group Tabs Locally** is also present unless local is
the configured auto-group method. **New Tab Group** is in the command palette
and the window menu. To run auto-grouping directly on the palette chord, set
`keybind = ctrl+shift+p=auto_group_tabs`; this replaces the default
command-palette binding.

For example, bind the saved-session palette without changing the main command
palette:

```ini
keybind = ctrl+shift+s=toggle_session_palette
```

## Build and install

Holoctty is built from this tree. There is no separate download channel
from Ghostty's.

Requires [Zig](https://ziglang.org) **0.16.0** (see
`minimum_zig_version` in `build.zig.zon`). Linux builds also need GTK4,
libadwaita, and, from a Git checkout, `blueprint-compiler` 0.16.0 or
newer. See [HACKING.md](HACKING.md) for the full developer setup.

User install to `~/.local`:

```sh
./install.sh
```

System install to `/usr` (stages as you, copies with `sudo`):

```sh
./install.sh --system
```

`install.sh` builds `-Doptimize=ReleaseFast`, installs the binary,
desktop file, icons, terminfo, and shell integration, then refreshes
the desktop and icon caches. Extra `zig build` flags go after `--`:

```sh
./install.sh -- -Dgtk-x11=false
```

Or build by hand:

```sh
zig build -Doptimize=ReleaseFast
# binary: zig-out/bin/holoctty
```

## Configuration

Create `~/.config/holoctty/config.holoctty`. Most keys are the same as
Ghostty's (`font-family`, `theme`, `keybind`, `background-opacity`,
…). Fork-only keys are listed above.

Reload with the same action as Ghostty (`reload_config`; default
`ctrl+shift+,` on Linux).

## Documentation

- Shared terminal behavior, config reference, and install notes:
  [ghostty.org/docs](https://ghostty.org/docs)
- Building and hacking this tree: [HACKING.md](HACKING.md)
- Packaging: [PACKAGING.md](PACKAGING.md)

Treat Ghostty docs as the source of truth for the emulator. If a GTK
UI detail disagrees with this README, this README wins.

## Contributing and developing

This is a personal Ghostty fork. Do not open Holoctty pull requests
against [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty),
and do not expect Ghostty maintainers to take these GTK chrome changes
as-is.

If you are working in this tree, read [HACKING.md](HACKING.md) and
[UPSTREAM.md](UPSTREAM.md). Linux GUI checks should use isolated virtual
KWin (`virt-shot`), not a window on the live desktop.

Upstream Ghostty still has its own contributing process, AI policy, and
vouch system. Those apply to Ghostty, not automatically to this fork.

## Crash reports

Holoctty keeps Ghostty's built-in crash reporter. Reports are written
to `$XDG_STATE_HOME/holoctty/crash` (default `~/.local/state/holoctty/crash`)
the next time the app starts after a crash. They are **not** sent
anywhere unless you upload them.

```sh
holoctty +crash-report
```

Reports use the [Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/)
and can contain stack memory, so treat them as sensitive.

## License

MIT. Holoctty is a fork of Ghostty. Original authorship and copyright
remain with Mitchell Hashimoto and the Ghostty contributors; see
[LICENSE](LICENSE).
