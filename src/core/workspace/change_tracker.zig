const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const OperationKind = enum {
    write,
    edit,
    delete,
    rename,
};

pub const FileOperation = struct {
    kind: OperationKind,
    path: []u8,
    previous_content: ?[]u8,
    new_path: ?[]u8 = null,
    timestamp_ms: i64,
    /// Records why state required to reverse the mutation could not be retained.
    /// The operation remains a barrier, so undo consumes it and says so rather than
    /// silently undoing an older operation the user did not ask about.
    unavailable_cause: ?UnavailableCause = null,
};

pub const UnavailableStage = enum {
    capture_open,
    capture_read,
    new_path_clone,
};

pub const UnavailableCause = struct {
    stage: UnavailableStage,
    err: anyerror,
};

pub const UndoResult = union(enum) {
    restored: []const u8,
    deleted: []const u8,
    /// The operation was consumed but could not be reversed, either because its
    /// preimage was never captured or because restoring it failed. Undo must not
    /// guess, and must not report this as a restore.
    unavailable: []const u8,
    empty,
};

/// The state of a file before a mutation. `absent` means the file was proven not to
/// exist, which is the only case that licenses undo to delete it again; `unavailable`
/// means the state could not be read (too large, permissions, IO error) and nothing
/// about the file may be assumed.
pub const CaptureResult = union(enum) {
    captured: []u8,
    absent,
    unavailable: UnavailableCause,
};

const RollbackOutcome = union(enum) {
    not_attempted,
    succeeded,
    failed: anyerror,
};

const UndoTestControl = if (builtin.is_test) struct {
    before_rename_rollback: ?*const fn ([]const u8) void = null,
} else struct {};

pub const ChangeTracker = struct {
    stack: std.ArrayList(FileOperation) = .empty,

    const max_stack_size: usize = 100;

    pub fn deinit(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.deinit(alloc);
    }

    pub fn clear(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.clearRetainingCapacity();
    }

    pub fn pushOperation(self: *ChangeTracker, alloc: Allocator, op: FileOperation) !void {
        if (self.stack.items.len >= max_stack_size) {
            freeOperation(alloc, self.stack.items[0]);
            _ = self.stack.orderedRemove(0);
        }
        try self.stack.append(alloc, op);
    }

    pub fn undoLast(self: *ChangeTracker, alloc: Allocator) UndoResult {
        return self.undoLastWithTestControl(alloc, .{});
    }

    fn undoLastWithTestControl(
        self: *ChangeTracker,
        alloc: Allocator,
        test_control: UndoTestControl,
    ) UndoResult {
        if (self.stack.items.len == 0) return .empty;

        const op = self.stack.pop().?;
        defer if (op.new_path) |new_path| alloc.free(new_path);

        if (op.unavailable_cause) |cause| {
            if (op.previous_content) |content| alloc.free(content);
            traceUnavailable(op, @tagName(cause.stage), cause.err, .not_attempted);
            return .{ .unavailable = op.path };
        }

        switch (op.kind) {
            .delete => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch |err| {
                        traceUnavailable(op, "restore_deleted", err, .not_attempted);
                        return .{ .unavailable = op.path };
                    };
                    return .{ .restored = op.path };
                }
                alloc.free(op.path);
                return .empty;
            },
            .rename => {
                if (op.new_path) |new_path| {
                    std.Io.Dir.renameAbsolute(new_path, op.path, io_mod.getIo()) catch |err| {
                        if (op.previous_content) |content| alloc.free(content);
                        traceUnavailable(op, "rename_back", err, .not_attempted);
                        return .{ .unavailable = op.path };
                    };
                    // previous_content holds the overwritten destination preimage.
                    if (op.previous_content) |content| {
                        defer alloc.free(content);
                        restoreContent(alloc, new_path, content) catch |err| {
                            // The rename back succeeded but the file it displaced could
                            // not be put back. Undo the rename too, so the tree is left
                            // as it was rather than half reversed under a success report.
                            if (comptime builtin.is_test) {
                                if (test_control.before_rename_rollback) |callback| callback(new_path);
                            }
                            const rollback: RollbackOutcome = if (std.Io.Dir.renameAbsolute(op.path, new_path, io_mod.getIo()))
                                .succeeded
                            else |rollback_err|
                                .{ .failed = rollback_err };
                            traceUnavailable(
                                op,
                                "restore_destination",
                                err,
                                rollback,
                            );
                            return .{ .unavailable = op.path };
                        };
                    }
                    return .{ .restored = op.path };
                }
                if (op.previous_content) |content| alloc.free(content);
                return .{ .restored = op.path };
            },
            .write, .edit => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch |err| {
                        traceUnavailable(op, "restore_content", err, .not_attempted);
                        return .{ .unavailable = op.path };
                    };
                    return .{ .restored = op.path };
                }

                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), op.path) catch |err| {
                    // An already-absent file has reached the requested state. Every
                    // other failure leaves the file's state uncertain and must not
                    // be reported as a successful deletion.
                    if (err != error.FileNotFound) {
                        traceUnavailable(op, "delete_created", err, .not_attempted);
                        return .{ .unavailable = op.path };
                    }
                };
                return .{ .deleted = op.path };
            },
        }
    }

    pub fn captureFileState(alloc: Allocator, absolute_path: []const u8) CaptureResult {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{}) catch |err| {
            return if (err == error.FileNotFound) .absent else .{ .unavailable = .{
                .stage = .capture_open,
                .err = err,
            } };
        };
        defer file.close(io_mod.getIo());
        const content = io_mod.readFileToEnd(alloc, &file, 10 * 1024 * 1024) catch |err| return .{ .unavailable = .{
            .stage = .capture_read,
            .err = err,
        } };
        return .{ .captured = content };
    }

    /// Restores `content` at `absolute_path` without destroying what is already there
    /// until the replacement is durable. A failed restore leaves the current file
    /// untouched and is reported to the caller rather than swallowed.
    ///
    /// There is no in-place fallback for a file whose directory denies writes. Such a
    /// file cannot be replaced atomically, and writing the preimage over it directly
    /// would leave a half-replaced file behind on any mid-write failure, which is the
    /// damage undo exists to avoid. The caller reports the refusal instead.
    fn restoreContent(alloc: Allocator, absolute_path: []const u8, content: []const u8) !void {
        try io_mod.writeFileAtomic(alloc, absolute_path, content);
    }

    fn freeOperation(alloc: Allocator, op: FileOperation) void {
        alloc.free(op.path);
        if (op.previous_content) |content| alloc.free(content);
        if (op.new_path) |new_path| alloc.free(new_path);
    }
};

fn traceUnavailable(
    op: FileOperation,
    stage: []const u8,
    err: anyerror,
    rollback: RollbackOutcome,
) void {
    var path_buf: [256]u8 = undefined;
    const path = debug_trace.terminalPreview(path_buf[0..], op.path);
    switch (rollback) {
        .not_attempted => debug_trace.eventf(
            "undo",
            "undo_unavailable",
            .{},
            "kind={s} path={s} stage={s} error={s} rollback=not_attempted",
            .{ @tagName(op.kind), path, stage, @errorName(err) },
        ),
        .succeeded => debug_trace.eventf(
            "undo",
            "undo_unavailable",
            .{},
            "kind={s} path={s} stage={s} error={s} rollback=succeeded",
            .{ @tagName(op.kind), path, stage, @errorName(err) },
        ),
        .failed => |rollback_err| debug_trace.eventf(
            "undo",
            "undo_unavailable",
            .{},
            "kind={s} path={s} stage={s} error={s} rollback=failed rollback_error={s}",
            .{ @tagName(op.kind), path, stage, @errorName(err), @errorName(rollback_err) },
        ),
    }
}

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, "");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn expectMissing(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
        file.close(io_mod.getIo());
        return error.FileStillExists;
    } else |_| {}
}

const FileSizeLimitGuard = struct {
    saved_limit: std.posix.rlimit,
    saved_action: std.posix.Sigaction,

    fn restore(self: FileSizeLimitGuard) void {
        std.posix.setrlimit(.FSIZE, self.saved_limit) catch {};
        std.posix.sigaction(std.posix.SIG.XFSZ, &self.saved_action, null);
    }
};

fn limitFileSizeForTest(bytes: u64, fail_after_signal: bool) !FileSizeLimitGuard {
    var saved_action: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &saved_action);
    errdefer std.posix.sigaction(std.posix.SIG.XFSZ, &saved_action, null);
    if (fail_after_signal) return error.InjectedSetupFailure;

    const saved_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = bytes, .max = saved_limit.max });
    return .{ .saved_limit = saved_limit, .saved_action = saved_action };
}

fn expectSignalHandlerEqual(expected: std.posix.Sigaction, actual: std.posix.Sigaction) !void {
    try std.testing.expectEqual(expected.handler.handler, actual.handler.handler);
}

fn readUndoTrace(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const path = try tmpPath(alloc, tmp.dir, name);
    defer alloc.free(path);
    return readAbsolute(alloc, path);
}

test "file size limit guard restores SIGXFSZ after normal use" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var original: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &original);
    defer std.posix.sigaction(std.posix.SIG.XFSZ, &original, null);

    var expected: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &expected);
    const guard = try limitFileSizeForTest(4096, false);
    guard.restore();

    var actual: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &actual);
    try expectSignalHandlerEqual(expected, actual);
}

test "file size limit setup restores SIGXFSZ on failure" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var original: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &original);
    defer std.posix.sigaction(std.posix.SIG.XFSZ, &original, null);

    var expected: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &expected);
    try std.testing.expectError(error.InjectedSetupFailure, limitFileSizeForTest(4096, true));

    var actual: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &actual);
    try expectSignalHandlerEqual(expected, actual);
}

test "undoLast returns empty on an initially empty stack" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "clear releases operations and leaves the tracker empty" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, "/workspace/a.txt"),
        .previous_content = try alloc.dupe(u8, "before"),
        .new_path = try alloc.dupe(u8, "/workspace/b.txt"),
        .timestamp_ms = 1,
    });

    tracker.clear(alloc);

    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, "/workspace/reused.txt"),
        .previous_content = null,
        .timestamp_ms = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqualStrings("/workspace/reused.txt", tracker.stack.items[0].path);
}

test "pushOperation evicts the oldest operation with stable ordering" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    for (0..ChangeTracker.max_stack_size + 1) |i| {
        try tracker.pushOperation(alloc, .{
            .kind = .write,
            .path = try std.fmt.allocPrint(alloc, "/tracked/file-{d}", .{i}),
            .previous_content = null,
            .timestamp_ms = @intCast(i),
        });
    }

    try std.testing.expectEqual(ChangeTracker.max_stack_size, tracker.stack.items.len);
    try std.testing.expectEqualStrings("/tracked/file-1", tracker.stack.items[0].path);
    try std.testing.expectEqualStrings("/tracked/file-100", tracker.stack.items[tracker.stack.items.len - 1].path);
}

test "undoLast restores previous content for write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "modified");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "original"),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("original", content);
}

test "undoLast deletes new write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "new content");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast reports deleted for a new write when the file is already absent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "already-absent.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast reports unavailable when a new file cannot be deleted" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/new.txt");
    defer alloc.free(path);
    try writeAbsolute(path, "new content");

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeZ(u8, dir_path);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported_path| {
            defer alloc.free(reported_path);
            try std.testing.expectEqualStrings(path, reported_path);
        },
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("new content", survived);
}

test "undoLast restores deleted files when previous content exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "deleted.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .delete,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "restored"),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("restored", content);
}

test "undoLast returns empty for deleted files without previous content" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .delete,
        .path = try alloc.dupe(u8, "/workspace/deleted.txt"),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "undoLast renames new_path back to path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "old.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(new_path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), new_path) catch {};

    try writeAbsolute(new_path, "moved");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = null,
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(old_path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, old_path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("moved", content);
    try expectMissing(new_path);
}

test "undoLast restores destination preimage after overwrite rename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "source.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "dest.txt");
    defer alloc.free(new_path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), new_path) catch {};

    // After overwrite rename, only dest exists with the source bytes.
    try writeAbsolute(new_path, "source-bytes");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = try alloc.dupe(u8, "dest-preimage"),
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(old_path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const source = try readAbsolute(alloc, old_path);
    defer alloc.free(source);
    try std.testing.expectEqualStrings("source-bytes", source);
    const dest = try readAbsolute(alloc, new_path);
    defer alloc.free(dest);
    try std.testing.expectEqualStrings("dest-preimage", dest);
}

test "undoLast reports unavailable when renaming back fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "old-missing.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new-missing.txt");
    defer alloc.free(new_path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = try alloc.dupe(u8, "unused"),
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported_path| {
            defer alloc.free(reported_path);
            try std.testing.expectEqualStrings(old_path, reported_path);
        },
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "undoLast refuses rename operations without the required new_path" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, "/workspace/original.txt"),
        .previous_content = try alloc.dupe(u8, "previous"),
        .timestamp_ms = 1,
        .unavailable_cause = .{ .stage = .new_path_clone, .err = error.OutOfMemory },
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .unavailable => |reported_path| {
            defer alloc.free(reported_path);
            try std.testing.expectEqualStrings("/workspace/original.txt", reported_path);
        },
        else => return error.ExpectedUnavailable,
    }
}

test "undoLast pops before filesystem restore failures, reports them, and does not create parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "missing-parent/file.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "content"),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try expectMissing(path);
    // The stack is empty now, which is a different answer from a failed restore.
    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "captureFileState captures existing files and returns null for missing files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "capture.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "snapshot");

    const captured = switch (ChangeTracker.captureFileState(alloc, path)) {
        .captured => |content| content,
        else => return error.ExpectedCapture,
    };
    defer alloc.free(captured);
    try std.testing.expectEqualStrings("snapshot", captured);

    const missing_path = try tmpPath(alloc, tmp.dir, "missing.txt");
    defer alloc.free(missing_path);
    try std.testing.expect(ChangeTracker.captureFileState(alloc, missing_path) == .absent);
}

test "captureFileState reports unavailable for files at the size limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "limit.bin");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.setLength(io_mod.getIo(), 10 * 1024 * 1024);

    switch (ChangeTracker.captureFileState(alloc, path)) {
        .unavailable => |cause| try std.testing.expectEqual(UnavailableStage.capture_read, cause.stage),
        else => return error.ExpectedUnavailable,
    }
}

test "captureFileState reports unavailable for files over the size limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "over-limit.bin");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.setLength(io_mod.getIo(), 10 * 1024 * 1024 + 1);

    switch (ChangeTracker.captureFileState(alloc, path)) {
        .unavailable => |cause| try std.testing.expectEqual(UnavailableStage.capture_read, cause.stage),
        else => return error.ExpectedUnavailable,
    }
}

test "undoLast leaves the original file intact when the restore write fails" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore-target.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    const current = "bytes the user still has on disk";
    try writeAbsolute(path, current);

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'R');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    // Fail every write past 4 KiB, without the file-size signal killing the test process.
    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings(current, survived);
}

test "undoLast refuses an operation whose preimage was never captured" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trace_path = try tmpPath(alloc, tmp.dir, "preimage-unavailable.log");
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "undo");

    const path = try tmpPath(alloc, tmp.dir, "uncaptured.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "content the tool did not create");

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
        .unavailable_cause = .{ .stage = .capture_read, .err = error.FileTooBig },
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("content the tool did not create", survived);

    const trace = try readUndoTrace(alloc, tmp, "preimage-unavailable.log");
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=undo_unavailable") != null);
    try std.testing.expect(std.mem.find(u8, trace, "kind=write") != null);
    try std.testing.expect(std.mem.find(u8, trace, "stage=capture_read") != null);
    try std.testing.expect(std.mem.find(u8, trace, "error=FileTooBig") != null);
    try std.testing.expect(std.mem.find(u8, trace, "rollback=not_attempted") != null);
}

test "undo refuses a file whose directory denies writes and leaves it intact" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/file.txt");
    defer alloc.free(path);
    try writeAbsolute(path, "current bytes");

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeZ(u8, dir_path);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    // The file cannot be replaced atomically here, and a direct overwrite could
    // leave it half replaced, so undo reports that it could not act.
    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }
    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("current bytes", survived);
}

test "undo restore cannot be redirected by a symlink introduced after capture" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const recorded_path = try tmpPath(alloc, tmp.dir, "recorded.txt");
    defer alloc.free(recorded_path);
    const redirect_target = try tmpPath(alloc, tmp.dir, "redirect-target.txt");
    defer alloc.free(redirect_target);
    try writeAbsolute(recorded_path, "current bytes");
    try writeAbsolute(redirect_target, "must stay untouched");

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, recorded_path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), recorded_path);
    tmp.dir.symLink(std.testing.io, redirect_target, "recorded.txt", .{ .is_directory = false }) catch return error.SkipZigTest;

    switch (tracker.undoLast(alloc)) {
        .restored => |restored| alloc.free(restored),
        else => return error.ExpectedRestore,
    }

    const restored_stat = try tmp.dir.statFile(io_mod.getIo(), "recorded.txt", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, restored_stat.kind);
    const restored = try readAbsolute(alloc, recorded_path);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("preimage bytes", restored);
    const untouched = try readAbsolute(alloc, redirect_target);
    defer alloc.free(untouched);
    try std.testing.expectEqualStrings("must stay untouched", untouched);
}

test "undo rolls back a rename when the displaced file cannot be restored" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trace_path = try tmpPath(alloc, tmp.dir, "rename-rollback.log");
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "undo");

    const old_path = try tmpPath(alloc, tmp.dir, "old.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(new_path);
    try writeAbsolute(new_path, "renamed content");

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'D');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .new_path = try alloc.dupe(u8, new_path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    // The tree is left exactly as it was before the undo attempt.
    const displaced = try readAbsolute(alloc, new_path);
    defer alloc.free(displaced);
    try std.testing.expectEqualStrings("renamed content", displaced);
    try expectMissing(old_path);

    const trace = try readUndoTrace(alloc, tmp, "rename-rollback.log");
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=undo_unavailable") != null);
    try std.testing.expect(std.mem.find(u8, trace, "kind=rename") != null);
    try std.testing.expect(std.mem.find(u8, trace, "stage=restore_destination") != null);
    try std.testing.expect(std.mem.find(u8, trace, "rollback=succeeded") != null);
}

test "undo traces a failed rename rollback" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trace_path = try tmpPath(alloc, tmp.dir, "rename-rollback-failure.log");
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "undo");

    const old_path = try tmpPath(alloc, tmp.dir, "old.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(new_path);
    try writeAbsolute(new_path, "renamed content");

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'D');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .new_path = try alloc.dupe(u8, new_path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    const InjectRollbackFailure = struct {
        fn beforeRollback(path: []const u8) void {
            std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch unreachable;
        }
    };
    switch (tracker.undoLastWithTestControl(alloc, .{
        .before_rename_rollback = InjectRollbackFailure.beforeRollback,
    })) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const source = try readAbsolute(alloc, old_path);
    defer alloc.free(source);
    try std.testing.expectEqualStrings("renamed content", source);
    const blocked_target = try tmp.dir.statFile(io_mod.getIo(), "new.txt", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.directory, blocked_target.kind);

    const trace = try readUndoTrace(alloc, tmp, "rename-rollback-failure.log");
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=undo_unavailable") != null);
    try std.testing.expect(std.mem.find(u8, trace, "kind=rename") != null);
    try std.testing.expect(std.mem.find(u8, trace, "stage=restore_destination") != null);
    try std.testing.expect(std.mem.find(u8, trace, "rollback=failed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "rollback_error=") != null);
}

test "a locked directory plus a failing write never leaves a half-replaced file" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/file.txt");
    defer alloc.free(path);

    const current = "the bytes the user has right now";
    try writeAbsolute(path, current);

    // Large enough that any direct overwrite would be cut short by the limit
    // below, which is what would leave a prefix of preimage bytes behind.
    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'R');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeZ(u8, dir_path);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    // Not shortened, not partly rewritten: exactly the bytes that were there.
    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings(current, survived);
}
