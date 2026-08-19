const std = @import("std");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const gateway_client = @import("client.zig");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const gateway_schema = @import("../core/tooling/gateway_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const tool_advertisement = @import("../core/tooling/tool_advertisement.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 8 * 1024 * 1024;

pub const openai_endpoint_env = "OPENAI_ENDPOINT";
pub const anthropic_endpoint_env = "ANTHROPIC_ENDPOINT";
pub const model_env = "MODEL";

const Protocol = enum {
    openai_chat_completions,
    openai_responses,
    anthropic_messages,
};

fn configuredUrlForEnv(env_name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(env_name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn configuredUrl() ?[]const u8 {
    return configuredUrlForEnv(openai_endpoint_env) orelse
        configuredUrlForEnv(anthropic_endpoint_env);
}

pub fn enabled() bool {
    return configuredUrl() != null;
}

fn configuredProtocol() !Protocol {
    const openai_url = configuredUrlForEnv(openai_endpoint_env);
    const anthropic_url = configuredUrlForEnv(anthropic_endpoint_env);
    if (openai_url != null and anthropic_url != null) {
        return error.ConflictingDirectProviderEndpoints;
    }
    if (openai_url) |url| {
        const protocol = try protocolForUrl(url);
        if (protocol == .anthropic_messages) return error.InvalidOpenAiEndpoint;
        return protocol;
    }
    if (anthropic_url) |url| {
        const protocol = try protocolForUrl(url);
        if (protocol != .anthropic_messages) return error.InvalidAnthropicEndpoint;
        return protocol;
    }
    return error.DirectProviderNotConfigured;
}

fn protocolForUrl(url: []const u8) !Protocol {
    try validateEndpointUrl(url);
    const query_start = std.mem.findScalar(u8, url, '?') orelse url.len;
    var path_end = query_start;
    while (path_end > 0 and url[path_end - 1] == '/') path_end -= 1;
    const endpoint = url[0..path_end];
    if (std.mem.endsWith(u8, endpoint, "/chat/completions")) return .openai_chat_completions;
    if (std.mem.endsWith(u8, endpoint, "/responses")) return .openai_responses;
    if (std.mem.endsWith(u8, endpoint, "/messages")) return .anthropic_messages;
    return error.UnsupportedDirectProviderEndpoint;
}

pub fn validateEndpointUrl(url: []const u8) error{ InvalidEndpoint, InsecureEndpoint }!void {
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidEndpoint;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null) {
        return error.InsecureEndpoint;
    }

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return error.InvalidEndpoint;
    if (std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]"))
    {
        return;
    }
    return error.InsecureEndpoint;
}

pub fn buildAgentRequest(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) ![]u8 {
    return buildAgentRequestForProtocol(alloc, request, try configuredProtocol());
}

fn buildAgentRequestForProtocol(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
    protocol: Protocol,
) ![]u8 {
    try checkBudget(request.budget);
    try gateway_json.validateToolMessageHistory(alloc, request.messages);

    if (request.verified_images != null and request.response_format == null) {
        return error.MissingStructuredResponseFormat;
    }
    if (request.response_format != null and request.verified_images == null) {
        return error.StructuredResponseRequiresVerifiedImages;
    }

    var required_tool_choice = false;
    var tools_json: []u8 = undefined;
    if (request.vision_mode == .required) {
        const vision_schema = try writeVisionSchema(alloc, request);
        defer alloc.free(vision_schema);
        tools_json = try std.fmt.allocPrint(alloc, "[{s}]", .{vision_schema});
        required_tool_choice = true;
    } else if (request.vision_mode != .unavailable or request.selected_dynamic_tool_schemas.len > 0) {
        const vision_schema = if (request.vision_mode != .unavailable)
            try writeVisionSchema(alloc, request)
        else
            null;
        defer if (vision_schema) |schema| alloc.free(schema);

        var schemas: std.ArrayList([]const u8) = .empty;
        defer schemas.deinit(alloc);
        try schemas.appendSlice(alloc, request.selected_dynamic_tool_schemas);
        if (vision_schema) |schema| try schemas.append(alloc, schema);
        tools_json = try tool_advertisement.buildGatewayToolsJsonWithSelectedDynamicSchemas(
            alloc,
            request.serialized_tools,
            schemas.items,
        );
    } else {
        tools_json = try alloc.dupe(u8, request.serialized_tools);
    }
    defer alloc.free(tools_json);

    return switch (protocol) {
        .openai_chat_completions => buildChatRequestBody(
            alloc,
            request,
            tools_json,
            required_tool_choice,
        ),
        .openai_responses => buildResponsesRequestBody(
            alloc,
            request,
            tools_json,
            required_tool_choice,
        ),
        .anthropic_messages => buildAnthropicRequestBody(
            alloc,
            request,
            tools_json,
            required_tool_choice,
        ),
    };
}

fn writeVisionSchema(alloc: Allocator, request: agent_stream_provider.BuildRequest) ![]u8 {
    const vision_tool = request.tool_registry.lookup("vision") orelse
        return error.VisionToolNotRegistered;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try gateway_schema.writeBuiltinFunctionSchema(alloc, &out.writer, vision_tool.gateway_schema);
    return out.toOwnedSlice();
}

fn checkBudget(budget: ?agent_stream_provider.BuildBudget) !void {
    const active = budget orelse return;
    if (active.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
    if (active.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) return error.TimedOut;
    }
}

fn buildChatRequestBody(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
    tools_json: []const u8,
    required_tool_choice: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    try out.writer.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        try checkBudget(request.budget);
        if (index > 0) try out.writer.writeByte(',');
        const verified_images = if (request.verified_images) |images|
            if (index + 1 == request.messages.len) images else null
        else
            null;
        try writeMessage(alloc, &out.writer, message, verified_images, request.budget);
    }
    try out.writer.writeByte(']');

    const function_tool_count = try writeTools(alloc, &out.writer, tools_json);
    if (function_tool_count > 0) {
        try out.writer.writeAll(",\"tool_choice\":");
        const tool_choice = if (required_tool_choice)
            "required"
        else
            request.tool_choice.label();
        try std.json.Stringify.value(tool_choice, .{}, &out.writer);
    } else if (required_tool_choice) {
        return error.VisionToolNotRegistered;
    }

    if (request.response_format) |format| {
        try writeResponseFormat(alloc, &out.writer, format);
    }
    try out.writer.writeAll(",\"stream\":true}");
    try checkBudget(request.budget);
    return out.toOwnedSlice();
}

fn writeMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?agent_stream_provider.BuildBudget,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);

    switch (message.role) {
        .system => {
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
        .user => try writeUserContent(alloc, writer, message, verified_images, budget),
        .assistant => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
        },
        .tool => {
            try writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
    }
    try writer.writeByte('}');
}

fn writeUserContent(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?agent_stream_provider.BuildBudget,
) !void {
    const image_count = if (verified_images) |images| images.len else message.images.len;
    try writer.writeAll(",\"content\":");
    if (image_count == 0) {
        try std.json.Stringify.value(message.content orelse "", .{}, writer);
        return;
    }

    try writer.writeByte('[');
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
    }

    if (verified_images) |images| {
        for (images) |snapshot| {
            try checkBudget(budget);
            if (wrote_part) try writer.writeByte(',');
            try writeImagePart(writer, snapshot);
            wrote_part = true;
        }
    } else {
        for (message.images) |attachment| {
            try checkBudget(budget);
            var snapshot = try image_attachments.loadVerifiedSnapshot(alloc, attachment, .{
                .deadline = if (budget) |active| active.deadline else null,
                .cancel_flag = if (budget) |active| active.cancel_flag else null,
            });
            defer snapshot.deinit(alloc);
            if (wrote_part) try writer.writeByte(',');
            try writeImagePart(writer, snapshot);
            wrote_part = true;
        }
    }
    try writer.writeByte(']');
}

fn writeImagePart(writer: *std.Io.Writer, snapshot: image_attachments.VerifiedSnapshot) !void {
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(snapshot.media_type);
    try writer.writeAll(";base64,");
    try std.base64.standard.Encoder.encodeWriter(writer, snapshot.bytes);
    try writer.writeAll("\"}}");
}

fn writeTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolArguments;

    var count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const type_value = tool.object.get("type") orelse continue;
        const name = tool.object.get("name") orelse continue;
        const input_schema = tool.object.get("inputSchema") orelse continue;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "function") or
            name != .string or name.string.len == 0)
        {
            continue;
        }

        if (count == 0) try writer.writeAll(",\"tools\":[") else try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(name.string, .{}, writer);
        if (tool.object.get("description")) |description| {
            if (description == .string) {
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description.string, .{}, writer);
            }
        }
        try writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(input_schema, .{}, writer);
        try writer.writeAll("}}");
        count += 1;
    }
    if (count > 0) try writer.writeByte(']');
    return count;
}

fn writeResponseFormat(
    alloc: Allocator,
    writer: *std.Io.Writer,
    format: agent_stream_provider.StructuredResponseFormat,
) !void {
    var schema = std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStructuredResponseSchema,
    };
    defer schema.deinit();
    if (schema.value != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"strict\":true,\"schema\":");
    try std.json.Stringify.value(schema.value, .{}, writer);
    try writer.writeAll("}}");
}

fn buildResponsesRequestBody(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
    tools_json: []const u8,
    required_tool_choice: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    try out.writer.writeAll(",\"input\":[");
    var wrote_item = false;
    for (request.messages, 0..) |message, index| {
        try checkBudget(request.budget);
        const verified_images = if (request.verified_images) |images|
            if (index + 1 == request.messages.len) images else null
        else
            null;
        switch (message.role) {
            .system, .user => {
                if (wrote_item) try out.writer.writeByte(',');
                try writeResponsesMessage(alloc, &out.writer, message, verified_images, request.budget);
                wrote_item = true;
            },
            .assistant => {
                if (message.content) |content| {
                    if (content.len > 0) {
                        if (wrote_item) try out.writer.writeByte(',');
                        try writeResponsesMessage(alloc, &out.writer, message, null, request.budget);
                        wrote_item = true;
                    }
                }
                for (message.tool_calls) |call| {
                    if (wrote_item) try out.writer.writeByte(',');
                    try out.writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, &out.writer);
                    try out.writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, &out.writer);
                    try out.writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, &out.writer);
                    try out.writer.writeByte('}');
                    wrote_item = true;
                }
            },
            .tool => {
                if (wrote_item) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, &out.writer);
                try out.writer.writeAll(",\"output\":");
                try std.json.Stringify.value(message.content orelse "", .{}, &out.writer);
                try out.writer.writeByte('}');
                wrote_item = true;
            },
        }
    }
    try out.writer.writeByte(']');

    const function_tool_count = try writeResponsesTools(alloc, &out.writer, tools_json);
    if (function_tool_count > 0) {
        try out.writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(
            if (required_tool_choice) "required" else request.tool_choice.label(),
            .{},
            &out.writer,
        );
    } else if (required_tool_choice) {
        return error.VisionToolNotRegistered;
    }

    if (request.response_format) |format| {
        try writeResponsesTextFormat(alloc, &out.writer, format);
    }
    try out.writer.writeAll(",\"stream\":true}");
    try checkBudget(request.budget);
    return out.toOwnedSlice();
}

fn writeResponsesMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?agent_stream_provider.BuildBudget,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);

    const image_count = if (verified_images) |images| images.len else message.images.len;
    if (message.role != .user or image_count == 0) {
        try writer.writeAll(",\"content\":");
        try std.json.Stringify.value(message.content orelse "", .{}, writer);
        try writer.writeByte('}');
        return;
    }

    try writer.writeAll(",\"content\":[");
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try writer.writeAll("{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
    }
    if (verified_images) |images| {
        for (images) |snapshot| {
            try checkBudget(budget);
            if (wrote_part) try writer.writeByte(',');
            try writeResponsesImagePart(writer, snapshot);
            wrote_part = true;
        }
    } else {
        for (message.images) |attachment| {
            try checkBudget(budget);
            var snapshot = try image_attachments.loadVerifiedSnapshot(alloc, attachment, .{
                .deadline = if (budget) |active| active.deadline else null,
                .cancel_flag = if (budget) |active| active.cancel_flag else null,
            });
            defer snapshot.deinit(alloc);
            if (wrote_part) try writer.writeByte(',');
            try writeResponsesImagePart(writer, snapshot);
            wrote_part = true;
        }
    }
    try writer.writeAll("]}");
}

fn writeResponsesImagePart(writer: *std.Io.Writer, snapshot: image_attachments.VerifiedSnapshot) !void {
    try writer.writeAll("{\"type\":\"input_image\",\"image_url\":\"data:");
    try writer.writeAll(snapshot.media_type);
    try writer.writeAll(";base64,");
    try std.base64.standard.Encoder.encodeWriter(writer, snapshot.bytes);
    try writer.writeAll("\"}");
}

fn writeResponsesTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolArguments;

    var count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const type_value = tool.object.get("type") orelse continue;
        const name = tool.object.get("name") orelse continue;
        const input_schema = tool.object.get("inputSchema") orelse continue;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "function") or
            name != .string or name.string.len == 0)
        {
            continue;
        }

        if (count == 0) try writer.writeAll(",\"tools\":[") else try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"function\",\"name\":");
        try std.json.Stringify.value(name.string, .{}, writer);
        if (tool.object.get("description")) |description| {
            if (description == .string) {
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description.string, .{}, writer);
            }
        }
        try writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(input_schema, .{}, writer);
        try writer.writeByte('}');
        count += 1;
    }
    if (count > 0) try writer.writeByte(']');
    return count;
}

fn writeResponsesTextFormat(
    alloc: Allocator,
    writer: *std.Io.Writer,
    format: agent_stream_provider.StructuredResponseFormat,
) !void {
    var schema = std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStructuredResponseSchema,
    };
    defer schema.deinit();
    if (schema.value != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"strict\":true,\"schema\":");
    try std.json.Stringify.value(schema.value, .{}, writer);
    try writer.writeAll("}}");
}

fn buildAnthropicRequestBody(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
    tools_json: []const u8,
    required_tool_choice: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    try out.writer.print(",\"max_tokens\":{d}", .{request.max_output_tokens orelse 32_000});

    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(alloc);
    for (request.messages) |message| {
        if (message.role != .system) continue;
        try checkBudget(request.budget);
        const content = message.content orelse "";
        if (content.len == 0) continue;
        if (system.items.len > 0) try system.appendSlice(alloc, "\n\n");
        try system.appendSlice(alloc, content);
    }
    if (system.items.len > 0) {
        try out.writer.writeAll(",\"system\":");
        try std.json.Stringify.value(system.items, .{}, &out.writer);
    }

    try out.writer.writeAll(",\"messages\":[");
    var wrote_message = false;
    for (request.messages, 0..) |message, index| {
        try checkBudget(request.budget);
        if (message.role == .system) continue;
        if (wrote_message) try out.writer.writeByte(',');
        const verified_images = if (request.verified_images) |images|
            if (index + 1 == request.messages.len) images else null
        else
            null;
        try writeAnthropicMessage(alloc, &out.writer, message, verified_images, request.budget);
        wrote_message = true;
    }
    try out.writer.writeByte(']');

    const function_tool_count = if (request.tool_choice == .none and !required_tool_choice)
        0
    else
        try writeAnthropicTools(alloc, &out.writer, tools_json);
    if (function_tool_count > 0) {
        try out.writer.writeAll(",\"tool_choice\":{\"type\":");
        try std.json.Stringify.value(if (required_tool_choice) "any" else "auto", .{}, &out.writer);
        try out.writer.writeByte('}');
    } else if (required_tool_choice) {
        return error.VisionToolNotRegistered;
    }

    if (request.response_format) |format| {
        try writeAnthropicOutputFormat(alloc, &out.writer, format);
    }
    try out.writer.writeAll(",\"stream\":true}");
    try checkBudget(request.budget);
    return out.toOwnedSlice();
}

fn writeAnthropicMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?agent_stream_provider.BuildBudget,
) !void {
    const role = if (message.role == .assistant) "assistant" else "user";
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[");
    var wrote_part = false;

    switch (message.role) {
        .system => unreachable,
        .user => {
            if (message.content) |content| {
                if (content.len > 0) {
                    try writeAnthropicTextPart(writer, content);
                    wrote_part = true;
                }
            }
            if (verified_images) |images| {
                for (images) |snapshot| {
                    try checkBudget(budget);
                    if (wrote_part) try writer.writeByte(',');
                    try writeAnthropicImagePart(writer, snapshot);
                    wrote_part = true;
                }
            } else {
                for (message.images) |attachment| {
                    try checkBudget(budget);
                    var snapshot = try image_attachments.loadVerifiedSnapshot(alloc, attachment, .{
                        .deadline = if (budget) |active| active.deadline else null,
                        .cancel_flag = if (budget) |active| active.cancel_flag else null,
                    });
                    defer snapshot.deinit(alloc);
                    if (wrote_part) try writer.writeByte(',');
                    try writeAnthropicImagePart(writer, snapshot);
                    wrote_part = true;
                }
            }
        },
        .assistant => {
            if (message.content) |content| {
                if (content.len > 0) {
                    try writeAnthropicTextPart(writer, content);
                    wrote_part = true;
                }
            }
            for (message.tool_calls) |call| {
                if (wrote_part) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                try std.json.Stringify.value(call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"input\":");
                try writeJsonObjectOrEmpty(alloc, writer, call.arguments_json);
                try writer.writeByte('}');
                wrote_part = true;
            }
        },
        .tool => {
            try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            if (message.tool_result_status == .failure) {
                try writer.writeAll(",\"is_error\":true");
            }
            try writer.writeByte('}');
            wrote_part = true;
        },
    }

    if (!wrote_part) try writeAnthropicTextPart(writer, "");
    try writer.writeAll("]}");
}

fn writeAnthropicTextPart(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

fn writeAnthropicImagePart(writer: *std.Io.Writer, snapshot: image_attachments.VerifiedSnapshot) !void {
    try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try std.json.Stringify.value(snapshot.media_type, .{}, writer);
    try writer.writeAll(",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(writer, snapshot.bytes);
    try writer.writeAll("\"}}");
}

fn writeJsonObjectOrEmpty(alloc: Allocator, writer: *std.Io.Writer, raw: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try writer.writeAll("{}");
            return;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try writer.writeAll("{}");
        return;
    }
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writeAnthropicTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolArguments;

    var count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const type_value = tool.object.get("type") orelse continue;
        const name = tool.object.get("name") orelse continue;
        const input_schema = tool.object.get("inputSchema") orelse continue;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "function") or
            name != .string or name.string.len == 0)
        {
            continue;
        }

        if (count == 0) try writer.writeAll(",\"tools\":[") else try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(name.string, .{}, writer);
        if (tool.object.get("description")) |description| {
            if (description == .string) {
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description.string, .{}, writer);
            }
        }
        try writer.writeAll(",\"input_schema\":");
        try std.json.Stringify.value(input_schema, .{}, writer);
        try writer.writeByte('}');
        count += 1;
    }
    if (count > 0) try writer.writeByte(']');
    return count;
}

fn writeAnthropicOutputFormat(
    alloc: Allocator,
    writer: *std.Io.Writer,
    format: agent_stream_provider.StructuredResponseFormat,
) !void {
    var schema = std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStructuredResponseSchema,
    };
    defer schema.deinit();
    if (schema.value != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"output_config\":{\"format\":{\"type\":\"json_schema\",\"schema\":");
    try std.json.Stringify.value(schema.value, .{}, writer);
    try writer.writeAll("}}");
}

pub fn streamAgentCompletion(
    alloc: Allocator,
    request: agent_stream_provider.Request,
) !agent_stream_provider.Result {
    const protocol = try protocolForUrl(request.chat_url);
    const uri = std.Uri.parse(request.chat_url) catch return error.InvalidEndpoint;
    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => @max(request.retry_count, 1),
    };

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const openai_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
        };
        const anthropic_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "x-api-key", .value = request.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };
        const extra_headers: []const std.http.Header = switch (protocol) {
            .openai_chat_completions, .openai_responses => &openai_headers,
            .anthropic_messages => &anthropic_headers,
        };
        var req = client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (protocol == .anthropic_messages)
                    .omit
                else
                    .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (gateway_client.isRetryableGatewayError(err) and attempt + 1 < retry_count) {
                io_mod.sleep((attempt + 1) * 150 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request.payload.len };
        var send_buf: [8192]u8 = undefined;
        request.delivery.markPossiblySent();
        var body_writer = try req.sendBodyUnflushed(&send_buf);
        try body_writer.writer.writeAll(request.payload);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        if (response.head.status != .ok) {
            const status = response.head.status;
            var transfer_buf: [16 * 1024]u8 = undefined;
            const reader = response.reader(&transfer_buf);
            const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
                error.StreamTooLong => try alloc.dupe(u8, "provider error response exceeded 1 MiB"),
                else => return err,
            };
            if (isRetryableStatus(status) and attempt + 1 < retry_count) {
                alloc.free(body);
                io_mod.sleep((attempt + 1) * 150 * std.time.ns_per_ms);
                continue;
            }
            return .{
                .status = status,
                .err_body = body,
                .completion = .{ .delivery_ambiguous = @intFromEnum(status) >= 500 },
                .ownership = .owned,
            };
        }

        var transfer_buf: [256 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const completion = switch (protocol) {
            .openai_chat_completions => try consumeOpenAiSseStream(
                alloc,
                reader,
                request.callback_ctx,
                request.on_content_chunk,
                request.on_tool_start,
                request.on_reasoning_chunk,
                request.on_tool_input_chunk,
                request.cancel_flag,
                request.content_capture_limit,
            ),
            .openai_responses => try consumeResponsesSseStream(
                alloc,
                reader,
                request.callback_ctx,
                request.on_content_chunk,
                request.on_tool_start,
                request.on_reasoning_chunk,
                request.on_tool_input_chunk,
                request.cancel_flag,
                request.content_capture_limit,
            ),
            .anthropic_messages => try consumeAnthropicSseStream(
                alloc,
                reader,
                request.callback_ctx,
                request.on_content_chunk,
                request.on_tool_start,
                request.on_reasoning_chunk,
                request.on_tool_input_chunk,
                request.cancel_flag,
                request.content_capture_limit,
            ),
        };
        return .{
            .status = .ok,
            .completion = completion,
            .ownership = .owned,
        };
    }
    return error.HttpConnectionClosing;
}

fn isRetryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = .{};
    }
};

pub fn consumeOpenAiSseStream(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var line_reader = SseLineReader{};
    defer line_reader.deinit(alloc);

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const event = try line_reader.next(alloc, reader);
        defer line_reader.releaseLine();
        const json_text = switch (event) {
            .data => |value| value,
            .done, .eof => break,
            .ignored => continue,
            .read_failed => return error.ReadFailed,
        };

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        captureUsage(parsed.value, &usage);

        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        if (choice.object.get("finish_reason")) |value| {
            if (value == .string) finish_reason = parseFinishReason(value.string);
        }
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("content")) |value| {
            if (value == .string and value.string.len > 0) {
                const remaining = if (content_capture_limit) |limit| limit -| content.items.len else value.string.len;
                try content.appendSlice(alloc, value.string[0..@min(value.string.len, remaining)]);
                on_content_chunk(callback_ctx, value.string);
            }
        }
        if (on_reasoning_chunk) |callback| {
            const reasoning = delta.object.get("reasoning_content") orelse delta.object.get("reasoning");
            if (reasoning) |value| {
                if (value == .string and value.string.len > 0) callback(callback_ctx, value.string);
            }
        }
        if (delta.object.get("tool_calls")) |tool_values| {
            if (tool_values == .array) {
                for (tool_values.array.items) |tool_value| {
                    try consumeToolDelta(
                        alloc,
                        &tools,
                        tool_value,
                        callback_ctx,
                        on_tool_start,
                        on_tool_input_chunk,
                    );
                }
            }
        }
    }

    var completion: types.GatewayCompletion = .{};
    errdefer deinitCompletion(alloc, &completion);
    if (content.items.len > 0) completion.content = try alloc.dupe(u8, content.items);
    completion.tool_calls = try materializeToolCalls(alloc, tools.items, callback_ctx, on_tool_start);
    completion.finish_reason = finish_reason orelse if (completion.tool_calls.len > 0) .tool_calls else .stop;
    completion.usage = usage;
    return completion;
}

fn consumeResponsesSseStream(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var line_reader = SseLineReader{};
    defer line_reader.deinit(alloc);

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const event = try line_reader.next(alloc, reader);
        defer line_reader.releaseLine();
        const json_text = switch (event) {
            .data => |value| value,
            .done, .eof => break,
            .ignored => continue,
            .read_failed => return error.ReadFailed,
        };

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type = parsed.value.object.get("type") orelse continue;
        if (event_type != .string) continue;

        if (std.mem.eql(u8, event_type.string, "response.output_text.delta")) {
            if (parsed.value.object.get("delta")) |delta| {
                if (delta == .string) try appendContentChunk(
                    alloc,
                    &content,
                    delta.string,
                    callback_ctx,
                    on_content_chunk,
                    content_capture_limit,
                );
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type.string, "response.reasoning_text.delta"))
        {
            if (on_reasoning_chunk) |callback| {
                if (parsed.value.object.get("delta")) |delta| {
                    if (delta == .string and delta.string.len > 0) callback(callback_ctx, delta.string);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.output_item.added") or
            std.mem.eql(u8, event_type.string, "response.output_item.done"))
        {
            const index = jsonIndex(parsed.value.object.get("output_index") orelse continue) orelse continue;
            const item = parsed.value.object.get("item") orelse continue;
            try consumeResponsesToolItem(alloc, &tools, index, item, callback_ctx, on_tool_start);
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.function_call_arguments.delta") or
            std.mem.eql(u8, event_type.string, "response.function_call_arguments.done"))
        {
            const index = jsonIndex(parsed.value.object.get("output_index") orelse continue) orelse continue;
            const field = if (std.mem.endsWith(u8, event_type.string, ".delta")) "delta" else "arguments";
            const value = parsed.value.object.get(field) orelse continue;
            if (value != .string or value.string.len == 0) continue;
            const tool = try ensureToolAccumulator(alloc, &tools, index);
            try appendDelta(alloc, &tool.arguments, value.string);
            if (std.mem.endsWith(u8, event_type.string, ".delta")) {
                if (on_tool_input_chunk) |callback| callback(callback_ctx, value.string);
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.completed")) {
            captureResponsesUsage(parsed.value, &usage);
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.incomplete")) {
            captureResponsesUsage(parsed.value, &usage);
            finish_reason = responsesIncompleteReason(parsed.value);
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "response.failed") or
            std.mem.eql(u8, event_type.string, "error"))
        {
            return error.ProviderStreamError;
        }
    }

    var completion: types.GatewayCompletion = .{};
    errdefer deinitCompletion(alloc, &completion);
    if (content.items.len > 0) completion.content = try alloc.dupe(u8, content.items);
    completion.tool_calls = try materializeToolCalls(alloc, tools.items, callback_ctx, on_tool_start);
    completion.finish_reason = finish_reason orelse if (completion.tool_calls.len > 0) .tool_calls else .stop;
    completion.usage = usage;
    return completion;
}

fn consumeResponsesToolItem(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    index: usize,
    item: std.json.Value,
    callback_ctx: *anyopaque,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
) !void {
    if (item != .object) return;
    const item_type = item.object.get("type") orelse return;
    if (item_type != .string or !std.mem.eql(u8, item_type.string, "function_call")) return;
    const tool = try ensureToolAccumulator(alloc, tools, index);
    if (item.object.get("call_id")) |id| {
        if (id == .string and id.string.len > 0) try appendDelta(alloc, &tool.id, id.string);
    } else if (item.object.get("id")) |id| {
        if (id == .string and id.string.len > 0) try appendDelta(alloc, &tool.id, id.string);
    }
    if (item.object.get("name")) |name| {
        if (name == .string and name.string.len > 0) try appendDelta(alloc, &tool.name, name.string);
    }
    if (item.object.get("arguments")) |arguments| {
        if (arguments == .string and arguments.string.len > 0) {
            try appendDelta(alloc, &tool.arguments, arguments.string);
        }
    }
    maybeStartTool(tool, callback_ctx, on_tool_start);
}

fn captureResponsesUsage(root: std.json.Value, usage: *types.Usage) void {
    const response = root.object.get("response") orelse root;
    if (response != .object) return;
    const usage_value = response.object.get("usage") orelse return;
    if (usage_value != .object) return;
    if (usage_value.object.get("input_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.input_tokens = tokens;
    }
    if (usage_value.object.get("output_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.output_tokens = tokens;
    }
}

fn responsesIncompleteReason(root: std.json.Value) types.ProviderFinishReason {
    const response = root.object.get("response") orelse return .other;
    if (response != .object) return .other;
    const details = response.object.get("incomplete_details") orelse return .other;
    if (details != .object) return .other;
    const reason = details.object.get("reason") orelse return .other;
    if (reason != .string) return .other;
    if (std.mem.eql(u8, reason.string, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, reason.string, "content_filter")) return .content_filter;
    return .other;
}

fn consumeAnthropicSseStream(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var line_reader = SseLineReader{};
    defer line_reader.deinit(alloc);

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const event = try line_reader.next(alloc, reader);
        defer line_reader.releaseLine();
        const json_text = switch (event) {
            .data => |value| value,
            .done, .eof => break,
            .ignored => continue,
            .read_failed => return error.ReadFailed,
        };

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type = parsed.value.object.get("type") orelse continue;
        if (event_type != .string) continue;

        if (std.mem.eql(u8, event_type.string, "message_start")) {
            if (parsed.value.object.get("message")) |message| captureAnthropicUsage(message, &usage);
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "content_block_start")) {
            const index = jsonIndex(parsed.value.object.get("index") orelse continue) orelse continue;
            const block = parsed.value.object.get("content_block") orelse continue;
            if (block != .object) continue;
            const block_type = block.object.get("type") orelse continue;
            if (block_type != .string) continue;
            if (std.mem.eql(u8, block_type.string, "tool_use")) {
                const tool = try ensureToolAccumulator(alloc, &tools, index);
                if (block.object.get("id")) |id| {
                    if (id == .string and id.string.len > 0) try appendDelta(alloc, &tool.id, id.string);
                }
                if (block.object.get("name")) |name| {
                    if (name == .string and name.string.len > 0) try appendDelta(alloc, &tool.name, name.string);
                }
                maybeStartTool(tool, callback_ctx, on_tool_start);
            } else if (std.mem.eql(u8, block_type.string, "text")) {
                if (block.object.get("text")) |text| {
                    if (text == .string) try appendContentChunk(
                        alloc,
                        &content,
                        text.string,
                        callback_ctx,
                        on_content_chunk,
                        content_capture_limit,
                    );
                }
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
            const delta = parsed.value.object.get("delta") orelse continue;
            if (delta != .object) continue;
            const delta_type = delta.object.get("type") orelse continue;
            if (delta_type != .string) continue;
            if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                if (delta.object.get("text")) |text| {
                    if (text == .string) try appendContentChunk(
                        alloc,
                        &content,
                        text.string,
                        callback_ctx,
                        on_content_chunk,
                        content_capture_limit,
                    );
                }
            } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                if (on_reasoning_chunk) |callback| {
                    if (delta.object.get("thinking")) |thinking| {
                        if (thinking == .string and thinking.string.len > 0) callback(callback_ctx, thinking.string);
                    }
                }
            } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
                const index = jsonIndex(parsed.value.object.get("index") orelse continue) orelse continue;
                const partial = delta.object.get("partial_json") orelse continue;
                if (partial != .string or partial.string.len == 0) continue;
                const tool = try ensureToolAccumulator(alloc, &tools, index);
                try tool.arguments.appendSlice(alloc, partial.string);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, partial.string);
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "message_delta")) {
            if (parsed.value.object.get("usage")) |usage_value| captureAnthropicUsageValue(usage_value, &usage);
            if (parsed.value.object.get("delta")) |delta| {
                if (delta == .object) {
                    if (delta.object.get("stop_reason")) |reason| {
                        if (reason == .string) finish_reason = parseAnthropicFinishReason(reason.string);
                    }
                }
            }
            continue;
        }
        if (std.mem.eql(u8, event_type.string, "message_stop")) break;
        if (std.mem.eql(u8, event_type.string, "error")) return error.ProviderStreamError;
    }

    var completion: types.GatewayCompletion = .{};
    errdefer deinitCompletion(alloc, &completion);
    if (content.items.len > 0) completion.content = try alloc.dupe(u8, content.items);
    completion.tool_calls = try materializeToolCalls(alloc, tools.items, callback_ctx, on_tool_start);
    completion.finish_reason = finish_reason orelse if (completion.tool_calls.len > 0) .tool_calls else .stop;
    completion.usage = usage;
    return completion;
}

fn appendContentChunk(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    chunk: []const u8,
    callback_ctx: *anyopaque,
    callback: agent_stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    if (chunk.len == 0) return;
    const remaining = if (content_capture_limit) |limit| limit -| content.items.len else chunk.len;
    try content.appendSlice(alloc, chunk[0..@min(chunk.len, remaining)]);
    callback(callback_ctx, chunk);
}

fn ensureToolAccumulator(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    index: usize,
) !*ToolAccumulator {
    while (tools.items.len <= index) try tools.append(alloc, .{});
    return &tools.items[index];
}

fn jsonIndex(value: std.json.Value) ?usize {
    const integer = nonNegativeInteger(value) orelse return null;
    return std.math.cast(usize, integer);
}

fn captureAnthropicUsage(message: std.json.Value, usage: *types.Usage) void {
    if (message != .object) return;
    const usage_value = message.object.get("usage") orelse return;
    captureAnthropicUsageValue(usage_value, usage);
}

fn captureAnthropicUsageValue(usage_value: std.json.Value, usage: *types.Usage) void {
    if (usage_value != .object) return;
    if (usage_value.object.get("input_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.input_tokens = tokens;
    }
    if (usage_value.object.get("output_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.output_tokens = tokens;
    }
}

fn parseAnthropicFinishReason(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "end_turn") or std.mem.eql(u8, raw, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, raw, "max_tokens") or std.mem.eql(u8, raw, "model_context_window_exceeded")) return .length;
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "refusal")) return .content_filter;
    return .other;
}

fn consumeToolDelta(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    value: std.json.Value,
    callback_ctx: *anyopaque,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
) !void {
    if (value != .object) return;
    const index_value = value.object.get("index") orelse return;
    if (index_value != .integer or index_value.integer < 0) return;
    const index: usize = std.math.cast(usize, index_value.integer) orelse return;
    while (tools.items.len <= index) try tools.append(alloc, .{});
    const tool = &tools.items[index];

    if (value.object.get("id")) |id| {
        if (id == .string and id.string.len > 0) try appendDelta(alloc, &tool.id, id.string);
    }
    if (value.object.get("function")) |function| {
        if (function == .object) {
            if (function.object.get("name")) |name| {
                if (name == .string and name.string.len > 0) try appendDelta(alloc, &tool.name, name.string);
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments == .string and arguments.string.len > 0) {
                    try tool.arguments.appendSlice(alloc, arguments.string);
                    if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments.string);
                }
            }
        }
    }
    maybeStartTool(tool, callback_ctx, on_tool_start);
}

fn appendDelta(alloc: Allocator, destination: *std.ArrayList(u8), value: []const u8) !void {
    if (destination.items.len == 0) {
        try destination.appendSlice(alloc, value);
    } else if (!std.mem.eql(u8, destination.items, value) and
        !std.mem.startsWith(u8, value, destination.items))
    {
        try destination.appendSlice(alloc, value);
    } else if (std.mem.startsWith(u8, value, destination.items)) {
        try destination.appendSlice(alloc, value[destination.items.len..]);
    }
}

fn maybeStartTool(
    tool: *ToolAccumulator,
    callback_ctx: *anyopaque,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
) void {
    if (tool.started or tool.id.items.len == 0 or tool.name.items.len == 0) return;
    tool.started = true;
    if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
}

fn materializeToolCalls(
    alloc: Allocator,
    accumulators: []ToolAccumulator,
    callback_ctx: *anyopaque,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
) ![]const types.ToolCall {
    var count: usize = 0;
    for (accumulators) |tool| {
        if (tool.name.items.len > 0) count += 1;
    }
    if (count == 0) return &.{};

    const calls = try alloc.alloc(types.ToolCall, count);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |call| types.freeToolCall(alloc, call);
        alloc.free(calls);
    }
    for (accumulators, 0..) |*tool, index| {
        if (tool.name.items.len == 0) continue;
        if (tool.id.items.len == 0) {
            const generated = try std.fmt.allocPrint(alloc, "call_{d}", .{index});
            defer alloc.free(generated);
            try tool.id.appendSlice(alloc, generated);
        }
        maybeStartTool(tool, callback_ctx, on_tool_start);

        const raw_arguments = if (tool.arguments.items.len > 0) tool.arguments.items else "{}";
        const integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, raw_arguments);
        const id = try alloc.dupe(u8, tool.id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, tool.name.items);
        errdefer alloc.free(name);
        const arguments_json = try alloc.dupe(
            u8,
            if (integrity == .valid) raw_arguments else "{}",
        );
        errdefer alloc.free(arguments_json);
        calls[initialized] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments_json,
            .argument_integrity = integrity,
        };
        initialized += 1;
    }
    return calls;
}

fn captureUsage(root: std.json.Value, usage: *types.Usage) void {
    const usage_value = root.object.get("usage") orelse return;
    if (usage_value != .object) return;
    if (usage_value.object.get("prompt_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.input_tokens = tokens;
    }
    if (usage_value.object.get("completion_tokens")) |value| {
        if (nonNegativeInteger(value)) |tokens| usage.output_tokens = tokens;
    }
}

fn nonNegativeInteger(value: std.json.Value) ?u64 {
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(u64, value.integer);
}

fn parseFinishReason(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    return .other;
}

const SseEvent = union(enum) {
    data: []const u8,
    done,
    ignored,
    read_failed,
    eof,
};

const SseLineReader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn releaseLine(self: *@This()) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *@This(), alloc: Allocator, reader: anytype) !SseEvent {
        const line = switch (try self.readLine(alloc, reader)) {
            .line => |line| line,
            .read_failed => return .read_failed,
            .eof => return .eof,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == ':') return .ignored;
        if (!std.mem.startsWith(u8, trimmed, "data:")) return .ignored;
        const data = std.mem.trimStart(u8, trimmed["data:".len..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) return .done;
        return .{ .data = data };
    }

    const Line = union(enum) {
        line: []const u8,
        read_failed,
        eof,
    };

    fn readLine(self: *@This(), alloc: Allocator, reader: anytype) !Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAiSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAiSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAiSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

fn deinitCompletion(alloc: Allocator, completion: *types.GatewayCompletion) void {
    if (completion.content) |content| alloc.free(@constCast(content));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    completion.* = .{};
}

pub fn catalogFromEnvironment(alloc: Allocator, fallback_model: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);

    const configured = io_mod.getenv(model_env) orelse fallback_model;
    const model = std.mem.trim(u8, configured, " \t\r\n");
    try appendCatalogEntry(alloc, &entries, if (model.len > 0) model else fallback_model);
    return entries;
}

fn appendCatalogEntry(
    alloc: Allocator,
    entries: *std.ArrayList(model_catalog.ModelCatalogEntry),
    model: []const u8,
) !void {
    const id = try alloc.dupe(u8, model);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    try entries.append(alloc, .{
        .id = id,
        .model_type = model_type,
        .has_tool_use = true,
        .has_vision = true,
        .has_file_input = true,
        .context_window = 128_000,
        .max_tokens = 32_000,
    });
}

test "direct provider endpoint validation and protocol selection are strict" {
    try validateEndpointUrl("https://api.openai.com/v1/chat/completions");
    try validateEndpointUrl("http://127.0.0.1:11434/v1/responses");
    try validateEndpointUrl("http://localhost:1234/v1/messages");
    try std.testing.expectError(error.InsecureEndpoint, validateEndpointUrl("http://example.com/v1/chat/completions"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpointUrl("https://user:pass@example.com/v1/chat/completions"));
    try std.testing.expectEqual(Protocol.openai_chat_completions, try protocolForUrl("https://example.com/v1/chat/completions"));
    try std.testing.expectEqual(Protocol.openai_responses, try protocolForUrl("https://example.com/v1/responses?trace=true"));
    try std.testing.expectEqual(Protocol.anthropic_messages, try protocolForUrl("http://localhost:8321/v1/messages/"));
    try std.testing.expectError(error.UnsupportedDirectProviderEndpoint, protocolForUrl("https://example.com/v1/completions"));
}

test "OpenAI-compatible request converts messages and flattened tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are concise." },
        .{ .role = .user, .content = "Read a file." },
    };
    const body = try buildAgentRequestForProtocol(
        std.testing.allocator,
        .{
            .model = "local/test-model",
            .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}]",
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
        },
        .openai_chat_completions,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("local/test-model", parsed.value.object.get("model").?.string);
    try std.testing.expect(parsed.value.object.get("stream").?.bool);
    const tool = parsed.value.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("read_file", tool.object.get("function").?.object.get("name").?.string);
    try std.testing.expect(tool.object.get("function").?.object.get("parameters") != null);
}

test "Responses request converts history tools and tool results" {
    const calls = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are concise." },
        .{ .role = .user, .content = "Read a file." },
        .{ .role = .assistant, .content = "I will read it.", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildAgentRequestForProtocol(
        std.testing.allocator,
        .{
            .model = "local/responses-model",
            .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}]",
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
        },
        .openai_responses,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), input.len);
    try std.testing.expectEqualStrings("function_call", input[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[4].object.get("type").?.string);
    const tool = parsed.value.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("read_file", tool.object.get("name").?.string);
    try std.testing.expect(tool.object.get("function") == null);
    try std.testing.expect(parsed.value.object.get("messages") == null);
}

test "Anthropic request converts system tools and tool results" {
    const calls = [_]types.ToolCall{.{
        .id = "toolu_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are concise." },
        .{ .role = .user, .content = "Read a file." },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .tool_name = "read_file", .content = "contents", .tool_result_status = .success },
    };
    const body = try buildAgentRequestForProtocol(
        std.testing.allocator,
        .{
            .model = "claude-local",
            .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}]",
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
            .max_output_tokens = 4096,
        },
        .anthropic_messages,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("You are concise.", parsed.value.object.get("system").?.string);
    try std.testing.expectEqual(@as(i64, 4096), parsed.value.object.get("max_tokens").?.integer);
    const messages_json = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("tool_use", messages_json[1].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_result", messages_json[2].object.get("content").?.array.items[0].object.get("type").?.string);
    const tool = parsed.value.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("read_file", tool.object.get("name").?.string);
    try std.testing.expect(tool.object.get("input_schema") != null);
}

test "OpenAI-compatible stream accumulates text tools and usage" {
    const payload =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":7}}\n\n" ++
        "data: [DONE]\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Capture = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };
    var marker: u8 = 0;
    var completion = try consumeOpenAiSseStream(
        std.testing.allocator,
        &reader,
        @ptrCast(&marker),
        Capture.content,
        null,
        null,
        null,
        &cancel,
        null,
    );
    defer deinitCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("Hello ", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.output_tokens);
}

test "Responses stream accumulates text tools and usage" {
    const payload =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello \"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":14,\"output_tokens\":9}}}\n\n" ++
        "data: [DONE]\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Capture = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };
    var marker: u8 = 0;
    var completion = try consumeResponsesSseStream(
        std.testing.allocator,
        &reader,
        @ptrCast(&marker),
        Capture.content,
        null,
        null,
        null,
        &cancel,
        null,
    );
    defer deinitCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("Hello ", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 14), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 9), completion.usage.output_tokens);
}

test "Anthropic stream accumulates text tools and usage" {
    const payload =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":18,\"output_tokens\":1}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":11}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Capture = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };
    var marker: u8 = 0;
    var completion = try consumeAnthropicSseStream(
        std.testing.allocator,
        &reader,
        @ptrCast(&marker),
        Capture.content,
        null,
        null,
        null,
        &cancel,
        null,
    );
    defer deinitCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("Hello ", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 18), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 11), completion.usage.output_tokens);
}
