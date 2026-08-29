---
name: gtk-ui
description: >
  Fast path for holocTTY GTK (Linux/FreeBSD) UI work: session bar, vertical
  tabs, Blueprint, GObject Zig classes, process icons, compact chrome.
  Use when changing src/apprt/gtk, .blp/.css, Adw/Gtk widgets, session tabs,
  or when the user runs /gtk-ui.
---

# GTK UI (holocTTY)

GUI verify is **virt-gui-verify** (see `AGENTS.md`). Do not launch on the live desktop.

## Before editing

1. Read [UPSTREAM.md](../../../UPSTREAM.md). Do not sed `Ghostty` → `Holoctty` in comments, help text, or upstream GObject type names.
2. Read the CSS for the surface you are changing (`src/apprt/gtk/css/style.css`). Match existing `min-height`, padding, and margin. Do not invent a taller layout.
3. Copy a sibling GObject class (`vertical_tab.zig`, `session.zig`) — do not author a new class shape from memory.
4. Prefer a thin change in the existing widget. Do not replace `Adw.TabBar`/`Adw.TabView` or extract a module until that thin change is proven insufficient.

Upstream widgets keep `Ghostty*` GObject names (`GhosttyWindow`, `$GhosttyTab`).
Fork-only widgets keep `Holoctty*` (`HolocttySession`, `HolocttyVerticalTab`).

## Zig GObject classes

- Struct fields use **commas**, including `parent_instance` and `parent_class`.
- `Adw.TabPage.getTitle()` is `[*:0]const u8` (not optional). `getTooltip()` is optional.
- Writers: `var w: std.Io.Writer = .fixed(&buf);` then `w.buffered()`.
- New Blueprint: add it to `src/apprt/gtk/build/gresource.zig` `blueprints`, `gobject.ext.ensureType` before `setTemplateFromResource`, bind names that match the `.blp`.
- GTK CSS has **no** `overflow` or `max-height`. Use widget properties (`overflow: hidden` in Blueprint) and `min-height`.
- Runtime CSS in `application.zig` already tints `.session-bar-background` / `.vertical-tabs`. Do not add a second background unless you mean to override that.

## Sessions and chrome

- Top and bottom session bars are a **~20px** strip. Process icons sit in one centered row, truncated with `+N`.
- Left and right bars are a narrow column. Default label is `none` (`gtk-session-sidebar-label`). Icons are one column unless `gtk-session-sidebar-icon-layout = grid`. `Window.syncSessionBarLocation()` moves the one bar widget between template slots.
- Visibility is `gtk-session-bar`: `auto` shows when `session_view.n-pages > 1`, plus `always` / `never`. Edge is `gtk-session-bar-location`.
- Session color is `Session.color` (same eight palette colors as tab groups). The session-tab context menu sets it. Snapshots store it.
- Active session pages live in the window `tab_view`. Inactive pages live in `Session.getTabView()`. Read pages via `Session.getPagesTabView()`.
- `page-attached` runs **before** `page.setTitle()`. Bind the label to `Adw.TabPage.title` so the number paints immediately. Scan `/proc` on idle, not in `init`.
- Process icons: reuse `src/apprt/gtk/cli_process.zig`. Do not copy the mapping tables. The idle fallback is `holoctty-cli-terminal-symbolic` (`icons/terminal.svg`).

### Tab groups

- Fork-only types: `HolocttyTabGroup` (`tab_group.zig`) and `HolocttyTabGroupHeader` (`tab_group_header.zig`).
- Shared plan type is `tab_group_plan.zig`. Local clustering is `tab_group_local.zig`. AI is `tab_group_ai.zig`.
- `win.tab-groups-auto` follows `gtk-tab-group-auto-method`. `win.tab-groups-auto-local` always runs local.
- Pages bind to a group through the qdata key `holoctty-tab-group` in `tab_group.zig`.
- Headers live in `vertical_tab_bar.zig`; clicking a header collapses/expands the group and does not rename it.
- Rename is only reachable from the header context menu, the `win.tab-group-rename` window action, or `new_tab_group` (which still opens the name dialog for a new group).
- After membership or collapse changes, call `Window.syncTabGroups()`.

### Folder icons

- Store is `folder_icons.zig` (`$XDG_STATE_HOME/holoctty/folder-icons.json`). Picker is `folder_icon_picker.zig`.
- Closest ancestor path wins. Remotes are keyed by SSH/Mosh host.
- Vertical-tab menu: **Set Folder Icon…** or **Set Remote Icon…**. Do not invent a second store.

## Gtk.Box + label + icon

A horizontal `Gtk.Box` baseline-aligns `Gtk.Label` to `Gtk.Image` and sits the icon low. Set `valign: center` on both. Do not rely on baseline.

## Build

```sh
zig build -Demit-macos-app=false
zig build test -Dtest-filter=<name>
zig fmt src/apprt/gtk
```

Batch CSS + Blueprint + Zig, then **one** compile. Full `zig build test` is slow.

Debug GTK app id is `com.sfire.holoctty-debug`; action object path `/com/sfire/holoctty_debug` (release is `com.sfire.holoctty` / `/com/sfire/holoctty`). Isolated verify still uses virt-gui-verify, not a host window.
