//! Native GTK workbench for iterating on Holoctty chrome.
//!
//! This uses production widget classes and CSS with lightweight fixture data.
//! It must never create terminal surfaces or launch child processes.

const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_info = @import("../build/info.zig");
const global = @import("../../../global.zig");
const Session = @import("../class/session.zig").Session;
const SessionTabBar = @import("../class/session_tab_bar.zig").SessionTabBar;
const TabGroup = @import("../class/tab_group.zig").TabGroup;
const VerticalTabBar = @import("../class/vertical_tab_bar.zig").VerticalTabBar;

const State = struct {
    window: *adw.ApplicationWindow,
    tab_view: *adw.TabView,
    session_view: *adw.TabView,
    vertical_tabs: *VerticalTabBar,
    next_tab: usize = 1,
    next_session: usize = 1,

    fn clearView(view: *adw.TabView) void {
        while (view.getNPages() > 0) {
            view.closePage(view.getNthPage(view.getNPages() - 1));
        }
    }

    fn reset(self: *State) void {
        clearView(self.tab_view);
        clearView(self.session_view);
        self.next_tab = 1;
        self.next_session = 1;
    }

    fn addTab(self: *State, title: [:0]const u8, path: [:0]const u8) *adw.TabPage {
        const content = fixtureContent(title, "Terminal content is intentionally mocked");
        const page = self.tab_view.append(content.as(gtk.Widget));
        page.setTitle(title);
        page.setTooltip(path);
        self.next_tab += 1;
        return page;
    }

    fn addGeneratedTab(self: *State) *adw.TabPage {
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &title_buf,
            "Terminal {d}",
            .{self.next_tab},
        ) catch "Terminal";
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(
            &path_buf,
            "/home/sfire/Projects/slopfire/holoctty/worktree-{d}",
            .{self.next_tab},
        ) catch "/home/sfire/Projects/slopfire/holoctty";
        return self.addTab(title, path);
    }

    fn addSession(self: *State, tab_count: usize) *adw.TabPage {
        const session = Session.new();
        const inner_view = session.getTabView();
        var i: usize = 0;
        while (i < tab_count) : (i += 1) {
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "Session {d} · Tab {d}",
                .{ self.next_session, i + 1 },
            ) catch "Terminal";
            const child = fixtureContent(title, "Session fixture");
            const inner_page = inner_view.append(child.as(gtk.Widget));
            inner_page.setTitle(title);
        }

        const outer_page = self.session_view.append(session.as(gtk.Widget));
        var session_buf: [32]u8 = undefined;
        const session_title = std.fmt.bufPrintZ(
            &session_buf,
            "{d}",
            .{self.next_session},
        ) catch "Session";
        outer_page.setTitle(session_title);
        self.next_session += 1;
        return outer_page;
    }

    fn showFew(self: *State) void {
        self.reset();
        _ = self.addTab("Codex", "/home/sfire/Projects/slopfire/holoctty");
        _ = self.addTab("Editor", "/home/sfire/Projects/slopfire/holoctty/src/apprt/gtk");
        _ = self.addTab("Tests", "/home/sfire/Projects/slopfire/holoctty/zig-out");
        _ = self.addSession(3);
        _ = self.addSession(2);
        self.tab_view.setSelectedPage(self.tab_view.getNthPage(0));
        self.session_view.setSelectedPage(self.session_view.getNthPage(0));
        self.vertical_tabs.syncNow();
    }

    fn showMany(self: *State) void {
        self.reset();
        var i: usize = 0;
        while (i < 14) : (i += 1) {
            const page = self.addGeneratedTab();
            if (i == 9) page.setNeedsAttention(1);
        }
        i = 0;
        while (i < 6) : (i += 1) _ = self.addSession((i % 4) + 1);
        self.tab_view.setSelectedPage(self.tab_view.getNthPage(6));
        self.session_view.setSelectedPage(self.session_view.getNthPage(2));
        self.vertical_tabs.syncNow();
    }

    fn showGroups(self: *State) void {
        self.reset();
        var pages: [9]*adw.TabPage = undefined;
        for (&pages) |*page| page.* = self.addGeneratedTab();
        const agents = TabGroup.new();
        defer agents.unref();
        agents.setName("Agents");
        agents.setColor(.blue);
        for (pages[0..3]) |page| TabGroup.bindPage(page, agents);

        const review = TabGroup.new();
        defer review.unref();
        review.setName("Review and tests");
        review.setColor(.purple);
        for (pages[4..8]) |page| TabGroup.bindPage(page, review);

        _ = self.addSession(4);
        _ = self.addSession(3);
        _ = self.addSession(1);
        self.tab_view.setSelectedPage(pages[1]);
        self.session_view.setSelectedPage(self.session_view.getNthPage(1));
        self.vertical_tabs.syncNow();
        // Exercise the same post-render collapse notification as a header click.
        review.setCollapsed(true);
    }

    fn presetFew(_: *gtk.Button, self: *State) callconv(.c) void {
        self.showFew();
    }

    fn presetMany(_: *gtk.Button, self: *State) callconv(.c) void {
        self.showMany();
    }

    fn presetGroups(_: *gtk.Button, self: *State) callconv(.c) void {
        self.showGroups();
    }

    fn addTabClicked(_: *gtk.Button, self: *State) callconv(.c) void {
        const page = self.addGeneratedTab();
        self.tab_view.setSelectedPage(page);
        self.vertical_tabs.syncNow();
    }

    fn addSessionClicked(_: *gtk.Button, self: *State) callconv(.c) void {
        const page = self.addSession(2);
        self.session_view.setSelectedPage(page);
    }

    fn narrowToggled(button: *gtk.ToggleButton, self: *State) callconv(.c) void {
        const width: c_int = if (button.getActive() != 0) 720 else 1120;
        self.window.as(gtk.Window).setDefaultSize(width, 720);
    }
};

var lab_state: ?*State = null;

pub fn main(minimal: std.process.Init.Minimal) !void {
    try global.init(.{ .main = minimal });
    defer global.deinit();

    const app = adw.Application.new(
        "com.sfire.holoctty.UiLab",
        .{ .non_unique = true },
    );
    defer app.unref();
    app.as(gio.Application).setResourceBasePath(build_info.resource_path);
    _ = gio.Application.signals.activate.connect(
        app,
        *adw.Application,
        activate,
        app,
        .{},
    );
    const status = app.as(gio.Application).run(0, null);
    if (status != 0) std.process.exit(@intCast(status));
}

fn activate(app: *adw.Application, _: *adw.Application) callconv(.c) void {
    if (lab_state) |state| {
        state.window.as(gtk.Window).present();
        return;
    }

    loadCss();

    const window = adw.ApplicationWindow.new(app.as(gtk.Application));
    window.as(gtk.Window).setTitle("Holoctty UI Lab");
    window.as(gtk.Window).setDefaultSize(1120, 720);
    window.as(gtk.Widget).addCssClass("window");
    window.as(gtk.Widget).addCssClass("ui-lab-window");

    const root = gtk.Box.new(.vertical, 0);
    root.as(gtk.Widget).addCssClass("ui-lab-root");

    const title = gtk.Label.new("Holoctty UI Lab");
    title.as(gtk.Widget).addCssClass("title-1");
    title.as(gtk.Widget).addCssClass("ui-lab-title");
    title.setXalign(0);
    root.append(title.as(gtk.Widget));

    const controls = gtk.Box.new(.horizontal, 6);
    controls.as(gtk.Widget).addCssClass("ui-lab-controls");
    root.append(controls.as(gtk.Widget));

    const tab_view = adw.TabView.new();
    const session_view = adw.TabView.new();
    const vertical_tabs = gobject.ext.newInstance(VerticalTabBar, .{
        .view = tab_view,
    });
    const session_bar = gobject.ext.newInstance(SessionTabBar, .{
        .view = session_view,
    });

    const state = std.heap.c_allocator.create(State) catch return;
    state.* = .{
        .window = window,
        .tab_view = tab_view,
        .session_view = session_view,
        .vertical_tabs = vertical_tabs,
    };
    lab_state = state;

    appendButton(controls, "Few", State.presetFew, state);
    appendButton(controls, "Many", State.presetMany, state);
    appendButton(controls, "Groups", State.presetGroups, state);
    appendButton(controls, "+ Tab", State.addTabClicked, state);
    appendButton(controls, "+ Session", State.addSessionClicked, state);
    const narrow = gtk.ToggleButton.newWithLabel("Narrow window");
    _ = gtk.ToggleButton.signals.toggled.connect(
        narrow,
        *State,
        State.narrowToggled,
        state,
        .{},
    );
    controls.append(narrow.as(gtk.Widget));

    root.append(sectionTitle("Sessions"));
    const session_shell = gtk.Box.new(.horizontal, 2);
    session_shell.as(gtk.Widget).addCssClass("session-bar-background");
    session_shell.as(gtk.Widget).addCssClass("ui-lab-session-shell");
    session_bar.as(gtk.Widget).setHexpand(1);
    session_shell.append(session_bar.as(gtk.Widget));
    root.append(session_shell.as(gtk.Widget));

    root.append(sectionTitle("Horizontal and vertical tabs"));
    const horizontal_tabs = adw.TabBar.new();
    horizontal_tabs.setView(tab_view);
    horizontal_tabs.setAutohide(0);
    horizontal_tabs.setExpandTabs(0);
    root.append(horizontal_tabs.as(gtk.Widget));

    const paned = gtk.Paned.new(.horizontal);
    paned.as(gtk.Widget).setVexpand(1);
    paned.as(gtk.Widget).addCssClass("ui-lab-paned");
    vertical_tabs.as(gtk.Widget).setSizeRequest(280, -1);
    paned.setStartChild(vertical_tabs.as(gtk.Widget));
    paned.setEndChild(tab_view.as(gtk.Widget));
    paned.setPosition(280);
    paned.setResizeStartChild(0);
    paned.setShrinkStartChild(0);
    root.append(paned.as(gtk.Widget));

    window.setContent(root.as(gtk.Widget));
    state.showGroups();
    window.as(gtk.Window).present();
}

fn appendButton(
    box: *gtk.Box,
    label: [:0]const u8,
    callback: *const fn (*gtk.Button, *State) callconv(.c) void,
    state: *State,
) void {
    const button = gtk.Button.newWithLabel(label);
    _ = gtk.Button.signals.clicked.connect(
        button,
        *State,
        callback,
        state,
        .{},
    );
    box.append(button.as(gtk.Widget));
}

fn sectionTitle(text: [:0]const u8) *gtk.Widget {
    const label = gtk.Label.new(text);
    label.setXalign(0);
    label.as(gtk.Widget).addCssClass("heading");
    label.as(gtk.Widget).addCssClass("ui-lab-section-title");
    return label.as(gtk.Widget);
}

fn fixtureContent(title: [:0]const u8, subtitle: [:0]const u8) *gtk.Box {
    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).setHexpand(1);
    box.as(gtk.Widget).setVexpand(1);
    box.as(gtk.Widget).setHalign(.fill);
    box.as(gtk.Widget).setValign(.fill);
    box.as(gtk.Widget).addCssClass("ui-lab-fixture");

    const heading = gtk.Label.new(title);
    heading.as(gtk.Widget).addCssClass("title-1");
    const detail = gtk.Label.new(subtitle);
    detail.as(gtk.Widget).addCssClass("dim-label");
    box.append(heading.as(gtk.Widget));
    box.append(detail.as(gtk.Widget));
    return box;
}

fn loadCss() void {
    const display = gdk.Display.getDefault() orelse return;

    const production = gtk.CssProvider.new();
    production.loadFromResource(build_info.resource_path ++ "/style.css");
    gtk.StyleContext.addProviderForDisplay(
        display,
        production.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    production.unref();

    const lab = gtk.CssProvider.new();
    lab.loadFromData(
        \\.ui-lab-root { background-color: @window_bg_color; }
        \\.ui-lab-title { margin: 12px 14px 4px; }
        \\.ui-lab-controls { padding: 6px 12px 10px; }
        \\.ui-lab-section-title { margin: 8px 12px 4px; }
        \\.ui-lab-session-shell { margin: 0 12px 6px; min-height: 24px; }
        \\.ui-lab-paned { margin-top: 1px; }
        \\.ui-lab-fixture { padding: 48px; background-color: @view_bg_color; }
    , -1);
    gtk.StyleContext.addProviderForDisplay(
        display,
        lab.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    lab.unref();
}
