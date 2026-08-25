const std = @import("std");
const js_host_workspace = @import("../../core/hosts/js_host_workspace.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const terminal = @import("terminal.zig");

const Allocator = std.mem.Allocator;

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return failure(ctx.allocator, "browser terminal arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return failure(ctx.allocator, "browser terminal arguments must be an object");
    }
    const action = parsed.value.object.get("action") orelse {
        return failure(ctx.allocator, "browser terminal requires string field \"action\"");
    };
    if (action != .string or !std.mem.eql(u8, action.string, "exec")) {
        return failure(ctx.allocator, "browser terminal action must be \"exec\"");
    }
    const command = parsed.value.object.get("command") orelse {
        return failure(ctx.allocator, "browser terminal requires string field \"command\"");
    };
    if (command != .string) {
        return failure(ctx.allocator, "browser terminal field \"command\" must be a string");
    }
    if (parsed.value.object.count() != 2) {
        return failure(ctx.allocator, "browser terminal accepts only the \"action\" and \"command\" fields");
    }
    if (command.string.len > js_host_workspace.max_command_bytes) {
        return failure(ctx.allocator, "browser terminal field \"command\" exceeds 65536 bytes");
    }
    var native_args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer native_args.deinit();
    native_args.writer.writeAll("{\"action\":\"exec\",\"command\":") catch
        return error.OutOfMemory;
    std.json.Stringify.value(command.string, .{}, &native_args.writer) catch
        return error.OutOfMemory;
    native_args.writer.print(",\"timeout_ms\":{d}}}", .{js_host_workspace.max_timeout_ms}) catch
        return error.OutOfMemory;
    return terminal.decode(ctx, native_args.written());
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}
