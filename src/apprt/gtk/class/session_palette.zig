const std = @import("std");

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const internal_os = @import("../../../os/main.zig");
const i18n = internal_os.i18n;
const session_snapshot = @import("../session_snapshot.zig");
const gresource = @import("../build/gresource.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_holoctty_session_palette);

pub const SessionPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttySessionPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const ReviewRow = struct {
        tab: u32,
        node: u32,
        check: *gtk.CheckButton,
        entry: *gtk.Entry,
        original: *const session_snapshot.LaunchCommand,
        display: []u8,
    };

    const Private = struct {
        window: WeakRef(Window) = .empty,
        loaded: ?session_snapshot.Loaded = null,
        review_rows: std.ArrayList(ReviewRow) = .empty,
        review_name: ?[:0]u8 = null,

        dialog: *adw.Dialog,
        stack: *gtk.Stack,
        library_page: *gtk.Box,
        review_page: *gtk.Box,
        search: *gtk.SearchEntry,
        save_button: *gtk.Button,
        snapshot_list: *gtk.Box,
        review_title: *gtk.Label,
        review_list: *gtk.Box,
        restore_button: *gtk.Button,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.clearReview();
        if (priv.loaded) |*loaded| {
            loaded.deinit();
            priv.loaded = null;
        }
        priv.window.deinit();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn toggle(self: *Self, window: *Window) void {
        const priv = self.private();
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            _ = priv.dialog.close();
            return;
        }

        priv.window.set(window);
        priv.stack.setVisibleChild(priv.library_page.as(gtk.Widget));
        self.refreshLibrary() catch |err| {
            log.warn("unable to load session snapshots err={}", .{err});
            window.showToast(i18n._("Could not load saved sessions"));
        };
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.close();
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.populateLibrary();
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();
        const session = window.getActiveSession() orelse return;
        if (session.getSnapshotName()) |name| {
            self.saveCurrent(name) catch |err| self.saveFailed(err);
            return;
        }
        self.promptName(.save, null);
    }

    fn saveAsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.promptName(.save, null);
    }

    const PromptKind = enum { save, rename };

    fn promptName(self: *Self, kind: PromptKind, initial: ?[]const u8) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();
        const dialog = adw.AlertDialog.new(
            if (kind == .save) i18n._("Save Session") else i18n._("Rename Saved Session"),
            if (kind == .save)
                i18n._("Saving again with the same name replaces that snapshot.")
            else
                null,
        );
        dialog.addResponse("cancel", i18n._("Cancel"));
        dialog.addResponse("ok", if (kind == .save) i18n._("Save") else i18n._("Rename"));
        dialog.setResponseAppearance("ok", .suggested);
        dialog.setDefaultResponse("ok");
        const entry = gtk.Entry.new();
        entry.setActivatesDefault(1);
        if (initial) |value| {
            const value_z = glib.ext.dupeZ(u8, value);
            defer glib.free(@ptrCast(@constCast(value_z.ptr)));
            entry.getBuffer().setText(value_z, -1);
        }
        dialog.setExtraChild(entry.as(gtk.Widget));
        dialog.as(adw.Dialog).setFocus(entry.as(gtk.Widget));
        dialog.as(gobject.Object).setData("holoctty-session-name-entry", entry);
        dialog.as(gobject.Object).setData(
            "holoctty-session-prompt-kind",
            @ptrFromInt(@as(usize, @intFromEnum(kind)) + 1),
        );
        if (initial) |value| setObjectName(dialog.as(gobject.Object), "holoctty-session-old-name", value);
        _ = self.ref();
        dialog.choose(window.as(gtk.Widget), null, promptNameReady, self);
    }

    fn promptNameReady(
        object: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const dialog: *adw.AlertDialog = @ptrCast(@alignCast(object orelse return));
        if (std.mem.orderZ(u8, "ok", dialog.chooseFinish(result)) != .eq) return;
        const entry_ptr = dialog.as(gobject.Object).getData("holoctty-session-name-entry") orelse return;
        const entry: *gtk.Entry = @ptrCast(@alignCast(entry_ptr));
        const name = std.mem.trim(
            u8,
            std.mem.span(entry.getBuffer().getText()),
            " \t\r\n",
        );
        if (name.len == 0) return;
        const raw_kind = @intFromPtr(dialog.as(gobject.Object).getData(
            "holoctty-session-prompt-kind",
        ) orelse return);
        const kind: PromptKind = @enumFromInt(raw_kind - 1);
        switch (kind) {
            .save => self.saveCurrent(name) catch |err| self.saveFailed(err),
            .rename => {
                const old = objectName(dialog.as(gobject.Object), "holoctty-session-old-name") orelse return;
                self.renameSnapshot(old, name) catch |err| self.saveFailed(err);
            },
        }
    }

    fn saveCurrent(self: *Self, name: []const u8) !void {
        const window = self.private().window.get() orelse return error.NoWindow;
        defer window.unref();
        const alloc = ApplicationAllocator.get();
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const snapshot = try window.captureActiveSession(arena.allocator(), name);
        const path = try session_snapshot.defaultPath(alloc);
        defer alloc.free(path);
        try session_snapshot.upsert(global.io(), alloc, path, snapshot);
        window.associateActiveSessionSnapshot(name);
        window.showToast(i18n._("Session saved"));
        try self.refreshLibrary();
    }

    fn saveFailed(self: *Self, err: anyerror) void {
        log.warn("saved session operation failed err={}", .{err});
        const window = self.private().window.get() orelse return;
        defer window.unref();
        window.showToast(i18n._("Could not save the session"));
    }

    fn refreshLibrary(self: *Self) !void {
        const priv = self.private();
        if (priv.loaded) |*loaded| loaded.deinit();
        priv.loaded = null;
        const alloc = ApplicationAllocator.get();
        const path = try session_snapshot.defaultPath(alloc);
        defer alloc.free(path);
        priv.loaded = try session_snapshot.load(global.io(), alloc, path);

        const window = priv.window.get();
        if (window) |value| {
            defer value.unref();
            const associated = if (value.getActiveSession()) |session|
                session.getSnapshotName() != null
            else
                false;
            priv.save_button.setLabel(if (associated) i18n._("Update") else i18n._("Save"));
        }
        self.populateLibrary();
    }

    fn populateLibrary(self: *Self) void {
        const priv = self.private();
        clearBox(priv.snapshot_list);
        const loaded = if (priv.loaded) |*value| value else return;
        const query = std.mem.span(priv.search.as(gtk.Editable).getText());

        for (loaded.value.snapshots) |snapshot| {
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(snapshot.name, query) == null) continue;
            self.appendSnapshotRow(snapshot.name);
        }
        if (loaded.value.snapshots.len == 0) {
            const empty = gtk.Label.new(i18n._("No saved sessions yet"));
            empty.as(gtk.Widget).setMarginTop(48);
            empty.as(gtk.Widget).addCssClass("dim-label");
            priv.snapshot_list.append(empty.as(gtk.Widget));
        }
    }

    fn appendSnapshotRow(self: *Self, name: []const u8) void {
        const row = gtk.Box.new(.horizontal, 6);
        row.as(gtk.Widget).addCssClass("card");
        row.as(gtk.Widget).setMarginBottom(4);

        const name_z = glib.ext.dupeZ(u8, name);
        defer glib.free(@ptrCast(@constCast(name_z.ptr)));
        const open = gtk.Button.newWithLabel(name_z);
        open.as(gtk.Widget).setHexpand(1);
        open.as(gtk.Widget).setHalign(.fill);
        open.as(gtk.Widget).addCssClass("flat");
        setObjectName(open.as(gobject.Object), "holoctty-session-name", name);
        _ = gtk.Button.signals.clicked.connect(open, *Self, snapshotActivated, self, .{});
        row.append(open.as(gtk.Widget));

        const rename_button = gtk.Button.newFromIconName("document-edit-symbolic");
        rename_button.as(gtk.Widget).setTooltipText(i18n._("Rename"));
        rename_button.as(gtk.Widget).addCssClass("flat");
        setObjectName(rename_button.as(gobject.Object), "holoctty-session-name", name);
        _ = gtk.Button.signals.clicked.connect(rename_button, *Self, renameClicked, self, .{});
        row.append(rename_button.as(gtk.Widget));

        const delete_button = gtk.Button.newFromIconName("user-trash-symbolic");
        delete_button.as(gtk.Widget).setTooltipText(i18n._("Delete"));
        delete_button.as(gtk.Widget).addCssClass("flat");
        setObjectName(delete_button.as(gobject.Object), "holoctty-session-name", name);
        _ = gtk.Button.signals.clicked.connect(delete_button, *Self, deleteClicked, self, .{});
        row.append(delete_button.as(gtk.Widget));
        self.private().snapshot_list.append(row.as(gtk.Widget));
    }

    fn snapshotActivated(button: *gtk.Button, self: *Self) callconv(.c) void {
        const name = objectName(button.as(gobject.Object), "holoctty-session-name") orelse return;
        self.showReview(name) catch |err| self.saveFailed(err);
    }

    fn renameClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const name = objectName(button.as(gobject.Object), "holoctty-session-name") orelse return;
        self.promptName(.rename, name);
    }

    fn renameSnapshot(self: *Self, old_name: []const u8, new_name: []const u8) !void {
        const alloc = ApplicationAllocator.get();
        const path = try session_snapshot.defaultPath(alloc);
        defer alloc.free(path);
        if (!try session_snapshot.rename(global.io(), alloc, path, old_name, new_name)) return;
        const window = self.private().window.get();
        if (window) |value| {
            defer value.unref();
            value.renameSnapshotAssociation(old_name, new_name);
        }
        try self.refreshLibrary();
    }

    fn deleteClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const name = objectName(button.as(gobject.Object), "holoctty-session-name") orelse return;
        const window = self.private().window.get() orelse return;
        defer window.unref();
        const dialog = adw.AlertDialog.new(i18n._("Delete Saved Session?"), null);
        dialog.addResponse("cancel", i18n._("Cancel"));
        dialog.addResponse("delete", i18n._("Delete"));
        dialog.setResponseAppearance("delete", .destructive);
        setObjectName(dialog.as(gobject.Object), "holoctty-session-name", name);
        _ = self.ref();
        dialog.choose(window.as(gtk.Widget), null, deleteReady, self);
    }

    fn deleteReady(object: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const dialog: *adw.AlertDialog = @ptrCast(@alignCast(object orelse return));
        if (std.mem.orderZ(u8, "delete", dialog.chooseFinish(result)) != .eq) return;
        const name = objectName(dialog.as(gobject.Object), "holoctty-session-name") orelse return;
        const alloc = ApplicationAllocator.get();
        const path = session_snapshot.defaultPath(alloc) catch return;
        defer alloc.free(path);
        if (session_snapshot.delete(global.io(), alloc, path, name)) |deleted| {
            if (!deleted) return;
            const window = self.private().window.get();
            if (window) |value| {
                defer value.unref();
                value.clearSnapshotAssociation(name);
            }
            self.refreshLibrary() catch {};
        } else |err| self.saveFailed(err);
    }

    fn showReview(self: *Self, name: []const u8) !void {
        const priv = self.private();
        self.clearReview();
        const loaded = if (priv.loaded) |*value| value else return error.NotLoaded;
        const snapshot = session_snapshot.find(loaded.value, name) orelse return error.NotFound;
        priv.review_name = try ApplicationAllocator.get().dupeZ(u8, name);
        priv.review_title.setLabel(priv.review_name.?);

        for (snapshot.tabs, 0..) |tab, tab_index| {
            for (tab.tree.nodes, 0..) |node, node_index| switch (node) {
                .split => {},
                .pane => |pane| {
                    const row = gtk.Box.new(.vertical, 4);
                    row.as(gtk.Widget).addCssClass("card");
                    row.as(gtk.Widget).setMarginBottom(4);
                    const cwd = pane.working_directory orelse "~";
                    const header_text = try std.fmt.allocPrint(
                        ApplicationAllocator.get(),
                        "Tab {d}, pane {d}  ·  {s}",
                        .{ tab_index + 1, node_index + 1, cwd },
                    );
                    defer ApplicationAllocator.get().free(header_text);
                    const header_z = try ApplicationAllocator.get().dupeZ(u8, header_text);
                    defer ApplicationAllocator.get().free(header_z);
                    const header = gtk.Label.new(header_z);
                    header.as(gtk.Widget).setHalign(.start);
                    header.as(gtk.Widget).addCssClass("dim-label");
                    row.append(header.as(gtk.Widget));

                    if (pane.launch_command) |*command| {
                        const command_row = gtk.Box.new(.horizontal, 8);
                        const check = gtk.CheckButton.new();
                        check.setActive(@intFromBool(command.* == .foreground));
                        command_row.append(check.as(gtk.Widget));
                        const display = try formatCommand(ApplicationAllocator.get(), command.*);
                        const display_z = try ApplicationAllocator.get().dupeZ(u8, display);
                        const entry = gtk.Entry.new();
                        entry.as(gtk.Widget).setHexpand(1);
                        entry.as(gtk.Widget).addCssClass("monospace");
                        entry.getBuffer().setText(display_z, -1);
                        command_row.append(entry.as(gtk.Widget));
                        row.append(command_row.as(gtk.Widget));
                        try priv.review_rows.append(ApplicationAllocator.get(), .{
                            .tab = @intCast(tab_index),
                            .node = @intCast(node_index),
                            .check = check,
                            .entry = entry,
                            .original = command,
                            .display = display,
                        });
                        ApplicationAllocator.get().free(display_z);
                    } else {
                        const shell = gtk.Label.new(i18n._("Fresh shell"));
                        shell.as(gtk.Widget).setHalign(.start);
                        row.append(shell.as(gtk.Widget));
                    }
                    priv.review_list.append(row.as(gtk.Widget));
                },
            };
        }
        priv.stack.setVisibleChild(priv.review_page.as(gtk.Widget));
    }

    fn reviewBack(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.clearReview();
        self.private().stack.setVisibleChild(self.private().library_page.as(gtk.Widget));
    }

    fn restoreClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.restoreReviewed() catch |err| {
            log.warn("unable to restore session snapshot err={}", .{err});
            const window = self.private().window.get() orelse return;
            defer window.unref();
            window.showToast(i18n._("Could not restore the saved session"));
        };
    }

    fn restoreReviewed(self: *Self) !void {
        const priv = self.private();
        const name = priv.review_name orelse return error.NoReview;
        const loaded = if (priv.loaded) |*value| value else return error.NotLoaded;
        const snapshot = session_snapshot.find(loaded.value, name) orelse return error.NotFound;
        const alloc = ApplicationAllocator.get();
        var commands: std.ArrayList(Window.RestoreCommand) = .empty;
        defer {
            for (commands.items) |*command| command.deinit(alloc);
            commands.deinit(alloc);
        }

        for (priv.review_rows.items) |row| {
            if (row.check.getActive() == 0) continue;
            const text = std.mem.span(row.entry.getBuffer().getText());
            if (text.len == 0) continue;
            const action: Window.RestoreCommand.Action = switch (row.original.*) {
                .foreground => .{ .shell_input = try shellInput(alloc, text) },
                .shell, .direct => .{ .launch = if (std.mem.eql(u8, text, row.display))
                    try cloneSavedCommand(alloc, row.original.*)
                else
                    configpkg.Command{ .shell = try alloc.dupeZ(u8, text) } },
            };
            var restore_command: Window.RestoreCommand = .{
                .tab = row.tab,
                .node = row.node,
                .action = action,
            };
            commands.append(alloc, restore_command) catch |err| {
                restore_command.deinit(alloc);
                return err;
            };
        }

        const window = priv.window.get() orelse return error.NoWindow;
        defer window.unref();
        _ = try window.restoreSessionSnapshot(snapshot.*, commands.items);
        self.close();
    }

    fn clearReview(self: *Self) void {
        const priv = self.private();
        clearBox(priv.review_list);
        const alloc = ApplicationAllocator.get();
        for (priv.review_rows.items) |row| alloc.free(row.display);
        priv.review_rows.clearRetainingCapacity();
        if (priv.review_name) |name| {
            alloc.free(name);
            priv.review_name = null;
        }
    }

    fn clearBox(box: *gtk.Box) void {
        while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
    }

    fn formatCommand(alloc: std.mem.Allocator, command: session_snapshot.LaunchCommand) ![]u8 {
        return switch (command) {
            .shell => |shell| try alloc.dupe(u8, shell),
            .direct, .foreground => |argv| direct: {
                var output: std.Io.Writer.Allocating = .init(alloc);
                errdefer output.deinit();
                for (argv, 0..) |arg, index| {
                    if (index > 0) try output.writer.writeByte(' ');
                    var escaped: internal_os.ShellEscapeWriter = .init(&output.writer);
                    try escaped.writer.writeAll(arg);
                }
                break :direct try output.toOwnedSlice();
            },
        };
    }

    fn shellInput(alloc: std.mem.Allocator, command: []const u8) ![]u8 {
        const input = try alloc.alloc(u8, command.len + 1);
        @memcpy(input[0..command.len], command);
        input[command.len] = '\r';
        return input;
    }

    fn cloneSavedCommand(alloc: std.mem.Allocator, command: session_snapshot.LaunchCommand) !configpkg.Command {
        return switch (command) {
            .shell => |shell| .{ .shell = try alloc.dupeZ(u8, shell) },
            .direct => |argv| direct: {
                const copy = try alloc.alloc([:0]const u8, argv.len);
                for (argv, copy) |arg, *dest| dest.* = try alloc.dupeZ(u8, arg);
                break :direct .{ .direct = copy };
            },
            .foreground => unreachable,
        };
    }

    fn setObjectName(object: *gobject.Object, key: [:0]const u8, value: []const u8) void {
        const copy = glib.ext.dupeZ(u8, value);
        object.setDataFull(key, @ptrCast(@constCast(copy.ptr)), freeObjectName);
    }

    fn objectName(object: *gobject.Object, key: [:0]const u8) ?[:0]const u8 {
        const value = object.getData(key) orelse return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    }

    fn freeObjectName(data: ?*anyopaque) callconv(.c) void {
        glib.free(data orelse return);
    }

    const ApplicationAllocator = struct {
        fn get() std.mem.Allocator {
            return @import("application.zig").Application.default().allocator();
        }
    };

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "session-palette",
                }),
            );
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("stack", .{});
            class.bindTemplateChildPrivate("library_page", .{});
            class.bindTemplateChildPrivate("review_page", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("save_button", .{});
            class.bindTemplateChildPrivate("snapshot_list", .{});
            class.bindTemplateChildPrivate("review_title", .{});
            class.bindTemplateChildPrivate("review_list", .{});
            class.bindTemplateChildPrivate("restore_button", .{});
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("save_clicked", &saveClicked);
            class.bindTemplateCallback("save_as_clicked", &saveAsClicked);
            class.bindTemplateCallback("review_back", &reviewBack);
            class.bindTemplateCallback("restore_clicked", &restoreClicked);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
