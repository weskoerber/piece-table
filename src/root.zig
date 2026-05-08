const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;

pub const PieceTable = struct {
    ro: []const u8,
    rw: ArrayList(u8),
    entries: ArrayList(Entry),

    const Entry = struct {
        buffer: Buffer,
        start: usize,
        len: usize,

        pub const Buffer = enum { rw, ro };
    };

    pub fn init(gpa: Allocator, buf: []const u8) !PieceTable {
        var entries: ArrayList(Entry) = try .initCapacity(gpa, 1);

        if (buf.len > 0) {
            try entries.append(gpa, .{ .buffer = .ro, .start = 0, .len = buf.len });
        }

        return .{
            .ro = buf,
            .rw = .empty,
            .entries = entries,
        };
    }

    pub fn deinit(self: *PieceTable, gpa: Allocator) void {
        self.rw.deinit(gpa);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    pub fn insert(self: *PieceTable, gpa: Allocator, index: usize, buf: []const u8) !void {
        const rw_end = self.rw.items.len;

        for (self.entries.items, 0..) |*entry, i| {
            const end = entry.start + entry.len;
            const len = entry.len;

            if (index > entry.start and index < end) {
                // In this case, we're trying to insert in the middle of an
                // entry. To do that, we need to split the entry into three
                // pieces:
                // 1. The original entry. Set the length of this entry to 1
                // index before the document insertion index.
                // 2. A new entry containing a reference to the text to be
                // inserted starting at the end of the previous entry, the
                // document insertion index.
                // 3. A new entry containing a reference to the second half of
                // the split entry starting at the end of the newly inserted
                // entry. Take note that the data referred to by this entry may
                // not be the same buffer that's referred to by the inserted
                // text. In this case, this third entry should start
                // immediately after the end of the first entry.
                entry.len = index - entry.start;
                const new_entry: Entry = .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
                };

                const next_entry: Entry = .{
                    .buffer = entry.buffer,
                    .start = entry.len,
                    .len = len - entry.len,
                };

                try self.rw.appendSlice(gpa, buf);
                try self.entries.insertSlice(gpa, i + 1, &.{ new_entry, next_entry });

                return;
            } else {
                try self.rw.appendSlice(gpa, buf);
                const entry_index = if (index == entry.start) i else i + 1;
                try self.entries.insert(gpa, entry_index, .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
                });

                return;
            }
        }

        // If we get here, we haven't figured out where to insert the entry due to:
        //   - no entries exist
        //   - we're appending a new entry
        // Either way, we're appending a new entry.
        if (index != 0 and self.entries.items.len == 0) {
            return error.OutOfBounds;
        }

        try self.rw.appendSlice(gpa, buf);
        try self.entries.append(gpa, .{
            .buffer = .rw,
            .start = rw_end,
            .len = buf.len,
        });
    }

    pub fn render(self: *const PieceTable, w: *Writer) !usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            const buf = switch (entry.buffer) {
                .ro => self.ro,
                .rw => self.rw.items,
            };

            const slice = buf[entry.start .. entry.start + entry.len];
            try w.writeAll(slice);
            count += slice.len;
        }

        return count;
    }

    pub fn renderBuf(self: *const PieceTable, buf: []u8) ![]const u8 {
        var w: Writer = .fixed(buf);
        const count = try self.render(&w);
        return buf[0..count];
    }
};

comptime {
    _ = PieceTable;
}

test "no modifications" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "Hello");
    defer t.deinit(gpa);

    const expected = "Hello";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RO append" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "Hello");
    defer t.deinit(gpa);

    try t.insert(gpa, 5, ", world!");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 0, .len = 5 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 8 }, t.entries.items[1]);

    const expected = "Hello, world!";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RO prepend" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "world!");
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "Hello, ");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 7 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 0, .len = 6 }, t.entries.items[1]);

    const expected = "Hello, world!";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RO insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "The brown fox...");
    defer t.deinit(gpa);

    try t.insert(gpa, 3, " quick");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 0, .len = 3 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 3, .len = 13 }, t.entries.items[2]);

    const expected = "The quick brown fox...";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RW insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try testing.expectError(error.OutOfBounds, t.insert(gpa, 1, "hi"));

    try t.insert(gpa, 0, "world!");
    try t.insert(gpa, 0, "Hello, ");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 6, .len = 7 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);

    const expected = "Hello, world!";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RW insert split" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try testing.expectError(error.OutOfBounds, t.insert(gpa, 1, "hi"));

    try t.insert(gpa, 0, "The quick fox");
    try t.insert(gpa, 9, " brown");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 9 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 13, .len = 6 }, t.entries.items[1]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 9, .len = 4 }, t.entries.items[2]);

    const expected = "The quick brown fox";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

test "RW insert at boundary" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try testing.expectError(error.OutOfBounds, t.insert(gpa, 1, "hi"));

    try t.insert(gpa, 0, "one");
    try t.insert(gpa, 3, "|");
    try t.insert(gpa, 4, "two");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 3 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 3, .len = 1 }, t.entries.items[1]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 4, .len = 3 }, t.entries.items[2]);

    const expected = "The quick brown fox";
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}
