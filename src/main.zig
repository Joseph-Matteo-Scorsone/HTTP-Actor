const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const http = std.http;

const InkList_lib = @import("InkList_lib");
const Engine = InkList_lib.Engine;
const Message = InkList_lib.Message;

const ActorServer = struct {
    const Self = @This();

    allocator: Allocator,
    address: ?net.Address,
    server: ?net.Server,

    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .address = null,
            .server = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |*server| {
            server.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn init_server(self: *Self, port: u16) !void {
        self.address = net.Address.parseIp4("127.0.0.1", port) catch |err| {
            return err;
        };

        if (self.address) |addr| {
            self.server = try addr.listen(.{});
        }
    }

    pub fn receive(self: *Self, allocator: Allocator, msg: *Message) void {
        _ = allocator;
        // Every time we get a custom payload, increment the counter.
        switch (msg.instruction) {
            .custom => |_| {
                // handle
            },
            .func => |f| {
                // For handler payloads, call the handler's function:
                f.call_fn(f.context, @ptrCast(self));
            },
        }
    }

    pub fn start_server(self: *Self) void {
        if (self.server == null) {
            return;
        }

        while (true) {
            var connection = self.server.?.accept() catch {
                continue;
            };
            defer connection.stream.close();

            var read_buffer: [1024]u8 = undefined;
            var http_server = http.Server.init(connection, &read_buffer);

            var request = http_server.receiveHead() catch {
                continue;
            };

            handle_request(&request) catch {
                continue;
            };
        }
    }

    pub fn handle_request(request: *http.Server.Request) !void {
        std.debug.print("Handling request for {s}\n", .{request.head.target});
        try request.respond("Hello http!\n", .{});
    }
};

const ActorServerContext = struct {
    const Self = @This();
    port: u16,

    pub fn init(allocator: Allocator, port: u16) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .port = port,
        };
        return self;
    }

    pub fn deinit(ctx: *anyopaque, allocator: Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }

    pub fn clone(ctx: *anyopaque, allocator: Allocator) !*anyopaque {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const new_ctx = try Self.init(allocator, self.port);
        return @ptrCast(new_ctx);
    }

    pub fn handleInit(ctx: *anyopaque, actor: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const server: *ActorServer = @ptrCast(@alignCast(actor));
        server.init_server(self.port) catch |err| {
            std.debug.print("Failed to initialize server: {}\n", .{err});
            unreachable;
        };
    }

    pub fn handleStart(ctx: *anyopaque, actor: *anyopaque) void {
        _ = ctx;
        const server: *ActorServer = @ptrCast(@alignCast(actor));
        server.start_server();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const server = try engine.spawnActor(ActorServer);

    const ctx = try ActorServerContext.init(allocator, 8080);

    const init_msg = try Message.makeFuncPayload(allocator, server, ActorServerContext.handleInit, ctx, ActorServerContext.deinit, ActorServerContext.clone);
    try engine.sendMessage(server, init_msg);

    // sync everything
    std.time.sleep(100 * std.time.ns_per_ms);

    const server_state = try engine.getActorState(ActorServer, server);
    if (server_state.address) |addr| {
        std.debug.print("Server listening on port: {d}\n", .{addr.getPort()});
    } else {
        std.debug.print("Server address is not set!\n", .{});
        return error.ServerNotInitialized;
    }

    const start_msg = try Message.makeFuncPayload(allocator, server, ActorServerContext.handleStart, ctx, ActorServerContext.deinit, ActorServerContext.clone);
    try engine.sendMessage(server, start_msg);

    try engine.waitForActor(server);
}
