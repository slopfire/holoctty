# Holoctty GTK UI lab

The UI lab is a developer-only native workbench for polishing tabs, tab groups,
sessions, and their shared chrome without starting a terminal process. It uses
the production GObject classes, Blueprint resources, and GTK CSS.

## Commands

```sh
zig build ui-lab
zig build ui-lab-run
zig build ui-lab-shot
```

`ui-lab` builds `zig-out/bin/holoctty-ui-lab`. `ui-lab-shot` launches it in an
isolated virtual KWin session and writes `/tmp/virt-shot.jpg`; it never opens a
window on the live desktop.

## Agent workflow

Only use this workflow when the user explicitly asks you to use, run, or modify
the UI lab. Do not route ordinary GTK work through the lab automatically.

1. Select the closest built-in fixture: `Few`, `Many`, or `Groups`.
2. Add a deterministic fixture state for any missing edge case before changing
   component styling or production window composition.
3. Exercise the relevant state at normal and narrow widths. Check selection,
   overflow, long titles, group boundaries, and session count as applicable.
4. Iterate on the real component or production CSS and capture the lab with
   `zig build ui-lab-shot`.
5. Inspect `/tmp/virt-shot.jpg`. Reject captures with the wrong preset, focus,
   dimensions, or theme.
6. Integrate the proven composition into the application, then run the focused
   Zig tests, normal GTK build, and a separate isolated real-app check.

The lab intentionally mocks terminal contents. Behavior involving PTYs,
surfaces, process icons, page transfer, or tear-off windows still requires a
focused real-application verification after the visual idea is accepted.
