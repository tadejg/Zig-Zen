//! Servers and clients can register their sockets with the I/O reactor to get notified when an event occurs. If
//! concurrency is required, a separate reactor instance should be created for each thread and servers that wish to
//! utilize concurrency should open and register a new listening socket for each reactor instance with the SO_REUSEPORT
//! socket option set
const std = @import("std");
const Socket = @import("socket.zig");
const Epoll = @import("epoll.zig");

const Self = @This();
const EVENT_QUEUE_LEN = 128;
const ASYNC_TASK_QUEUE_LEN = 128;
const ASYNC_TASK_ARGS_BYTES = 128;

pub const Handler = struct {
    extra: ?*anyopaque,
    callback: Callback,

    pub const Callback = *const fn (extra: ?*anyopaque, event: Event) void;

    pub const Event = enum {
        read,
        write,
        hangup,
        err,
        future_completed,
        future_failed,
    };
};

pub const IoEvent = struct {
    kind: Handler.Event,
    handler: *Handler,
};

const AsyncContext = struct {
    reactor: *Self,
    handler: *Handler,
};

pub const AsyncTask = struct {
    pub const CTX_BYTES = @sizeOf(AsyncContext) + ASYNC_TASK_ARGS_BYTES;
    context: [CTX_BYTES]u8 = [_]u8{undefined} ** CTX_BYTES,
    contextLen: usize = 0,
    contextAlignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) std.Io.Cancelable!void,
};

io: std.Io,
ioGroup: *std.Io.Group,
eventsInit: bool = false,
eventQueueBuffer: [EVENT_QUEUE_LEN]IoEvent = [_]IoEvent{undefined} ** EVENT_QUEUE_LEN,
events: std.Io.Queue(IoEvent) = undefined,
asyncTasksInit: bool = false,
asyncTasksQueueBuffer: [ASYNC_TASK_QUEUE_LEN]AsyncTask = [_]AsyncTask{undefined} ** ASYNC_TASK_QUEUE_LEN,
asyncTasks: std.Io.Queue(AsyncTask) = undefined,
epoll: Epoll,
epollDoneSignal: std.Thread.Semaphore = .{},
eventDoneSignal: std.Thread.Semaphore = .{},
asyncDoneSignal: std.Thread.Semaphore = .{},

pub const InitError = Epoll.InitError;

pub fn init(io: std.Io, ioGroup: *std.Io.Group) InitError!Self {
    var epoll = try Epoll.init();
    errdefer epoll.deinit();
    return .{
        .io = io,
        .ioGroup = ioGroup,
        .epoll = epoll,
    };
}

pub fn deinit(self: *Self) void {
    self.epoll.notify() catch {
        // TODO Log
    };
    self.epollDoneSignal.timedWait(3 * std.time.ns_per_s) catch {};
    if (self.asyncTasksInit) { // Don't touch the futures queue, if it hasn't been initialized yet
        self.asyncTasks.close(self.io);
        self.asyncDoneSignal.timedWait(3 * std.time.ns_per_s) catch {};
    }
    // TODO can we wait for events to drain (with a timeout)?
    if (self.eventsInit) { // Don't touch the events queue, if it hasn't been initialized yet
        self.events.close(self.io);
        self.eventDoneSignal.timedWait(3 * std.time.ns_per_s) catch {};
    }
    self.epoll.deinit();
}

pub const StartError = std.Io.ConcurrentError;

pub fn start(self: *Self) StartError!void {
    self.events = .init(&self.eventQueueBuffer);
    self.eventsInit = true;
    self.asyncTasks = .init(&self.asyncTasksQueueBuffer);
    self.asyncTasksInit = true;
    try self.ioGroup.concurrent(self.io, Self.runEpoll, .{self});
    try self.ioGroup.concurrent(self.io, Self.runAsyncTasks, .{self});
    try self.ioGroup.concurrent(self.io, Self.runEvents, .{self});
}

pub const AddSocketError = Epoll.AddFdError;

/// Handler ptr must remain stable until removeSocket() is called
pub fn addSocket(self: *Self, socket: Socket, handler: *Handler) AddSocketError!void {
    try self.epoll.addFd(socket.fd, @intFromPtr(handler));
}

pub const RemoveSocketError = Epoll.RemoveFdError;

pub fn removeSocket(self: *Self, socket: Socket) RemoveSocketError!void {
    try self.epoll.removeFd(socket.fd);
}

pub const WriteModeError = Epoll.WriteModeError;

/// Sets the socket into write mode; handler will receive write readiness notifications instead of read notifications
/// Handler ptr must be the same as in the call to addSocket()
pub fn writeMode(self: *Self, socket: Socket, handler: *Handler) WriteModeError!void {
    try self.epoll.writeMode(socket.fd, @intFromPtr(handler));
}

pub const ReadModeError = Epoll.ReadModeError;

/// Sets the socket into read mode; handler will receive read readiness notifications instead of write notifications
/// Handler ptr must be the same as in the call to addSocket()
pub fn readMode(self: *Self, socket: Socket, handler: *Handler) ReadModeError!void {
    try self.epoll.readMode(socket.fd, @intFromPtr(handler));
}

pub const AsyncError = std.Io.QueueClosedError || std.Io.Cancelable;

/// Runs the function asynchronously, guaranteed to run concurrent to the reactor event task, making it suitable for
/// tasks which need to wait for reactor events e.g. request handlers which write as much data as fits in the buffer,
/// then wait for the write event before continuing
/// Handler ptr must remain stable until the future event is received
pub fn async(
    self: *Self,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    handler: *Handler,
) AsyncError!void {
    const Context = struct {
        base: AsyncContext,
        args: @TypeOf(args),
        fn start(ctx: *const anyopaque) std.Io.Cancelable!void {
            const context: *const @This() = @ptrCast(@alignCast(ctx));
            const result = @call(.auto, function, context.args);
            context.base.reactor.events.putOneUncancelable(
                context.base.reactor.io,
                .{
                    .kind = if (std.meta.isError(result)) .future_failed else .future_completed,
                    .handler = context.base.handler,
                },
            ) catch |e| switch (e) {
                error.Closed => unreachable,
            };
        }
    };
    comptime if (@sizeOf(Context) > AsyncTask.CTX_BYTES) {
        @compileError("Async context doesn't fit into the reserved buffer; Reduce the byte size of the argument list");
    };
    const context: Context = .{
        .base = .{
            .reactor = self,
            .handler = handler,
        },
        .args = args,
    };
    var task: AsyncTask = .{
        .contextLen = @sizeOf(Context),
        .contextAlignment = .of(Context),
        .start = Context.start,
    };
    @memcpy(task.context[0..@sizeOf(Context)], @as([]const u8, @ptrCast(&context)));
    try self.asyncTasks.putOne(self.io, task);
}

fn runEpoll(self: *Self) void {
    var running = true;
    outer: while (running) {
        const events = self.epoll.wait(-1);
        for (events) |event| {
            if (event.data.ptr == Epoll.NOTIFY_SIGNAL_PTR) {
                running = false;
            } else {
                const handler: *Handler = @ptrFromInt(event.data.ptr);
                if ((event.events & std.os.linux.EPOLL.IN) > 0) {
                    self.events.putOneUncancelable(self.io, .{ .kind = .read, .handler = handler }) catch {
                        running = false;
                        continue :outer;
                    };
                }
                if ((event.events & std.os.linux.EPOLL.OUT) > 0) {
                    self.events.putOneUncancelable(self.io, .{ .kind = .write, .handler = handler }) catch {
                        running = false;
                        continue :outer;
                    };
                }
                if ((event.events & std.os.linux.EPOLL.HUP) > 0) {
                    self.events.putOneUncancelable(self.io, .{ .kind = .hangup, .handler = handler }) catch {
                        running = false;
                        continue :outer;
                    };
                }
                if ((event.events & std.os.linux.EPOLL.ERR) > 0) {
                    self.events.putOneUncancelable(self.io, .{ .kind = .err, .handler = handler }) catch {
                        running = false;
                        continue :outer;
                    };
                }
            }
        }
    }
    std.log.info("Epoll reactor shutdown", .{});
    self.epollDoneSignal.post();
}

/// All futures started with a call to async() are executed in this concurrent task, if the underlying I/O is out of
/// concurrent units to assign
fn runAsyncTasks(self: *Self) void {
    var running = true;
    while (running) {
        const task = self.asyncTasks.getOne(self.io) catch {
            running = false;
            continue;
        };
        // Either assigns a unit of concurrency or runs synchronously in this task
        self.io.vtable.groupAsync(
            self.io.userdata,
            self.ioGroup,
            task.context[0..task.contextLen],
            task.contextAlignment,
            task.start,
        );
    }
    std.log.info("Future reactor shutdown", .{});
    self.asyncDoneSignal.post();
}

fn runEvents(self: *Self) void {
    var running = true;
    while (running) {
        const event = self.events.getOne(self.io) catch {
            running = false;
            continue;
        };
        event.handler.callback(event.handler.extra, event.kind);
    }
    std.log.info("Reactor shutdown", .{});
    self.eventDoneSignal.post();
}
