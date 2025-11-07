const httpz = @import("httpz");
const module_config = @import("zx_info");

pub const App = struct {
    pub const Meta = struct {
        pub const Route = struct {
            path: []const u8,
            page: *const fn (allocator: Allocator, params: ?zx.RouteParams) Component,
            layout: ?*const fn (allocator: Allocator, component: Component) Component = null,
            routes: ?[]const Route = null,
        };
        routes: []const Route,
    };
    pub const Config = struct {
        server: httpz.Config,
        meta: *const Meta,
    };

    const Handler = struct {
        meta: *const App.Meta,

        pub fn handle(self: *Handler, req: *httpz.Request, res: *httpz.Response) void {
            const allocator = req.arena;
            const path = req.url.path;
            const writer = &res.buffer.writer;

            const request_path = normalizePath(allocator, path) catch {
                res.body = "Internal Server Error";
                return;
            };

            const empty_layouts: []const *const fn (allocator: Allocator, component: Component) Component = &.{};

            for (self.meta.routes) |route| {
                const rendered = matchRoute(request_path, route, empty_layouts, allocator, writer) catch {
                    res.body = "Internal Server Error";
                    return;
                };
                if (rendered) {
                    return;
                }
            }

            res.body = "Not found";
        }
    };

    pub const version = module_config.version_string;
    pub const info = std.fmt.comptimePrint("\x1b[1mZX\x1b[0m \x1b[2m· {s}\x1b[0m", .{version});

    allocator: std.mem.Allocator,
    meta: *const Meta,
    handler: Handler,
    server: httpz.Server(*Handler),

    pub fn init(allocator: std.mem.Allocator, config: Config) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        app.allocator = allocator;
        app.meta = config.meta;
        app.handler = Handler{ .meta = config.meta };
        app.server = try httpz.Server(*Handler).init(allocator, config.server, &app.handler);

        return app;
    }

    pub fn deinit(self: *App) void {
        const allocator = self.allocator;
        self.server.stop();
        self.server.deinit();
        allocator.destroy(self);
    }

    pub fn start(self: *App) !void {
        try self.server.listen();
    }

    /// Check if a path segment is a dynamic parameter (enclosed in square brackets)
    fn isDynamicParam(segment: []const u8) bool {
        return segment.len > 2 and segment[0] == '[' and segment[segment.len - 1] == ']';
    }

    /// Extract parameter name from a dynamic segment (e.g., "[id]" -> "id")
    fn getParamName(segment: []const u8) []const u8 {
        if (isDynamicParam(segment)) {
            return segment[1 .. segment.len - 1];
        }
        return segment;
    }

    /// Match a route path against a request path, extracting parameters if it's a dynamic route
    fn matchAndExtractParams(
        allocator: std.mem.Allocator,
        route_path: []const u8,
        request_path: []const u8,
    ) !?zx.RouteParams {
        // Split both paths into segments, skipping empty segments from leading slashes
        var route_it = std.mem.tokenizeScalar(u8, route_path, '/');
        var request_it = std.mem.tokenizeScalar(u8, request_path, '/');

        // Create a hash map to store parameters
        var params = zx.RouteParams.init(allocator);
        errdefer params.deinit();

        while (route_it.next()) |route_segment| {
            const request_segment = request_it.next() orelse {
                // Request path has fewer segments than route path
                return null;
            };

            if (isDynamicParam(route_segment)) {
                // This is a dynamic parameter, extract the value
                const param_name = getParamName(route_segment);
                try params.put(param_name, request_segment);
            } else {
                // This is a static segment, must match exactly
                if (!std.mem.eql(u8, route_segment, request_segment)) {
                    return null;
                }
            }
        }

        // Ensure request path doesn't have more segments than route path
        if (request_it.next() != null) {
            return null;
        }

        return params;
    }

    fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Remove trailing slash unless it's the root path
        if (path.len > 1 and path[path.len - 1] == '/') {
            return try allocator.dupe(u8, path[0 .. path.len - 1]);
        }
        return path;
    }

    fn matchRoute(
        request_path: []const u8,
        route: App.Meta.Route,
        parent_layouts: []const *const fn (allocator: Allocator, component: Component) Component,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !bool {
        const normalized_route_path = normalizePath(allocator, route.path) catch return false;

        // Check if this route matches the request path and extract parameters
        if (try matchAndExtractParams(allocator, normalized_route_path, request_path)) |params_map_const| {
            var params_map = params_map_const;
            // Route matches with parameters extracted
            var page = route.page(allocator, params_map);

            // Apply all parent layouts first (in order from root to here)
            for (parent_layouts) |layout| {
                page = layout(allocator, page);
            }

            // Apply this route's own layout last
            if (route.layout) |layout| {
                page = layout(allocator, page);
            }

            _ = writer.write("<!DOCTYPE html>\n") catch |err| {
                std.debug.print("Error writing HTML: {}\n", .{err});
                return true;
            };
            page.render(writer) catch |err| {
                std.debug.print("Error rendering page: {}\n", .{err});
                return true;
            };
            
            // Clean up the params map
            params_map.deinit();
            return true;
        }

        // Simple exact match as fallback
        if (std.mem.eql(u8, request_path, normalized_route_path)) {
            var page = route.page(allocator, null);

            // Apply all parent layouts first (in order from root to here)
            for (parent_layouts) |layout| {
                page = layout(allocator, page);
            }

            // Apply this route's own layout last
            if (route.layout) |layout| {
                page = layout(allocator, page);
            }

            _ = writer.write("<!DOCTYPE html>\n") catch |err| {
                std.debug.print("Error writing HTML: {}\n", .{err});
                return true;
            };
            page.render(writer) catch |err| {
                std.debug.print("Error rendering page: {}\n", .{err});
                return true;
            };
            return true;
        }

        // Check sub-routes if they exist
        if (route.routes) |sub_routes| {
            // Build the layout chain for sub-routes
            // We need to accumulate parent_layouts + current route's layout (if it exists)
            var layouts_buffer: [10]*const fn (allocator: Allocator, component: Component) Component = undefined;
            var layouts_count: usize = 0;

            // Copy all parent layouts
            for (parent_layouts) |layout| {
                layouts_buffer[layouts_count] = layout;
                layouts_count += 1;
            }

            // Add current route's layout if it exists
            if (route.layout) |layout| {
                layouts_buffer[layouts_count] = layout;
                layouts_count += 1;
            }

            const layouts_to_pass = layouts_buffer[0..layouts_count];

            for (sub_routes) |sub_route| {
                const matched = try matchRoute(request_path, sub_route, layouts_to_pass, allocator, writer);
                if (matched) {
                    return true;
                }
            }
        }

        return false;
    }
};

const std = @import("std");
const zx = @import("root.zig");
const Allocator = std.mem.Allocator;
const Component = zx.Component;
