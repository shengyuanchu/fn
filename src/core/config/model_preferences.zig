const std = @import("std");
const model_provider = @import("model_provider.zig");

const provider_count = std.meta.fields(model_provider.ProviderId).len;

pub const Preferences = struct {
    values: [provider_count]?[]u8 = [_]?[]u8{null} ** provider_count,

    pub fn get(self: *const Preferences, provider: model_provider.ProviderId) ?[]const u8 {
        return self.values[@intFromEnum(provider)];
    }

    pub fn putCopy(
        self: *Preferences,
        alloc: std.mem.Allocator,
        provider: model_provider.ProviderId,
        model: []const u8,
    ) !void {
        const owned = try alloc.dupe(u8, model);
        self.putOwned(alloc, provider, owned);
    }

    pub fn putOwned(
        self: *Preferences,
        alloc: std.mem.Allocator,
        provider: model_provider.ProviderId,
        model: []u8,
    ) void {
        const index = @intFromEnum(provider);
        if (self.values[index]) |current| alloc.free(current);
        self.values[index] = model;
    }

    pub fn take(
        self: *Preferences,
        provider: model_provider.ProviderId,
    ) ?[]u8 {
        const index = @intFromEnum(provider);
        const value = self.values[index];
        self.values[index] = null;
        return value;
    }

    pub fn mergeOwnedFrom(
        self: *Preferences,
        alloc: std.mem.Allocator,
        incoming: *Preferences,
    ) void {
        inline for (std.meta.tags(model_provider.ProviderId)) |provider| {
            if (incoming.take(provider)) |model| self.putOwned(alloc, provider, model);
        }
    }

    pub fn count(self: *const Preferences) usize {
        var result: usize = 0;
        for (self.values) |value| result += @intFromBool(value != null);
        return result;
    }

    pub fn isEmpty(self: *const Preferences) bool {
        return self.count() == 0;
    }

    pub fn deinit(self: *Preferences, alloc: std.mem.Allocator) void {
        for (&self.values) |*value| {
            if (value.*) |model| alloc.free(model);
            value.* = null;
        }
    }
};

test "model preferences are bounded and provider keyed" {
    var preferences: Preferences = .{};
    defer preferences.deinit(std.testing.allocator);

    try preferences.putCopy(std.testing.allocator, .gateway, "gateway/model");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.4");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.6");

    try std.testing.expectEqualStrings("gateway/model", preferences.get(.gateway).?);
    try std.testing.expectEqualStrings("gpt-5.6", preferences.get(.codex).?);
    try std.testing.expect(preferences.get(.grok) == null);
    try std.testing.expectEqual(@as(usize, 2), preferences.count());
    _ = model_provider.ProviderId;
}
