const std = @import("std");

const planpkg = @import("tab_group_plan.zig");

const Allocator = std.mem.Allocator;

pub const TabSnapshot = struct {
    id: u64,
    title: []const u8,
    tooltip: ?[]const u8 = null,
    pwd: ?[]const u8 = null,
};

pub const Group = planpkg.Group;
pub const Plan = planpkg.Plan;

pub fn buildPrompt(
    alloc: Allocator,
    tabs: []const TabSnapshot,
    max_groups: usize,
    custom_instructions: ?[]const u8,
) ![:0]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    try output.writer.writeAll(
        \\Organize the terminal tabs listed below into useful groups and give each group a short, descriptive name.
        \\Return only strict JSON with this exact shape: {"groups":[{"name":"group name","tabs":[tab IDs]}]}.
        \\Use each tab ID at most once. Every group must contain at least one tab. You may omit tabs that do not fit a useful group.
    );
    try output.writer.print("Return at most {d} groups.\n", .{max_groups});

    if (custom_instructions) |instructions| {
        try output.writer.writeAll("Additional instructions: ");
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.write(instructions);
        try output.writer.writeByte('\n');
    }

    try output.writer.writeAll("Tabs: ");
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(tabs);
    try output.writer.writeByte('\n');

    return try output.toOwnedSliceSentinel(0);
}

pub fn buildOpenAIRequest(
    alloc: Allocator,
    model: []const u8,
    prompt: []const u8,
) ![:0]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.beginObject();
    try stringify.objectField("model");
    try stringify.write(model);
    try stringify.objectField("messages");
    try stringify.beginArray();
    try stringify.beginObject();
    try stringify.objectField("role");
    try stringify.write("user");
    try stringify.objectField("content");
    try stringify.write(prompt);
    try stringify.endObject();
    try stringify.endArray();
    try stringify.objectField("response_format");
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("json_object");
    try stringify.endObject();
    try stringify.endObject();

    return try output.toOwnedSliceSentinel(0);
}

pub fn extractOpenAIContent(alloc: Allocator, body: []const u8) ![]u8 {
    const Message = struct {
        content: ?[]const u8 = null,
    };
    const Choice = struct {
        message: Message,
    };
    const Response = struct {
        choices: []const Choice,
    };

    const parsed = try std.json.parseFromSlice(Response, alloc, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.MissingOpenAIChoice;
    const content = parsed.value.choices[0].message.content orelse
        return error.MissingOpenAIContent;
    return try alloc.dupe(u8, content);
}

pub fn parsePlan(
    alloc: Allocator,
    raw: []const u8,
    valid_tab_ids: []const u64,
    max_groups: usize,
) !Plan {
    if (raw.len > 1024 * 1024) return error.ResponseTooLarge;
    const WireGroup = struct {
        name: []const u8,
        tabs: []const u64,
    };
    const WirePlan = struct {
        groups: []const WireGroup,
    };

    const json = try stripJsonFence(raw);
    const parsed = try std.json.parseFromSlice(WirePlan, alloc, json, .{});
    defer parsed.deinit();

    if (parsed.value.groups.len == 0) return error.EmptyPlan;
    if (parsed.value.groups.len > max_groups) return error.TooManyGroups;

    var valid_ids: std.AutoHashMap(u64, void) = .init(alloc);
    defer valid_ids.deinit();
    for (valid_tab_ids) |id| try valid_ids.put(id, {});

    var used_ids: std.AutoHashMap(u64, void) = .init(alloc);
    defer used_ids.deinit();
    var names: std.StringHashMap(void) = .init(alloc);
    defer names.deinit();

    for (parsed.value.groups) |group| {
        const name = std.mem.trim(u8, group.name, " \t\r\n");
        if (name.len == 0) return error.EmptyGroupName;
        if (name.len > 80) return error.GroupNameTooLong;
        if (names.contains(name)) return error.DuplicateGroupName;
        try names.put(name, {});

        if (group.tabs.len == 0) return error.EmptyGroup;
        for (group.tabs) |id| {
            if (!valid_ids.contains(id)) return error.UnknownTabId;
            if (used_ids.contains(id)) return error.DuplicateTabId;
            try used_ids.put(id, {});
        }
    }

    var groups: std.ArrayList(Group) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(alloc);
        groups.deinit(alloc);
    }

    try groups.ensureTotalCapacity(alloc, parsed.value.groups.len);
    for (parsed.value.groups) |group| {
        const trimmed_name = std.mem.trim(u8, group.name, " \t\r\n");
        const name = try alloc.dupe(u8, trimmed_name);
        errdefer alloc.free(name);
        const tabs = try alloc.dupe(u64, group.tabs);
        groups.appendAssumeCapacity(.{ .name = name, .tabs = tabs });
    }

    return .{ .groups = try groups.toOwnedSlice(alloc) };
}

fn stripJsonFence(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;

    const header_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse
        return error.InvalidJsonFence;
    const header = std.mem.trim(u8, trimmed[3..header_end], " \t\r");
    if (header.len != 0 and !std.ascii.eqlIgnoreCase(header, "json"))
        return error.InvalidJsonFence;

    const fenced_body = std.mem.trim(u8, trimmed[header_end + 1 ..], " \t\r\n");
    if (!std.mem.endsWith(u8, fenced_body, "```"))
        return error.InvalidJsonFence;
    return std.mem.trim(u8, fenced_body[0 .. fenced_body.len - 3], " \t\r\n");
}

test "prompt and OpenAI request escape JSON strings" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{.{
        .id = 42,
        .title = "shell \"quoted\"",
        .tooltip = "C:\\work",
    }};

    const prompt = try buildPrompt(alloc, &tabs, 3, "Prefer \"work\" tabs");
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "shell \\\"quoted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "C:\\\\work") != null);

    const request = try buildOpenAIRequest(alloc, "gpt-4.1\"test", prompt);
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "gpt-4.1\"test",
        parsed.value.object.get("model").?.string,
    );
}

test "extract OpenAI content and parse a valid plan" {
    const alloc = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"{\"groups\":[{\"name\":\"Code\",\"tabs\":[1,2]}]}"}}],"id":"response"}
    ;
    const content = try extractOpenAIContent(alloc, body);
    defer alloc.free(content);

    var plan = try parsePlan(alloc, content, &.{ 1, 2, 3 }, 2);
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), plan.groups.len);
    try std.testing.expectEqualStrings("Code", plan.groups[0].name);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, plan.groups[0].tabs);
}

test "parse a fenced plan and allow omitted tabs" {
    const alloc = std.testing.allocator;
    const raw =
        \\```json
        \\{"groups":[{"name":"Servers","tabs":[7]}]}
        \\```
    ;

    var plan = try parsePlan(alloc, raw, &.{ 7, 8 }, 2);
    defer plan.deinit(alloc);
    try std.testing.expectEqualSlices(u64, &.{7}, plan.groups[0].tabs);
}

test "plan validation failures" {
    const alloc = std.testing.allocator;
    const valid_ids = [_]u64{ 1, 2, 3 };

    try std.testing.expectError(error.DuplicateTabId, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"One\",\"tabs\":[1]},{\"name\":\"Two\",\"tabs\":[1]}]}",
        &valid_ids,
        3,
    ));
    try std.testing.expectError(error.UnknownTabId, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"One\",\"tabs\":[9]}]}",
        &valid_ids,
        3,
    ));
    try std.testing.expectError(error.EmptyGroupName, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"  \",\"tabs\":[1]}]}",
        &valid_ids,
        3,
    ));
    try std.testing.expectError(error.DuplicateGroupName, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"One\",\"tabs\":[1]},{\"name\":\"One\",\"tabs\":[2]}]}",
        &valid_ids,
        3,
    ));
    try std.testing.expectError(error.EmptyGroup, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"One\",\"tabs\":[]}]}",
        &valid_ids,
        3,
    ));
    try std.testing.expectError(error.TooManyGroups, parsePlan(
        alloc,
        "{\"groups\":[{\"name\":\"One\",\"tabs\":[1]},{\"name\":\"Two\",\"tabs\":[2]}]}",
        &valid_ids,
        1,
    ));
}
