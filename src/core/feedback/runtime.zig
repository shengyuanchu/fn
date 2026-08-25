const std = @import("std");

pub const url = "https://github.com/shengyuanchu/fn/issues";

test "feedback URL stays on the fx.sh domain" {
    try std.testing.expectEqualStrings("https://github.com/shengyuanchu/fn/issues", url);
}
