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

1. Read the CSS for the surface you are changing (`src/apprt/gtk/css/style.css`). Match existing `min-height`, padding, and margin. Do not invent a taller layout.
2. Copy a sibling GObject class (`vertical_tab.zig`, `session.zig`) — do not author a new class shape from memory.
3. Prefer a thin change in the existing widget. Do not replace `Adw.TabBar`/`Adw.TabView` or extract a module until that thin change is proven insufficient.

## Zig GObject classes

- Struct fields use **commas**, including `parent_instance` and `parent_class`.
- `Adw.TabPage.getTitle()` is `[*:0]const u8` (not optional). `getTooltip()` is optional.
- Writers: `var w: std.Io.Writer = .fixed(&buf);` then `w.buffered()`.
- New Blueprint: add it to `src/apprt/gtk/build/gresource.zig` `blueprints`, `gobject.ext.ensureType` before `setTemplateFromResource`, bind names that match the `.blp`.
- GTK CSS has **no** `overflow` or `max-height`. Use widget properties (`overflow: hidden` in Blueprint) and `min-height`.
- Runtime CSS in `application.zig` already tints `.session-bar-background` / `.vertical-tabs`. Do not add a second background unless you mean to override that.

## Sessions and chrome

- Session bar is a **~20px** strip. Process indicators are a **single centered row** with the session number, truncated with `+N`.
- Bar is visible only when `session_view.n-pages > 1`.
- Active session pages live in the window `tab_view`. Inactive pages live in `Session.getTabView()`. Read pages via `Session.getPagesTabView()`.
- `page-attached` runs **before** `page.setTitle()`. Bind the label to `Adw.TabPage.title` so the number paints immediately. Scan `/proc` on idle, not in `init`.
- Process icons: reuse `src/apprt/gtk/cli_process.zig`. Do not copy the mapping tables.

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
