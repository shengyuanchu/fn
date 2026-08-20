const std = @import("std");

pub const Policy = enum {
    finality_gated,
    append_only,
};

pub const ToolTurnFloor = struct {
    turn_id: u64,
    start_byte: usize,
};

/// Activity-independent finality boundaries for one prepared transcript flow.
/// `tool_turn_floors` is owned when populated and must be released with the
/// allocator that created or cloned it.
pub const Candidates = struct {
    mutation_pin_start: ?usize = null,
    assistant_tail_start: ?usize = null,
    tool_turn_floors: []const ToolTurnFloor = &.{},

    pub fn deinit(self: *Candidates, alloc: std.mem.Allocator) void {
        if (self.tool_turn_floors.len > 0) alloc.free(self.tool_turn_floors);
        self.* = .{};
    }

    pub fn clone(self: *const Candidates, alloc: std.mem.Allocator) !Candidates {
        return .{
            .mutation_pin_start = self.mutation_pin_start,
            .assistant_tail_start = self.assistant_tail_start,
            .tool_turn_floors = if (self.tool_turn_floors.len == 0)
                &.{}
            else
                try alloc.dupe(ToolTurnFloor, self.tool_turn_floors),
        };
    }
};

pub const State = struct {
    policy: Policy = .finality_gated,
    assistant_tail_writable: bool = true,

    pub fn with_assistant_tail_writable(self: State, writable: bool) State {
        var next = self;
        next.assistant_tail_writable = writable;
        return next;
    }

    /// Returns the earliest byte that is not final, or null when the entire
    /// prepared flow may enter native terminal history.
    pub fn finality_floor(
        self: State,
        candidates: Candidates,
        finalized_tool_turn_watermark: u64,
        replaceable_start: ?usize,
    ) ?usize {
        if (self.policy == .append_only) return null;

        var floor = candidates.mutation_pin_start;
        for (candidates.tool_turn_floors) |turn_floor| {
            if (turn_floor.turn_id <= finalized_tool_turn_watermark) continue;
            floor = earlier(floor, turn_floor.start_byte);
        }
        if (replaceable_start) |start| floor = earlier(floor, start);
        if (self.assistant_tail_writable) {
            if (candidates.assistant_tail_start) |start| {
                floor = earlier(floor, start);
            }
        }
        return floor;
    }
};

fn earlier(current: ?usize, candidate: usize) usize {
    return if (current) |value| @min(value, candidate) else candidate;
}

test "transcript release chooses the earliest mutable boundary" {
    const tool_turns = [_]ToolTurnFloor{
        .{ .turn_id = 4, .start_byte = 48 },
        .{ .turn_id = 6, .start_byte = 24 },
    };
    const candidates = Candidates{
        .mutation_pin_start = 32,
        .assistant_tail_start = 16,
        .tool_turn_floors = &tool_turns,
    };

    try std.testing.expectEqual(
        @as(?usize, 16),
        (State{}).finality_floor(candidates, 4, 40),
    );
}

test "transcript release ignores final producers and preserves append-only output" {
    const tool_turns = [_]ToolTurnFloor{
        .{ .turn_id = 4, .start_byte = 8 },
    };
    const candidates = Candidates{
        .assistant_tail_start = 12,
        .tool_turn_floors = &tool_turns,
    };

    try std.testing.expectEqual(
        @as(?usize, null),
        (State{ .assistant_tail_writable = false }).finality_floor(
            candidates,
            4,
            null,
        ),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        (State{ .policy = .append_only }).finality_floor(candidates, 0, 3),
    );
}

test "assistant tail writability returns a new state" {
    const open = State{};
    const closed = open.with_assistant_tail_writable(false);
    try std.testing.expect(open.assistant_tail_writable);
    try std.testing.expect(!closed.assistant_tail_writable);
    try std.testing.expect(closed.with_assistant_tail_writable(true).assistant_tail_writable);
}
