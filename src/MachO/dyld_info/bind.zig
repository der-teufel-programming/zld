const std = @import("std");
const assert = std.debug.assert;
const leb = std.leb;
const log = std.log.scoped(.dyld_info);
const macho = std.macho;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const MachO = @import("../../MachO.zig");
const Symbol = @import("../Symbol.zig");

pub const Bind = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    buffer: std.ArrayListUnmanaged(u8) = .{},

    const Self = @This();

    const Entry = struct {
        target: Symbol.Index,
        offset: u64,
        segment_id: u8,
        addend: i64,

        pub fn lessThan(ctx: *MachO, entry: Entry, other: Entry) bool {
            if (entry.segment_id == other.segment_id) {
                if (entry.target == other.target) {
                    return entry.offset < other.offset;
                }
                const entry_name = ctx.getSymbol(entry.target).getName(ctx);
                const other_name = ctx.getSymbol(other.target).getName(ctx);
                return std.mem.lessThan(u8, entry_name, other_name);
            }
            return entry.segment_id < other.segment_id;
        }
    };

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.buffer.deinit(gpa);
    }

    pub fn size(self: Self) u64 {
        return @as(u64, @intCast(self.buffer.items.len));
    }

    pub fn finalize(self: *Self, gpa: Allocator, ctx: *MachO) !void {
        if (self.entries.items.len == 0) return;

        const writer = self.buffer.writer(gpa);

        std.mem.sort(Entry, self.entries.items, ctx, Entry.lessThan);

        var start: usize = 0;
        var seg_id: ?u8 = null;
        for (self.entries.items, 0..) |entry, i| {
            if (seg_id != null and seg_id.? == entry.segment_id) continue;
            try finalizeSegment(self.entries.items[start..i], ctx, writer);
            seg_id = entry.segment_id;
            start = i;
        }

        try finalizeSegment(self.entries.items[start..], ctx, writer);
        try done(writer);
    }

    fn finalizeSegment(entries: []const Entry, ctx: *MachO, writer: anytype) !void {
        if (entries.len == 0) return;

        const seg_id = entries[0].segment_id;
        try setSegmentOffset(seg_id, 0, writer);

        var offset: u64 = 0;
        var addend: i64 = 0;
        var count: usize = 0;
        var skip: u64 = 0;
        var target: ?Symbol.Index = null;

        var state: enum {
            start,
            bind_single,
            bind_times_skip,
        } = .start;

        var i: usize = 0;
        while (i < entries.len) : (i += 1) {
            const current = entries[i];
            if (target == null or target.? != current.target) {
                switch (state) {
                    .start => {},
                    .bind_single => try doBind(writer),
                    .bind_times_skip => try doBindTimesSkip(count, skip, writer),
                }
                state = .start;
                target = current.target;

                const sym = ctx.getSymbol(current.target);
                const name = sym.getName(ctx);
                const flags: u8 = if (sym.weakRef(ctx)) macho.BIND_SYMBOL_FLAGS_WEAK_IMPORT else 0;
                const ordinal: i16 = ord: {
                    if (ctx.options.namespace == .flat) break :ord macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP;
                    if (sym.getDylibOrdinal(ctx)) |ord| break :ord @bitCast(ord);
                    if (ctx.options.undefined_treatment == .dynamic_lookup)
                        break :ord macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP;
                    break :ord macho.BIND_SPECIAL_DYLIB_SELF;
                };

                try setSymbol(name, flags, writer);
                try setTypePointer(writer);
                try setDylibOrdinal(ordinal, writer);

                if (current.addend != addend) {
                    addend = current.addend;
                    try setAddend(addend, writer);
                }
            }

            log.debug("{x}, {d}, {x}, {?x}, {s}", .{ offset, count, skip, addend, @tagName(state) });
            log.debug("  => {x}", .{current.offset});
            switch (state) {
                .start => {
                    if (current.offset < offset) {
                        try addAddr(@as(u64, @bitCast(@as(i64, @intCast(current.offset)) - @as(i64, @intCast(offset)))), writer);
                        offset = offset - (offset - current.offset);
                    } else if (current.offset > offset) {
                        const delta = current.offset - offset;
                        try addAddr(delta, writer);
                        offset += delta;
                    }
                    state = .bind_single;
                    offset += @sizeOf(u64);
                    count = 1;
                },
                .bind_single => {
                    if (current.offset == offset) {
                        try doBind(writer);
                        state = .start;
                    } else if (current.offset > offset) {
                        const delta = current.offset - offset;
                        state = .bind_times_skip;
                        skip = @as(u64, @intCast(delta));
                        offset += skip;
                    } else unreachable;
                    i -= 1;
                },
                .bind_times_skip => {
                    if (current.offset < offset) {
                        count -= 1;
                        if (count == 1) {
                            try doBindAddAddr(skip, writer);
                        } else {
                            try doBindTimesSkip(count, skip, writer);
                        }
                        state = .start;
                        offset = offset - (@sizeOf(u64) + skip);
                        i -= 2;
                    } else if (current.offset == offset) {
                        count += 1;
                        offset += @sizeOf(u64) + skip;
                    } else {
                        try doBindTimesSkip(count, skip, writer);
                        state = .start;
                        i -= 1;
                    }
                },
            }
        }

        switch (state) {
            .start => unreachable,
            .bind_single => try doBind(writer),
            .bind_times_skip => try doBindTimesSkip(count, skip, writer),
        }
    }

    pub fn write(self: Self, writer: anytype) !void {
        if (self.size() == 0) return;
        try writer.writeAll(self.buffer.items);
    }
};

pub const LazyBind = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    buffer: std.ArrayListUnmanaged(u8) = .{},
    offsets: std.ArrayListUnmanaged(u32) = .{},

    const Self = @This();

    const Entry = struct {
        target: Symbol.Index,
        offset: u64,
        segment_id: u8,
        addend: i64,
    };

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.buffer.deinit(gpa);
        self.offsets.deinit(gpa);
    }

    pub fn size(self: Self) u64 {
        return @as(u64, @intCast(self.buffer.items.len));
    }

    pub fn finalize(self: *Self, gpa: Allocator, ctx: *MachO) !void {
        if (self.entries.items.len == 0) return;

        try self.offsets.ensureTotalCapacityPrecise(gpa, self.entries.items.len);

        var cwriter = std.io.countingWriter(self.buffer.writer(gpa));
        const writer = cwriter.writer();

        var addend: i64 = 0;

        for (self.entries.items) |entry| {
            self.offsets.appendAssumeCapacity(@as(u32, @intCast(cwriter.bytes_written)));

            const sym = ctx.getSymbol(entry.target);
            const name = sym.getName(ctx);
            const flags: u8 = if (sym.weakRef(ctx)) macho.BIND_SYMBOL_FLAGS_WEAK_IMPORT else 0;
            const ordinal: i16 = ord: {
                if (ctx.options.namespace == .flat) break :ord macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP;
                if (sym.getDylibOrdinal(ctx)) |ord| break :ord @bitCast(ord);
                if (ctx.options.undefined_treatment == .dynamic_lookup)
                    break :ord macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP;
                break :ord macho.BIND_SPECIAL_DYLIB_SELF;
            };

            try setSegmentOffset(entry.segment_id, entry.offset, writer);
            try setSymbol(name, flags, writer);
            try setDylibOrdinal(ordinal, writer);

            if (entry.addend != addend) {
                try setAddend(entry.addend, writer);
                addend = entry.addend;
            }

            try doBind(writer);
            try done(writer);
        }
    }

    pub fn write(self: Self, writer: anytype) !void {
        if (self.size() == 0) return;
        try writer.writeAll(self.buffer.items);
    }
};

fn setSegmentOffset(segment_id: u8, offset: u64, writer: anytype) !void {
    log.debug(">>> set segment: {d} and offset: {x}", .{ segment_id, offset });
    try writer.writeByte(macho.BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | @as(u4, @truncate(segment_id)));
    try std.leb.writeULEB128(writer, offset);
}

fn setSymbol(name: []const u8, flags: u8, writer: anytype) !void {
    log.debug(">>> set symbol: {s} with flags: {x}", .{ name, flags });
    try writer.writeByte(macho.BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | @as(u4, @truncate(flags)));
    try writer.writeAll(name);
    try writer.writeByte(0);
}

fn setTypePointer(writer: anytype) !void {
    log.debug(">>> set type: {d}", .{macho.BIND_TYPE_POINTER});
    try writer.writeByte(macho.BIND_OPCODE_SET_TYPE_IMM | @as(u4, @truncate(macho.BIND_TYPE_POINTER)));
}

fn setDylibOrdinal(ordinal: i16, writer: anytype) !void {
    if (ordinal <= 0) {
        switch (ordinal) {
            macho.BIND_SPECIAL_DYLIB_SELF,
            macho.BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE,
            macho.BIND_SPECIAL_DYLIB_FLAT_LOOKUP,
            => {},
            else => unreachable, // Invalid dylib special binding
        }
        log.debug(">>> set dylib special: {d}", .{ordinal});
        const cast = @as(u16, @bitCast(ordinal));
        try writer.writeByte(macho.BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | @as(u4, @truncate(cast)));
    } else {
        const cast = @as(u16, @bitCast(ordinal));
        log.debug(">>> set dylib ordinal: {d}", .{ordinal});
        if (cast <= 0xf) {
            try writer.writeByte(macho.BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | @as(u4, @truncate(cast)));
        } else {
            try writer.writeByte(macho.BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB);
            try std.leb.writeULEB128(writer, cast);
        }
    }
}

fn setAddend(addend: i64, writer: anytype) !void {
    log.debug(">>> set addend: {x}", .{addend});
    try writer.writeByte(macho.BIND_OPCODE_SET_ADDEND_SLEB);
    try std.leb.writeILEB128(writer, addend);
}

fn doBind(writer: anytype) !void {
    log.debug(">>> bind", .{});
    try writer.writeByte(macho.BIND_OPCODE_DO_BIND);
}

fn doBindAddAddr(addr: u64, writer: anytype) !void {
    log.debug(">>> bind with add: {x}", .{addr});
    if (std.mem.isAligned(addr, @sizeOf(u64))) {
        const imm = @divExact(addr, @sizeOf(u64));
        if (imm <= 0xf) {
            try writer.writeByte(
                macho.BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED | @as(u4, @truncate(imm)),
            );
            return;
        }
    }
    try writer.writeByte(macho.BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB);
    try std.leb.writeULEB128(writer, addr);
}

fn doBindTimesSkip(count: usize, skip: u64, writer: anytype) !void {
    log.debug(">>> bind with count: {d} and skip: {x}", .{ count, skip });
    try writer.writeByte(macho.BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB);
    try std.leb.writeULEB128(writer, count);
    try std.leb.writeULEB128(writer, skip);
}

fn addAddr(addr: u64, writer: anytype) !void {
    log.debug(">>> add: {x}", .{addr});
    try writer.writeByte(macho.BIND_OPCODE_ADD_ADDR_ULEB);
    try std.leb.writeULEB128(writer, addr);
}

fn done(writer: anytype) !void {
    log.debug(">>> done", .{});
    try writer.writeByte(macho.BIND_OPCODE_DONE);
}

const TestContext = struct {
    symbols: std.ArrayListUnmanaged(macho.nlist_64) = .{},
    strtab: std.ArrayListUnmanaged(u8) = .{},

    const Target = struct {
        index: u32,

        fn eql(this: Target, other: Target) bool {
            return this.index == other.index;
        }
    };

    fn deinit(ctx: *TestContext, gpa: Allocator) void {
        ctx.symbols.deinit(gpa);
        ctx.strtab.deinit(gpa);
    }

    fn addSymbol(ctx: *TestContext, gpa: Allocator, name: []const u8, ordinal: i16, flags: u16) !void {
        const n_strx = try ctx.addString(gpa, name);
        var n_desc = @as(u16, @bitCast(ordinal * macho.N_SYMBOL_RESOLVER));
        n_desc |= flags;
        try ctx.symbols.append(gpa, .{
            .n_value = 0,
            .n_strx = n_strx,
            .n_desc = n_desc,
            .n_type = macho.N_EXT,
            .n_sect = 0,
        });
    }

    fn addString(ctx: *TestContext, gpa: Allocator, name: []const u8) !u32 {
        const n_strx = @as(u32, @intCast(ctx.strtab.items.len));
        try ctx.strtab.appendSlice(gpa, name);
        try ctx.strtab.append(gpa, 0);
        return n_strx;
    }

    fn getSymbol(ctx: TestContext, target: Target) macho.nlist_64 {
        return ctx.symbols.items[target.index];
    }

    fn getSymbolName(ctx: TestContext, target: Target) []const u8 {
        const sym = ctx.getSymbol(target);
        assert(sym.n_strx < ctx.strtab.items.len);
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(ctx.strtab.items.ptr + sym.n_strx)), 0);
    }
};
