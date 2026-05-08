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

    pub fn insert(self: *PieceTable, gpa: Allocator, idx_ptd: usize, buf: []const u8) !void {
        // Perform possible list reallocation up front so that we can insert
        // while iterating, maintaining stable pointers.
        try self.entries.ensureUnusedCapacity(gpa, 2);

        // This will be the starting index of the entry that refers to the inserted text.
        const rw_end = self.rw.items.len;

        // Maintain PTD positions.
        var pos_ptd_start: usize = 0;
        var pos_ptd_end: usize = 0;

        for (self.entries.items, 0..) |*entry, idx_tbl| {
            pos_ptd_end = pos_ptd_start + entry.len;
            defer pos_ptd_start += entry.len;

            if (idx_ptd > pos_ptd_start and idx_ptd < pos_ptd_end) {
                // In this case, we're trying to insert in the middle of an
                // entry. To do that, we need to split the entry into three
                // pieces:
                // 1. The original entry: Set the length of this entry to 1
                //    index before the PTD insertion index.
                // 2. New entry #1: A new entry containing a reference to the
                //    text to be inserted starting at the end of the previous
                //    entry, the PTD insertion index.
                // 3. New entry #2: A new entry containing a reference to the
                //    second half of the split entry starting at the end of the
                //    newly inserted entry. Take note that the data referred to
                //    by this entry may not be the same buffer that's referred
                //    to by the inserted text. In this case, this third entry
                //    should start immediately after the end of the first entry.

                // truncate the current entry up to the desired PTD insertion index.
                const len = entry.len;
                entry.len = idx_ptd - pos_ptd_start;

                // Create an entry that refers to the text to insert.
                const new_entry: Entry = .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
                };

                // The third entry that refers to the second half of the entry we're splitting.
                const next_entry: Entry = .{
                    .buffer = entry.buffer,
                    .start = entry.start + entry.len,
                    .len = len - entry.len,
                };

                // Append the text to the RW buffer and insert the entries.
                try self.rw.appendSlice(gpa, buf);
                try self.entries.insertSlice(gpa, idx_tbl + 1, &.{ new_entry, next_entry });

                break;
            } else if (idx_ptd == pos_ptd_start) {
                // Insert a new block between two existing blocks, pushing the current block forward.
                try self.rw.appendSlice(gpa, buf);
                try self.entries.insert(gpa, idx_tbl, .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
                });

                break;
            } else if (idx_ptd == pos_ptd_end) {
                // Insert a new block between two existing blocks, inserting after the current block.
                try self.rw.appendSlice(gpa, buf);
                try self.entries.insert(gpa, idx_tbl + 1, .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
                });

                break;
            } else {
                // We didn't find the entry we were looking for. Continue to next iteration.
            }
        } else {
            // We didn't find any entry that corresponds to the PTD insertion index.
            // Make sure we aren't out of bounds.
            if (idx_ptd > pos_ptd_end) {
                return error.OutOfBounds;
            }

            // Append a new block to the end.
            try self.rw.appendSlice(gpa, buf);
            try self.entries.append(gpa, .{
                .buffer = .rw,
                .start = rw_end,
                .len = buf.len,
            });
        }
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

    try testRender("Hello", &t);
}

test "inserting past end" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try testing.expectError(error.OutOfBounds, t.insert(gpa, 1, "hi"));
    try t.insert(gpa, 0, "Hello");
    try testing.expectError(error.OutOfBounds, t.insert(gpa, 42, "oops"));

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

    try testRender("Hello, world!", &t);
}

test "RO prepend" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "world!");
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "Hello, ");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 7 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 0, .len = 6 }, t.entries.items[1]);

    try testRender("Hello, world!", &t);
}

test "RO insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "The brown fox...");
    defer t.deinit(gpa);

    try t.insert(gpa, 3, " quick");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 0, .len = 3 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .ro, .start = 3, .len = 13 }, t.entries.items[2]);

    try testRender("The quick brown fox...", &t);
}

test "RW insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "world!");
    try t.insert(gpa, 0, "Hello, ");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 6, .len = 7 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);

    try testRender("Hello, world!", &t);
}

test "RW insert split" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "The quick fox");
    try t.insert(gpa, 9, " brown");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 9 }, t.entries.items[0]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 13, .len = 6 }, t.entries.items[1]);
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 9, .len = 4 }, t.entries.items[2]);

    try testRender("The quick brown fox", &t);
}

test "RW insert at boundary" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "one");
    try t.insert(gpa, 3, "|");
    try t.insert(gpa, 4, "two");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 3 }, t.entries.items[0]); // one
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 3, .len = 1 }, t.entries.items[1]); // |
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 4, .len = 3 }, t.entries.items[2]); // two

    try testRender("one|two", &t);
}

test "RW multiple inserts" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "one");
    try t.insert(gpa, 3, "|");
    try t.insert(gpa, 4, "two");
    try t.insert(gpa, 3, "<>");
    try t.insert(gpa, 4, ".");

    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 0, .len = 3 }, t.entries.items[0]); // one
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 7, .len = 1 }, t.entries.items[1]); // <
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 9, .len = 1 }, t.entries.items[2]); // .
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 8, .len = 1 }, t.entries.items[3]); // >
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 3, .len = 1 }, t.entries.items[4]); // |
    try testing.expectEqualDeep(PieceTable.Entry{ .buffer = .rw, .start = 4, .len = 3 }, t.entries.items[5]); // two

    try testRender("one<.>|two", &t);
}

fn testRender(comptime expected: []const u8, t: *const PieceTable) !void {
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}
