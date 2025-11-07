pub const ParseResult = struct {
    zig_ast: std.zig.Ast,
    zx_source: [:0]const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        self.zig_ast.deinit(allocator);
        allocator.free(self.zx_source);
        allocator.free(self.zig_source);
    }
};

pub fn parse(allocator: std.mem.Allocator, zx_source: [:0]const u8) !ParseResult {
    var zig_source = try Transpiler.transpile(allocator, zx_source);
    errdefer allocator.free(zig_source);

    zig_source = try ensurePageEntryPoint(allocator, zig_source);

    // std.debug.print("Transpiled ZX source:\n{s}\n", .{zig_source});

    const ast = try std.zig.Ast.parse(allocator, zig_source, .zig);

    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            var w: std.io.Writer.Allocating = .init(allocator);
            defer w.deinit();
            try ast.renderError(err, &w.writer);
            std.debug.print("{s}\n", .{w.written()});
        }
        return error.ParseError;
    }

    const rendered_zig_source = try ast.renderAlloc(allocator);
    const rendered_zig_source_z = try allocator.dupeZ(u8, rendered_zig_source);
    defer allocator.free(rendered_zig_source);
    errdefer allocator.free(rendered_zig_source_z);

    return ParseResult{
        .zig_ast = ast,
        .zx_source = zig_source,
        .zig_source = rendered_zig_source_z,
    };
}

const std = @import("std");
const Transpiler = @import("Transpiler_prototype.zig");

const whitespace = " \t\n\r";

const PageParamMode = enum {
    legacy,
    context,
    none,
    unsupported,
};

fn ensurePageEntryPoint(allocator: std.mem.Allocator, zig_source: [:0]const u8) ![:0]const u8 {
    const bytes = zig_source[0..zig_source.len];
    const pattern = "pub fn Page";
    const start_index_opt = std.mem.indexOf(u8, bytes, pattern) orelse return zig_source;
    const start_index = start_index_opt;
    const after_pattern = start_index + pattern.len;

    var cursor = after_pattern;
    while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) {
        cursor += 1;
    }

    if (cursor >= bytes.len or bytes[cursor] != '(') {
        return zig_source;
    }

    const params_start = cursor + 1;
    var depth: usize = 1;
    var params_end: ?usize = null;
    var i = params_start;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    params_end = i;
                    break;
                }
            },
            else => {},
        }
    }

    if (params_end == null) {
        return zig_source;
    }

    const params_slice = bytes[params_start..params_end.?];
    const trimmed = std.mem.trim(u8, params_slice, whitespace);

    const mode = detectParamMode(trimmed);
    if (mode == .legacy) {
        return zig_source;
    }
    if (mode == .unsupported) {
        return zig_source;
    }

    const brace_index = findNextBrace(bytes, params_end.? + 1) orelse return zig_source;
    const body_insert_index = brace_index + 1;

    var builder = std.ArrayList(u8){};
    defer builder.deinit(allocator);

    const insert_index = start_index + pattern.len;
    try builder.appendSlice(allocator, bytes[0..insert_index]);
    try builder.appendSlice(allocator, "__impl");
    try builder.appendSlice(allocator, bytes[insert_index..body_insert_index]);

    if (mode == .context) {
        const param_name = extractParamName(trimmed) orelse return zig_source;
        try builder.appendSlice(allocator, "\n    const allocator = ");
        try builder.appendSlice(allocator, param_name);
        try builder.appendSlice(allocator, ".allocator;\n");
    } else if (mode == .none) {
        try builder.appendSlice(allocator, "\n    const allocator = zx.usePageAllocator();\n");
    }

    try builder.appendSlice(allocator, bytes[body_insert_index..]);
    try builder.appendSlice(allocator, "\n\n");

    try builder.appendSlice(
        allocator,
        \\pub fn Page(allocator: zx.Allocator, params: ?zx.RouteParams) zx.Component {
        \\    var ctx = zx.createPageContext(allocator, params);
        \\    zx.setActivePageContext(&ctx);
        \\    defer zx.clearActivePageContext();
    );

    switch (mode) {
        .context => {
            try builder.appendSlice(
                allocator,
                \\    return Page__impl(ctx);
                \\
            );
        },
        .none => {
            try builder.appendSlice(
                allocator,
                \\    return Page__impl();
                \\
            );
        },
        else => unreachable,
    }

    try builder.appendSlice(
        allocator,
        \\}
        \\
    );

    const new_bytes = try builder.toOwnedSlice(allocator);
    defer allocator.free(new_bytes);

    const duplicated = try allocator.dupeZ(u8, new_bytes);
    allocator.free(zig_source[0 .. zig_source.len + 1]);
    return duplicated;
}

fn findNextBrace(bytes: []const u8, start: usize) ?usize {
    var idx = start;
    while (idx < bytes.len) : (idx += 1) {
        if (bytes[idx] == '{') return idx;
    }
    return null;
}

fn extractParamName(params: []const u8) ?[]const u8 {
    const colon_index = std.mem.indexOfScalar(u8, params, ':') orelse return null;
    return std.mem.trim(u8, params[0..colon_index], whitespace);
}

fn detectParamMode(params: []const u8) PageParamMode {
    if (std.mem.indexOf(u8, params, "zx.Allocator") != null or
        std.mem.indexOf(u8, params, "std.mem.Allocator") != null or
        std.mem.indexOf(u8, params, "StringArrayHashMap") != null)
    {
        return .legacy;
    }
    if (std.mem.indexOf(u8, params, "zx.PageContext") != null) {
        return .context;
    }
    if (params.len == 0) {
        return .none;
    }
    return .unsupported;
}
