const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_manifest_bytes: usize = 4096;
pub const max_version_bytes: usize = 32;
pub const max_revision_bytes: usize = 64;
const min_revision_bytes: usize = 7;

pub const Channel = enum {
    stable,
    dev,

    pub fn parse(raw: []const u8) ?Channel {
        if (std.ascii.eqlIgnoreCase(raw, "stable")) return .stable;
        if (std.ascii.eqlIgnoreCase(raw, "dev")) return .dev;
        return null;
    }

    pub fn label(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const CurrentBuild = struct {
    channel: Channel,
    version: []const u8,
    revision: []const u8,
};

pub const Target = union(Channel) {
    stable: Stable,
    dev: Dev,

    pub const Stable = struct {
        version: []u8,
        artifact_ref: []u8,
    };

    pub const Dev = struct {
        version: []u8,
        revision: []u8,
        artifact_ref: []u8,
    };

    pub fn initStable(alloc: Allocator, raw_version: []const u8) !Target {
        const trimmed = std.mem.trim(u8, raw_version, " \t\r\n");
        const normalized_version = normalizeVersion(trimmed);
        if (!validVersion(normalized_version)) return error.InvalidVersion;

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const artifact_ref = try alloc.dupe(u8, trimmed);
        return .{ .stable = .{
            .version = owned_version,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn parseDevManifest(alloc: Allocator, bytes: []const u8) !Target {
        if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
            return error.InvalidManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidManifest;

        const version_value = parsed.value.object.get("version") orelse
            return error.InvalidManifest;
        const revision_value = parsed.value.object.get("commit") orelse
            return error.InvalidManifest;
        if (version_value != .string or revision_value != .string) {
            return error.InvalidManifest;
        }

        const normalized_version = normalizeVersion(version_value.string);
        const manifest_revision = revision_value.string;
        if (!validVersion(normalized_version) or !validRevision(manifest_revision)) {
            return error.InvalidManifest;
        }

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const owned_revision = try alloc.dupe(u8, manifest_revision);
        errdefer alloc.free(owned_revision);
        const artifact_ref = try std.fmt.allocPrint(alloc, "dev/{s}", .{manifest_revision});
        return .{ .dev = .{
            .version = owned_version,
            .revision = owned_revision,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn deinit(self: *Target, alloc: Allocator) void {
        switch (self.*) {
            .stable => |stable| {
                alloc.free(stable.version);
                alloc.free(stable.artifact_ref);
            },
            .dev => |dev| {
                alloc.free(dev.version);
                alloc.free(dev.revision);
                alloc.free(dev.artifact_ref);
            },
        }
        self.* = undefined;
    }

    pub fn channel(self: Target) Channel {
        return std.meta.activeTag(self);
    }

    pub fn version(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.version,
            .dev => |dev| dev.version,
        };
    }

    pub fn revision(self: Target) ?[]const u8 {
        return switch (self) {
            .stable => null,
            .dev => |dev| dev.revision,
        };
    }

    pub fn artifactRef(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.artifact_ref,
            .dev => |dev| dev.artifact_ref,
        };
    }

    pub fn shouldInstall(self: Target, current: CurrentBuild) bool {
        if (self.channel() != current.channel) return true;
        return switch (self) {
            .stable => |stable| compareVersions(stable.version, current.version) == .gt,
            .dev => |dev| !revisionsEqual(dev.revision, current.revision),
        };
    }

    pub fn writeDisplayLabel(self: Target, out: []u8) ![]const u8 {
        return switch (self) {
            .stable => |stable| std.fmt.bufPrint(out, "{s}", .{stable.version}),
            .dev => |dev| std.fmt.bufPrint(out, "dev {s}", .{shortRevision(dev.revision)}),
        };
    }
};

pub fn normalizeVersion(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == 'v') return raw[1..];
    return raw;
}

pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const av = parseStableVersion(a) orelse ParsedStableVersion{};
    const bv = parseStableVersion(b) orelse ParsedStableVersion{};
    if (av.parts[0] != bv.parts[0]) return std.math.order(av.parts[0], bv.parts[0]);
    if (av.parts[1] != bv.parts[1]) return std.math.order(av.parts[1], bv.parts[1]);
    if (av.parts[2] != bv.parts[2]) return std.math.order(av.parts[2], bv.parts[2]);
    return std.math.order(av.fn_revision, bv.fn_revision);
}

fn validVersion(raw: []const u8) bool {
    return parseStableVersion(raw) != null;
}

const ParsedStableVersion = struct {
    parts: [3]u32 = .{ 0, 0, 0 },
    fn_revision: u32 = 0,
};

fn parseStableVersion(raw: []const u8) ?ParsedStableVersion {
    const normalized = normalizeVersion(raw);
    if (normalized.len == 0 or normalized.len > max_version_bytes) return null;

    var core = normalized;
    var fn_revision: u32 = 0;
    if (std.mem.find(u8, normalized, "-fn.")) |suffix_index| {
        core = normalized[0..suffix_index];
        const revision_text = normalized[suffix_index + "-fn.".len ..];
        if (revision_text.len == 0) return null;
        for (revision_text) |byte| if (!std.ascii.isDigit(byte)) return null;
        fn_revision = std.fmt.parseUnsigned(u32, revision_text, 10) catch return null;
    }

    var count: usize = 0;
    var values = [_]u32{ 0, 0, 0 };
    var parts = std.mem.splitScalar(u8, core, '.');
    while (parts.next()) |part| {
        if (count == 3 or part.len == 0) return null;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return null;
        values[count] = std.fmt.parseUnsigned(u32, part, 10) catch return null;
        count += 1;
    }
    if (count != 3) return null;
    return .{ .parts = values, .fn_revision = fn_revision };
}

fn validRevision(raw: []const u8) bool {
    if (raw.len < min_revision_bytes or raw.len > max_revision_bytes) return false;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn revisionsEqual(full: []const u8, current: []const u8) bool {
    if (std.mem.eql(u8, current, "unknown")) return false;
    const common_len = @min(full.len, current.len);
    if (common_len < min_revision_bytes) return false;
    return std.ascii.eqlIgnoreCase(full[0..common_len], current[0..common_len]);
}

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

test "channel parsing accepts only stable and dev" {
    try std.testing.expectEqual(Channel.stable, Channel.parse("stable").?);
    try std.testing.expectEqual(Channel.dev, Channel.parse("DEV").?);
    try std.testing.expect(Channel.parse("nightly") == null);
}

test "dev manifest creates a bounded immutable target" {
    const alloc = std.testing.allocator;
    var target = try Target.parseDevManifest(
        alloc,
        "{\"version\":\"0.3.62\",\"commit\":\"0123456789abcdef0123456789abcdef01234567\"}",
    );
    defer target.deinit(alloc);

    try std.testing.expectEqual(Channel.dev, target.channel());
    try std.testing.expectEqualStrings("0.3.62", target.version());
    try std.testing.expectEqualStrings(
        "dev/0123456789abcdef0123456789abcdef01234567",
        target.artifactRef(),
    );
    var label_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("dev 0123456789ab", try target.writeDisplayLabel(&label_buf));
}

test "dev manifest rejects malformed and oversized external data" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidManifest,
        Target.parseDevManifest(alloc, "{\"version\":\"0.3.62\",\"commit\":\"../escape\"}"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        Target.parseDevManifest(alloc, "{\"version\":\"0.3\",\"commit\":\"0123456\"}"),
    );
    try std.testing.expectError(
        error.ManifestTooLarge,
        Target.parseDevManifest(alloc, " " ** (max_manifest_bytes + 1)),
    );
}

test "stable release ordering rejects older targets and preserves channel switching" {
    const alloc = std.testing.allocator;
    var older = try Target.initStable(alloc, "v0.0.1");
    defer older.deinit(alloc);
    const newer_current = CurrentBuild{
        .channel = .stable,
        .version = "0.0.2",
        .revision = "0123456789ab",
    };

    try std.testing.expect(!older.shouldInstall(newer_current));
    try std.testing.expect(!older.shouldInstall(.{
        .channel = .stable,
        .version = "0.4.5",
        .revision = "0123456789ab",
    }));
    try std.testing.expect(older.shouldInstall(.{
        .channel = .dev,
        .version = "0.0.2",
        .revision = "abcdef012345",
    }));
}

test "stable fn releases preserve their tag and compare fork revisions" {
    const alloc = std.testing.allocator;
    var target = try Target.initStable(alloc, "v0.0.4-fn.2\n");
    defer target.deinit(alloc);

    try std.testing.expectEqualStrings("0.0.4-fn.2", target.version());
    try std.testing.expectEqualStrings("v0.0.4-fn.2", target.artifactRef());
    try std.testing.expect(target.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.4",
        .revision = "unknown",
    }));
    try std.testing.expect(target.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.4-fn.1",
        .revision = "unknown",
    }));
    try std.testing.expect(!target.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.4-fn.2",
        .revision = "unknown",
    }));
    try std.testing.expect(!target.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.4-fn.3",
        .revision = "unknown",
    }));
    try std.testing.expectEqual(
        std.math.Order.gt,
        compareVersions("0.0.5", "0.0.4-fn.999"),
    );
}

test "stable fn releases reject malformed suffixes" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "v0.0.4-fn."));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "v0.0.4-fn.x"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "v0.0.4-other.1"));
}

test "target freshness uses version for stable and revision for dev" {
    const alloc = std.testing.allocator;
    var stable = try Target.initStable(alloc, "v0.3.63");
    defer stable.deinit(alloc);
    const stable_current = CurrentBuild{
        .channel = .stable,
        .version = "0.3.62",
        .revision = "0123456789ab",
    };
    try std.testing.expect(stable.shouldInstall(stable_current));

    var dev = try Target.parseDevManifest(
        alloc,
        "{\"version\":\"0.3.62\",\"commit\":\"abcdef0123456789abcdef0123456789abcdef01\"}",
    );
    defer dev.deinit(alloc);
    try std.testing.expect(dev.shouldInstall(stable_current));
    try std.testing.expect(!dev.shouldInstall(.{
        .channel = .dev,
        .version = "0.3.62",
        .revision = "abcdef012345",
    }));
}
