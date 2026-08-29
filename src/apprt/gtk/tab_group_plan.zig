const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Group = struct {
    name: []u8,
    tabs: []u64,

    pub fn deinit(self: *Group, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.tabs);
        self.* = undefined;
    }
};

pub const Plan = struct {
    groups: []Group,

    pub fn deinit(self: *Plan, alloc: Allocator) void {
        for (self.groups) |*group| group.deinit(alloc);
        alloc.free(self.groups);
        self.* = undefined;
    }
};
