const std = @import("std");
const json = std.json;
const jsonrpc = @import("jsonrpc.zig");

pub const PendingRegistry = struct {
    pub const Outcome = union(enum) {
        result: json.Value,
        failed: void,
        connection_closed: void,
    };

    pub const Pending = struct {
        queue: std.Io.Queue(Outcome),
        buf: [1]Outcome = undefined,

        pub fn init(p: *Pending) void {
            p.queue = std.Io.Queue(Outcome).init(p.buf[0..]);
        }

        pub fn wait(p: *Pending, io: std.Io) (std.Io.QueueClosedError || std.Io.Cancelable)!Outcome {
            return p.queue.getOne(io);
        }

        pub fn signalUncancelable(p: *Pending, io: std.Io, outcome: Outcome) void {
            p.queue.putOneUncancelable(io, outcome) catch {};
        }
    };

    /// Ref-counted holder for a `Pending` queue.
    /// One reference is held by the registry while the entry is in the map,
    /// and one reference is held by the waiting caller.
    pub const SharedPending = struct {
        ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
        pending: Pending = undefined,

        pub fn init(sp: *SharedPending) void {
            sp.ref_count = std.atomic.Value(u32).init(2);
            sp.pending.init();
        }

        pub fn release(sp: *SharedPending, allocator: std.mem.Allocator, io: std.Io) void {
            if (sp.ref_count.fetchSub(1, .acq_rel) != 1) return;

            // Last reference: close and drain any undelivered outcome to avoid leaks.
            sp.pending.queue.close(io);
            while (true) {
                const outcome = sp.pending.queue.getOneUncancelable(io) catch break;
                switch (outcome) {
                    .result => |v| jsonrpc.Message.freeValue(allocator, v),
                    else => {},
                }
            }
            allocator.destroy(sp);
        }
    };

    pub const BorrowedId = union(enum) {
        number: i64,
        string: []const u8,
    };

    pub const StoredId = union(enum) {
        number: i64,
        string: []u8, // owned by registry

        pub fn deinit(self: StoredId, allocator: std.mem.Allocator) void {
            switch (self) {
                .number => {},
                .string => |s| allocator.free(s),
            }
        }
    };

    pub const IdCtx = struct {
        pub fn hash(_: @This(), key: anytype) u64 {
            return switch (@TypeOf(key)) {
                StoredId => hashStored(key),
                BorrowedId => hashBorrowed(key),
                else => @compileError("unsupported key type: " ++ @typeName(@TypeOf(key))),
            };
        }

        pub fn eql(_: @This(), key: anytype, stored: StoredId) bool {
            const borrowed: BorrowedId = switch (@TypeOf(key)) {
                StoredId => switch (key) {
                    .number => |n| .{ .number = n },
                    .string => |s| .{ .string = s },
                },
                BorrowedId => key,
                else => @compileError("unsupported key type: " ++ @typeName(@TypeOf(key))),
            };
            return switch (borrowed) {
                .number => |n| switch (stored) {
                    .number => |m| n == m,
                    .string => false,
                },
                .string => |s| switch (stored) {
                    .string => |t| std.mem.eql(u8, s, t),
                    .number => false,
                },
            };
        }

        fn hashBorrowed(key: BorrowedId) u64 {
            return switch (key) {
                .number => |n| std.hash.Wyhash.hash(0, std.mem.asBytes(&n)),
                .string => |s| std.hash.Wyhash.hash(0, s),
            };
        }

        fn hashStored(key: StoredId) u64 {
            return switch (key) {
                .number => |n| std.hash.Wyhash.hash(0, std.mem.asBytes(&n)),
                .string => |s| std.hash.Wyhash.hash(0, s),
            };
        }
    };

    pub const RegisterError = std.mem.Allocator.Error || error{
        DuplicateRequestId,
    };

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    map: std.HashMapUnmanaged(StoredId, *SharedPending, IdCtx, 80) = .{},

    pub fn init(allocator: std.mem.Allocator) PendingRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PendingRegistry) void {
        // By design, the registry should be empty at deinit time (run loop has ended,
        // or all waiters have completed). Releasing SharedPending instances requires
        // an `io` value, so we assert emptiness here.
        std.debug.assert(self.map.count() == 0);
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn borrowedIdFromRequestId(id: jsonrpc.RequestId) BorrowedId {
        return switch (id) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
        };
    }

    fn toStored(self: *PendingRegistry, id: BorrowedId) std.mem.Allocator.Error!StoredId {
        return switch (id) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
    }

    pub fn register(self: *PendingRegistry, io: std.Io, id: BorrowedId) RegisterError!*SharedPending {
        const stored = try self.toStored(id);
        errdefer stored.deinit(self.allocator);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.map.getAdapted(id, IdCtx{})) |_| return error.DuplicateRequestId;

        const shared = try self.allocator.create(SharedPending);
        shared.init();

        try self.map.put(self.allocator, stored, shared);
        return shared;
    }

    /// Removes the pending entry if present (freeing the stored key) and releases the
    /// registry's reference. The caller's reference is not affected.
    pub fn abandon(self: *PendingRegistry, io: std.Io, id: BorrowedId) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.map.fetchRemoveAdapted(id, IdCtx{})) |kv| {
            kv.key.deinit(self.allocator);
            kv.value.release(self.allocator, io);
            return;
        }
    }

    pub fn fulfillResult(self: *PendingRegistry, io: std.Io, id: BorrowedId, result: json.Value) void {
        const shared = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.map.fetchRemoveAdapted(id, IdCtx{})) |kv| {
                kv.key.deinit(self.allocator);
                break :blk kv.value;
            }
            break :blk null;
        };

        if (shared) |sp| {
            sp.pending.signalUncancelable(io, .{ .result = result });
            sp.release(self.allocator, io); // drop registry reference
            return;
        }

        jsonrpc.Message.freeValue(self.allocator, result);
    }

    pub fn fulfillFailed(self: *PendingRegistry, io: std.Io, id: BorrowedId) void {
        const shared = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.map.fetchRemoveAdapted(id, IdCtx{})) |kv| {
                kv.key.deinit(self.allocator);
                break :blk kv.value;
            }
            break :blk null;
        };
        if (shared) |sp| {
            sp.pending.signalUncancelable(io, .{ .failed = {} });
            sp.release(self.allocator, io); // drop registry reference
        }
    }

    pub fn notifyConnectionClosed(self: *PendingRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.map.count() != 0) {
            var it = self.map.iterator();
            const entry = it.next() orelse break;
            const key_copy = entry.key_ptr.*;
            const shared = entry.value_ptr.*;
            _ = self.map.fetchRemoveContext(key_copy, IdCtx{}) orelse unreachable;
            key_copy.deinit(self.allocator);
            shared.pending.signalUncancelable(io, .{ .connection_closed = {} });
            shared.release(self.allocator, io); // drop registry reference
        }
    }
};
