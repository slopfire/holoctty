const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("ext.zig");
const folder_icons = @import("folder_icons.zig");
const i18n = @import("../../os/main.zig").i18n;
const Color = folder_icons.Color;
const Glyph = folder_icons.Glyph;
const Icon = folder_icons.Icon;
const log = std.log.scoped(.gtk_holoctty_folder_icon_picker);

const icon_name_key = "holoctty-folder-icon-name";
const tinted_key = "holoctty-folder-icon-tinted";
const dialog_key = "holoctty-folder-icon-dialog";
const max_system_results = 56;

pub const ChangedFn = *const fn (?*anyopaque) void;

const TargetKind = enum { folder, remote };

const Request = struct {
    refs: usize = 1,
    parent: *gtk.Widget,
    parent_window: ?*gtk.Window,
    kind: TargetKind,
    key: [:0]const u8,
    changed: ChangedFn,
    changed_data: ?*anyopaque,
    link_entry: ?*gtk.Entry = null,
    link_open: bool = false,
    system_dialog: ?*adw.Dialog = null,
    system_search: ?*gtk.SearchEntry = null,
    system_flow: ?*gtk.FlowBox = null,
    system_status: ?*gtk.Label = null,
    system_names: ?[*:null]?[*:0]u8 = null,

    fn init(
        parent: *gtk.Widget,
        kind: TargetKind,
        key: []const u8,
        changed: ChangedFn,
        changed_data: ?*anyopaque,
    ) !*Request {
        const self = try std.heap.c_allocator.create(Request);
        errdefer std.heap.c_allocator.destroy(self);
        const key_copy = glib.ext.dupeZ(u8, key);
        errdefer glib.free(key_copy.ptr);
        _ = parent.as(gobject.Object).ref();
        self.* = .{
            .parent = parent,
            .parent_window = ext.getAncestor(gtk.Window, parent) orelse
                gobject.ext.cast(gtk.Window, parent),
            .kind = kind,
            .key = key_copy,
            .changed = changed,
            .changed_data = changed_data,
        };
        return self;
    }

    fn retain(self: *Request) void {
        self.refs += 1;
    }

    fn release(self: *Request) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        glib.free(@ptrCast(@constCast(self.key.ptr)));
        self.parent.as(gobject.Object).unref();
        std.heap.c_allocator.destroy(self);
    }

    fn assign(self: *Request, icon: Icon) bool {
        (switch (self.kind) {
            .folder => folder_icons.assign(self.key, icon),
            .remote => folder_icons.assignRemote(self.key, icon),
        }) catch |err| {
            log.warn("unable to assign location icon key={s} err={}", .{ self.key, err });
            return false;
        };
        self.changed(self.changed_data);
        return true;
    }

    fn hasExact(self: *Request) bool {
        return switch (self.kind) {
            .folder => folder_icons.hasExact(self.key),
            .remote => folder_icons.hasExactRemote(self.key),
        };
    }

    fn remove(self: *Request) !bool {
        return switch (self.kind) {
            .folder => folder_icons.remove(self.key),
            .remote => folder_icons.removeRemote(self.key),
        };
    }
};

pub fn present(
    parent: *gtk.Widget,
    path: []const u8,
    changed: ChangedFn,
    changed_data: ?*anyopaque,
) void {
    presentTarget(parent, .folder, path, changed, changed_data);
}

pub fn presentRemote(
    parent: *gtk.Widget,
    host: []const u8,
    changed: ChangedFn,
    changed_data: ?*anyopaque,
) void {
    presentTarget(parent, .remote, host, changed, changed_data);
}

fn presentTarget(
    parent: *gtk.Widget,
    kind: TargetKind,
    key: []const u8,
    changed: ChangedFn,
    changed_data: ?*anyopaque,
) void {
    const request = Request.init(parent, kind, key, changed, changed_data) catch |err| {
        log.warn("unable to allocate location icon picker err={}", .{err});
        return;
    };
    showSourcePrompt(request);
}

fn showSourcePrompt(request: *Request) void {
    var body_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const body: [*:0]const u8 = body: {
        const formatted = std.fmt.bufPrintZ(
            &body_buf,
            "{s}\n{s}",
            .{
                request.key,
                if (request.kind == .folder)
                    i18n._("This icon applies to the current folder and its subfolders.")
                else
                    i18n._("This icon applies whenever you connect to this host."),
            },
        ) catch break :body if (request.kind == .folder)
            i18n._("This icon applies to the current folder and its subfolders.")
        else
            i18n._("This icon applies whenever you connect to this host.");
        break :body formatted.ptr;
    };
    const dialog = adw.AlertDialog.new(
        if (request.kind == .folder)
            i18n._("Choose a folder icon")
        else
            i18n._("Choose a remote icon"),
        body,
    );
    dialog.addResponse("cancel", i18n._("Cancel"));
    dialog.addResponse("colors", i18n._("Holoctty Icons"));
    dialog.addResponse("system", i18n._("System Icons"));
    dialog.addResponse("image", i18n._("Link or File"));
    if (request.hasExact()) {
        dialog.addResponse("remove", i18n._("Remove Icon"));
        dialog.setResponseAppearance("remove", .destructive);
    }
    dialog.setCloseResponse("cancel");
    dialog.choose(request.parent, null, sourceReady, request);
}

fn sourceReady(
    object: ?*gobject.Object,
    result: *gio.AsyncResult,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(userdata orelse return));
    const dialog: *adw.AlertDialog = @ptrCast(@alignCast(object orelse {
        request.release();
        return;
    }));
    const response = std.mem.span(dialog.chooseFinish(result));
    if (std.mem.eql(u8, response, "colors")) {
        showColorPrompt(request);
    } else if (std.mem.eql(u8, response, "system")) {
        showSystemPicker(request);
    } else if (std.mem.eql(u8, response, "image")) {
        showLinkPrompt(request, null);
    } else {
        if (std.mem.eql(u8, response, "remove")) {
            if (request.remove() catch |err| remove: {
                log.warn("unable to remove location icon key={s} err={}", .{ request.key, err });
                break :remove false;
            }) request.changed(request.changed_data);
        }
        request.release();
    }
}

fn showColorPrompt(request: *Request) void {
    const dialog = adw.AlertDialog.new(
        i18n._("Choose a Holoctty icon"),
        i18n._("Choose an icon shape and color."),
    );
    dialog.addResponse("cancel", i18n._("Cancel"));
    dialog.setCloseResponse("cancel");

    const choices = gtk.Box.new(.vertical, 4);
    choices.as(gtk.Widget).setMarginTop(6);
    choices.as(gtk.Widget).setMarginBottom(2);
    for (std.enums.values(Glyph)) |glyph| {
        const glyph_label = gtk.Label.new(glyph.label());
        glyph_label.setXalign(0);
        glyph_label.as(gtk.Widget).addCssClass("dim-label");
        choices.append(glyph_label.as(gtk.Widget));

        const colors = gtk.Box.new(.horizontal, 4);
        colors.as(gtk.Widget).setHalign(.center);
        for (std.enums.values(Color)) |color| {
            const button = gtk.Button.new();
            const button_widget = button.as(gtk.Widget);
            button_widget.addCssClass("flat");
            button_widget.addCssClass("folder-icon-color-choice");
            var tooltip_buf: [64]u8 = undefined;
            const tooltip = std.fmt.bufPrintZ(
                &tooltip_buf,
                "{s}, {s}",
                .{ glyph.label(), color.label() },
            ) catch color.label();
            button_widget.setTooltipText(tooltip);
            const color_count = std.enums.values(Color).len;
            const encoded = @as(usize, @intCast(@intFromEnum(glyph))) * color_count +
                @as(usize, @intCast(@intFromEnum(color))) + 1;
            button.as(gobject.Object).setData(tinted_key, @ptrFromInt(encoded));
            button.as(gobject.Object).setData(dialog_key, dialog);

            const image = gtk.Image.newFromIconName(glyph.iconName());
            image.setPixelSize(22);
            const image_widget = image.as(gtk.Widget);
            image_widget.addCssClass("custom-folder-icon");
            image_widget.addCssClass(color.cssClass());
            button.setChild(image_widget);
            _ = gtk.Button.signals.clicked.connect(
                button,
                *Request,
                colorClicked,
                request,
                .{},
            );
            colors.append(button_widget);
        }
        choices.append(colors.as(gtk.Widget));
    }
    dialog.setExtraChild(choices.as(gtk.Widget));
    dialog.choose(request.parent, null, colorReady, request);
}

fn colorClicked(button: *gtk.Button, request: *Request) callconv(.c) void {
    const raw_choice = button.as(gobject.Object).getData(tinted_key) orelse return;
    const index: usize = @intFromPtr(raw_choice) - 1;
    const colors = std.enums.values(Color);
    const glyphs = std.enums.values(Glyph);
    const glyph_index = index / colors.len;
    const color_index = index % colors.len;
    if (glyph_index >= glyphs.len) return;
    if (!request.assign(.{ .tinted = .{
        .glyph = glyphs[glyph_index],
        .color = colors[color_index],
    } })) return;
    const raw_dialog = button.as(gobject.Object).getData(dialog_key) orelse return;
    const dialog: *adw.AlertDialog = @ptrCast(@alignCast(raw_dialog));
    _ = dialog.as(adw.Dialog).close();
}

fn colorReady(
    _: ?*gobject.Object,
    _: *gio.AsyncResult,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(userdata orelse return));
    request.release();
}

fn showSystemPicker(request: *Request) void {
    const dialog = adw.Dialog.new();
    dialog.setTitle(if (request.kind == .folder)
        i18n._("Choose a system icon")
    else
        i18n._("Choose a remote icon"));
    dialog.setContentWidth(560);
    dialog.setContentHeight(500);
    request.system_dialog = dialog;

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    const content = gtk.Box.new(.vertical, 0);
    const search = gtk.SearchEntry.new();
    search.setPlaceholderText(i18n._("Search system icons"));
    search.setSearchDelay(80);
    const search_widget = search.as(gtk.Widget);
    search_widget.setMarginStart(12);
    search_widget.setMarginEnd(12);
    search_widget.setMarginTop(12);
    search_widget.setMarginBottom(6);
    content.append(search_widget);

    const flow = gtk.FlowBox.new();
    flow.setActivateOnSingleClick(1);
    flow.setColumnSpacing(6);
    flow.setRowSpacing(6);
    flow.setHomogeneous(1);
    flow.setMinChildrenPerLine(6);
    flow.setMaxChildrenPerLine(8);
    flow.setSelectionMode(.none);
    flow.as(gtk.Widget).addCssClass("folder-icon-picker-grid");
    request.system_search = search;
    request.system_flow = flow;
    _ = gtk.SearchEntry.signals.search_changed.connect(
        search,
        *Request,
        systemSearchChanged,
        request,
        .{},
    );

    const status = gtk.Label.new(null);
    status.setWrap(1);
    status.setXalign(0);
    const status_widget = status.as(gtk.Widget);
    status_widget.addCssClass("dim-label");
    status_widget.setMarginStart(12);
    status_widget.setMarginEnd(12);
    status_widget.setMarginBottom(6);
    content.append(status_widget);
    request.system_status = status;

    const theme = gtk.IconTheme.getForDisplay(request.parent.getDisplay());
    request.system_names = @ptrCast(theme.getIconNames());
    populateSystemIcons(request);

    const scrolled = gtk.ScrolledWindow.new();
    scrolled.setPolicy(.never, .automatic);
    scrolled.setChild(flow.as(gtk.Widget));
    scrolled.as(gtk.Widget).setVexpand(1);
    content.append(scrolled.as(gtk.Widget));
    toolbar.setContent(content.as(gtk.Widget));
    dialog.setChild(toolbar.as(gtk.Widget));
    dialog.setFocus(search_widget);
    _ = adw.Dialog.signals.closed.connect(
        dialog,
        *Request,
        systemPickerClosed,
        request,
        .{},
    );
    dialog.present(request.parent);
}

fn appendSystemIcon(flow: *gtk.FlowBox, name: [*:0]const u8, request: *Request) void {
    const button = gtk.Button.new();
    const button_widget = button.as(gtk.Widget);
    button_widget.addCssClass("flat");
    button_widget.addCssClass("folder-icon-system-choice");
    button_widget.setTooltipText(name);
    const name_copy = glib.ext.dupeZ(u8, std.mem.span(name));
    button.as(gobject.Object).setDataFull(
        icon_name_key,
        @ptrCast(name_copy.ptr),
        freeString,
    );
    const image = gtk.Image.newFromIconName(name);
    image.setPixelSize(24);
    button.setChild(image.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(
        button,
        *Request,
        systemIconClicked,
        request,
        .{},
    );
    flow.append(button_widget);
}

fn freeString(data: ?*anyopaque) callconv(.c) void {
    glib.free(data);
}

fn systemSearchChanged(_: *gtk.SearchEntry, request: *Request) callconv(.c) void {
    populateSystemIcons(request);
}

fn populateSystemIcons(request: *Request) void {
    const flow = request.system_flow orelse return;
    const search = request.system_search orelse return;
    const names = request.system_names orelse return;
    while (flow.as(gtk.Widget).getFirstChild()) |child| flow.remove(child);

    const query = std.mem.trim(
        u8,
        std.mem.span(search.as(gtk.Editable).getText()),
        " \t\r\n",
    );
    var results = ResultLimit{};
    var index: usize = 0;
    while (names[index]) |name| : (index += 1) {
        if (!systemIconMatches(std.mem.span(name), query, request.kind)) continue;
        if (!results.accept()) break;
        appendSystemIcon(flow, name, request);
    }

    const status = request.system_status orelse return;
    if (results.shown == 0) {
        status.setLabel(i18n._("No matching system icons."));
    } else if (results.has_more) {
        status.setLabel(i18n._("Showing the first matches. Type more to narrow the results."));
    } else if (query.len == 0) {
        status.setLabel(if (request.kind == .folder)
            i18n._("Folder icons from the current system theme.")
        else
            i18n._("Server icons from the current system theme."));
    } else {
        status.setLabel("");
    }
}

const ResultLimit = struct {
    shown: usize = 0,
    has_more: bool = false,

    fn accept(self: *ResultLimit) bool {
        if (self.shown == max_system_results) {
            self.has_more = true;
            return false;
        }
        self.shown += 1;
        return true;
    }
};

fn systemIconMatches(name: []const u8, query: []const u8, kind: TargetKind) bool {
    const default_query = switch (kind) {
        .folder => "folder",
        .remote => "server",
    };
    return containsIgnoreCase(name, if (query.len == 0) default_query else query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (haystack[start..][0..needle.len], needle) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn systemIconClicked(button: *gtk.Button, request: *Request) callconv(.c) void {
    const raw_name = button.as(gobject.Object).getData(icon_name_key) orelse return;
    const name: [*:0]const u8 = @ptrCast(raw_name);
    if (!request.assign(.{ .theme = std.mem.span(name) })) return;
    if (request.system_dialog) |dialog| _ = dialog.close();
}

fn systemPickerClosed(_: *adw.Dialog, request: *Request) callconv(.c) void {
    if (request.system_names) |names| {
        glib.strfreev(@ptrCast(names));
        request.system_names = null;
    }
    request.system_dialog = null;
    request.system_search = null;
    request.system_flow = null;
    request.system_status = null;
    request.release();
}

fn showLinkPrompt(request: *Request, body: ?[*:0]const u8) void {
    const dialog = adw.AlertDialog.new(
        i18n._("Use an image link or file"),
        body orelse i18n._("Paste an image URL or choose a local image file."),
    );
    dialog.addResponse("cancel", i18n._("Cancel"));
    dialog.addResponse("use", i18n._("Use Icon"));
    dialog.setResponseAppearance("use", .suggested);
    dialog.setDefaultResponse("use");
    dialog.setCloseResponse("cancel");

    const row = gtk.Box.new(.horizontal, 6);
    const entry = gtk.Entry.new();
    entry.setActivatesDefault(1);
    entry.setPlaceholderText("https://example.com/icon.png");
    entry.as(gtk.Widget).setHexpand(1);
    row.append(entry.as(gtk.Widget));
    const browse = gtk.Button.newWithLabel(i18n._("Browse…"));
    _ = gtk.Button.signals.clicked.connect(
        browse,
        *Request,
        browseImage,
        request,
        .{},
    );
    row.append(browse.as(gtk.Widget));
    dialog.setExtraChild(row.as(gtk.Widget));
    dialog.as(adw.Dialog).setFocus(entry.as(gtk.Widget));

    request.link_entry = entry;
    request.link_open = true;
    dialog.choose(request.parent, null, linkReady, request);
}

fn linkReady(
    object: ?*gobject.Object,
    result: *gio.AsyncResult,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(userdata orelse return));
    request.link_open = false;
    const entry = request.link_entry;
    request.link_entry = null;
    const dialog: *adw.AlertDialog = @ptrCast(@alignCast(object orelse {
        request.release();
        return;
    }));
    const response = std.mem.span(dialog.chooseFinish(result));
    if (!std.mem.eql(u8, response, "use")) {
        request.release();
        return;
    }

    const value = if (entry) |input|
        std.mem.trim(u8, std.mem.span(input.as(gtk.Editable).getText()), " \t\r\n")
    else
        "";
    if (value.len == 0) {
        showLinkPrompt(request, i18n._("Enter an image URL or choose a local image file."));
        return;
    }
    if (!setUriIcon(request, value)) {
        showLinkPrompt(request, i18n._("The image could not be saved. Choose another link or file."));
        return;
    }
    request.release();
}

fn setUriIcon(request: *Request, value: []const u8) bool {
    const value_z = glib.ext.dupeZ(u8, value);
    defer glib.free(value_z.ptr);
    const is_uri = std.mem.indexOf(u8, value, "://") != null or
        std.mem.startsWith(u8, value, "data:");
    const file = if (is_uri)
        gio.File.newForUri(value_z)
    else
        gio.File.newForPath(value_z);
    defer file.unref();
    const uri = file.getUri();
    defer glib.free(uri);
    return request.assign(.{ .uri = std.mem.span(uri) });
}

fn browseImage(_: *gtk.Button, request: *Request) callconv(.c) void {
    const dialog = gtk.FileDialog.new();
    dialog.setTitle(i18n._("Choose Icon"));
    dialog.setAcceptLabel(i18n._("Choose"));
    const filter = gtk.FileFilter.new();
    filter.setName(i18n._("Images"));
    filter.addPixbufFormats();
    dialog.setDefaultFilter(filter);
    filter.unref();
    request.retain();
    dialog.open(request.parent_window, null, imageFileReady, request);
}

fn imageFileReady(
    object: ?*gobject.Object,
    result: *gio.AsyncResult,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(userdata orelse return));
    defer request.release();
    const dialog: *gtk.FileDialog = @ptrCast(@alignCast(object orelse return));
    defer dialog.unref();
    var gerr: ?*glib.Error = null;
    const file = dialog.openFinish(result, &gerr) orelse {
        if (gerr) |err| err.free();
        return;
    };
    defer file.unref();
    if (!request.link_open) return;
    const entry = request.link_entry orelse return;
    const uri = file.getUri();
    defer glib.free(uri);
    entry.getBuffer().setText(uri, -1);
}

test "folder icon search is ASCII case insensitive" {
    try std.testing.expect(containsIgnoreCase("folder-download-symbolic", "DOWN"));
    try std.testing.expect(containsIgnoreCase("Document-Open", "document"));
    try std.testing.expect(!containsIgnoreCase("folder", "terminal"));
    try std.testing.expect(systemIconMatches("folder-download-symbolic", "", .folder));
    try std.testing.expect(!systemIconMatches("document-open-symbolic", "", .folder));
    try std.testing.expect(systemIconMatches("network-server-symbolic", "", .remote));
    try std.testing.expect(!systemIconMatches("folder-symbolic", "", .remote));
}

test "system icon results are bounded" {
    var results = ResultLimit{};
    var accepted: usize = 0;
    for (0..max_system_results + 20) |_| {
        if (!results.accept()) break;
        accepted += 1;
    }
    try std.testing.expectEqual(max_system_results, accepted);
    try std.testing.expectEqual(max_system_results, results.shown);
    try std.testing.expect(results.has_more);
}
