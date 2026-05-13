const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Writer = std.Io.Writer;

/// A piece table data structure.
pub const PieceTable = struct {
    /// The buffer containing the read-only data upon initialization.
    ro: []const u8,
    /// The append-only buffer to which new data is added.
    rw: ArrayList(u8),
    /// The list of entries on the table.
    entries: ArrayList(Entry),

    const Entry = struct {
        /// The location of the data.
        buffer: Buffer,
        /// The start index of the data in the buffer.
        start: usize,
        /// The length of the entry.
        len: usize,

        /// The location of the data (i.e. which buffer the data is located).
        pub const Buffer = enum { rw, ro };

        /// Split a buffer into two pieces, where the current buffer
        /// represending the first piece is modified, and the second piece is
        /// returned.
        pub fn split(self: *Entry, pos: usize) Entry {
            const old_len = self.len;
            self.len = pos;

            return .{
                .buffer = self.buffer,
                .start = self.start + self.len,
                .len = old_len - pos,
            };
        }

        test split {
            var entry: Entry = .{ .buffer = .ro, .start = 0, .len = 10 };
            const new = entry.split(4);

            try expectEntry(.{ .buffer = .ro, .start = 0, .len = 4 }, entry);
            try expectEntry(.{ .buffer = .ro, .start = 4, .len = 6 }, new);
        }
    };

    pub const InitError = error{} || Allocator.Error;

    /// Initialize a new `PieceTable` with initial data, `buf`. This data is
    /// not modified. If the length of `buf` is zero, this function does not
    /// allocate any memory. If the length of `buf` is non-zero, a single table
    /// entry is allocated, referring to the initial buffer.
    pub fn init(gpa: Allocator, buf: []const u8) InitError!PieceTable {
        var entries: ArrayList(Entry) = .empty;

        if (buf.len > 0) {
            try entries.append(gpa, .{ .buffer = .ro, .start = 0, .len = buf.len });
        }

        return .{
            .ro = buf,
            .rw = .empty,
            .entries = entries,
        };
    }

    /// Deinitialize a `PieceTable`, freeing any memory associated with table
    /// insertions.
    pub fn deinit(self: *PieceTable, gpa: Allocator) void {
        self.rw.deinit(gpa);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    pub const AppendError = error{} || Allocator.Error;

    pub fn append(self: *PieceTable, gpa: Allocator, buf: []const u8) AppendError!void {
        const rw_end = self.rw.items.len;

        try self.rw.appendSlice(gpa, buf);
        try self.entries.append(gpa, .{
            .buffer = .rw,
            .start = rw_end,
            .len = buf.len,
        });
    }

    test append {
        const gpa = testing.allocator;

        var t: PieceTable = try .init(gpa, "Hello");
        defer t.deinit(gpa);

        try t.append(gpa, ", world!");

        try expectRender("Hello, world!", &t);
    }

    pub const InsertError = error{OutOfBounds} || Allocator.Error;

    /// Appends the new data to the append-only buffer, and inserts the necessary table entries.
    pub fn insert(self: *PieceTable, gpa: Allocator, idx_ptd: usize, buf: []const u8) InsertError!void {
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

                // Translate the PTD index to entry index. This is where we need to split the entry.
                const entry_split_pos = idx_ptd - pos_ptd_start;
                const next_entry = entry.split(entry_split_pos);

                // Create an entry that refers to the text to insert.
                const new_entry: Entry = .{
                    .buffer = .rw,
                    .start = rw_end,
                    .len = buf.len,
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
                return InsertError.OutOfBounds;
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

    pub const DeleteError = error{OutOfBounds} || Allocator.Error;

    /// Deletes a single character from the table, inserting the necessary
    /// table entries.
    pub fn delete(self: *PieceTable, gpa: Allocator, idx_ptd: usize) DeleteError!void {
        // Perform possible list reallocation up front so that we can insert
        // while iterating, maintaining stable pointers.
        try self.entries.ensureUnusedCapacity(gpa, 1);

        // Maintain PTD positions.
        var pos_ptd_start: usize = 0;
        var pos_ptd_end: usize = 0;

        for (self.entries.items, 0..) |*entry, idx_tbl| {
            pos_ptd_end = pos_ptd_start + entry.len - 1;
            defer pos_ptd_start += entry.len;

            if (idx_ptd > pos_ptd_start and idx_ptd < pos_ptd_end) {
                // In this case, we're trying to delete a character in the
                // middle of the entry. To do this, we need to split the entry
                // into two pieces immediately after our PTD deletion index:
                // 1. The first part of the original entry with the length
                //    truncated to the difference of our PTD deletion index and
                //    start, less one.
                // 2. The second part of the original entry with the start set
                //    to the translated PTD deletion index, and length the
                //    remaining portion of the original block.

                // Translated entry deletion index, bumped past the character to deleted.
                const entry_split_pos = idx_ptd - pos_ptd_start + 1;
                const next_entry = entry.split(entry_split_pos);

                // Remove the character from the entry.
                entry.len -= 1;

                try self.entries.insert(gpa, idx_tbl + 1, next_entry);

                break;
            } else if (idx_ptd == pos_ptd_start) {
                // In this case the deletion index is at the start of the
                // entry, so all we need to do is increment the start and
                // correspondingly decrement the length.
                entry.start += 1;
                entry.len -= 1;

                break;
            } else if (idx_ptd == pos_ptd_end) {
                // In this case the deletion index is at the end of the block,
                // so all we need to do is decrement the length.
                entry.len -= 1;

                break;
            } else {
                // We didn't find the entry we were looking for. Continue to next iteration.
            }
        } else {
            // If we didn't find anything, we must be out of bounds.
            return DeleteError.OutOfBounds;
        }
    }

    pub const RenderError = error{} || Writer.Error;

    /// Writes data to the writer in the order specified by the table entries.
    pub fn render(self: *const PieceTable, w: *Writer) RenderError!usize {
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

    /// Writes data to the buffer in the order specified by the table entries.
    pub fn renderBuf(self: *const PieceTable, buf: []u8) RenderError![]const u8 {
        var w: Writer = .fixed(buf);
        const count = try self.render(&w);
        return buf[0..count];
    }

    pub fn length(self: *const PieceTable) usize {
        var len: usize = 0;
        for (self.entries.items) |entry| {
            len += entry.len;
        }

        return len;
    }

    test length {
        const gpa = testing.allocator;

        var t: PieceTable = try .init(gpa, "world");
        defer t.deinit(gpa);

        try t.insert(gpa, 0, "Hello, ");

        try testing.expectEqual(12, t.length());
    }
};

comptime {
    _ = PieceTable;
    _ = PieceTable.Entry;
}

test "no modifications" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "Hello");
    defer t.deinit(gpa);

    try expectRender("Hello", &t);
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

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 5 }, t.entries.items[0]);
    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 8 }, t.entries.items[1]);

    try expectRender("Hello, world!", &t);
}

test "RO prepend" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "world!");
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "Hello, ");

    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 7 }, t.entries.items[0]);
    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 6 }, t.entries.items[1]);

    try expectRender("Hello, world!", &t);
}

test "RO insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "The brown fox...");
    defer t.deinit(gpa);

    try t.insert(gpa, 3, " quick");

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 3 }, t.entries.items[0]);
    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);
    try expectEntry(.{ .buffer = .ro, .start = 3, .len = 13 }, t.entries.items[2]);

    try expectRender("The quick brown fox...", &t);
}

test "RW insert" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "world!");
    try t.insert(gpa, 0, "Hello, ");

    try expectEntry(.{ .buffer = .rw, .start = 6, .len = 7 }, t.entries.items[0]);
    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 6 }, t.entries.items[1]);

    try expectRender("Hello, world!", &t);
}

test "RW insert split" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "The quick fox");
    try t.insert(gpa, 9, " brown");

    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 9 }, t.entries.items[0]);
    try expectEntry(.{ .buffer = .rw, .start = 13, .len = 6 }, t.entries.items[1]);
    try expectEntry(.{ .buffer = .rw, .start = 9, .len = 4 }, t.entries.items[2]);

    try expectRender("The quick brown fox", &t);
}

test "RW insert at boundary" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, &.{});
    defer t.deinit(gpa);

    try t.insert(gpa, 0, "one");
    try t.insert(gpa, 3, "|");
    try t.insert(gpa, 4, "two");

    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 3 }, t.entries.items[0]); // one
    try expectEntry(.{ .buffer = .rw, .start = 3, .len = 1 }, t.entries.items[1]); // |
    try expectEntry(.{ .buffer = .rw, .start = 4, .len = 3 }, t.entries.items[2]); // two

    try expectRender("one|two", &t);
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

    try expectEntry(.{ .buffer = .rw, .start = 0, .len = 3 }, t.entries.items[0]); // one
    try expectEntry(.{ .buffer = .rw, .start = 7, .len = 1 }, t.entries.items[1]); // <
    try expectEntry(.{ .buffer = .rw, .start = 9, .len = 1 }, t.entries.items[2]); // .
    try expectEntry(.{ .buffer = .rw, .start = 8, .len = 1 }, t.entries.items[3]); // >
    try expectEntry(.{ .buffer = .rw, .start = 3, .len = 1 }, t.entries.items[4]); // |
    try expectEntry(.{ .buffer = .rw, .start = 4, .len = 3 }, t.entries.items[5]); // two

    try expectRender("one<.>|two", &t);
}

test "RO delete at start" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "Hello");
    defer t.deinit(gpa);

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 5 }, t.entries.items[0]); // Hello

    try t.delete(gpa, 0);

    try expectEntry(.{ .buffer = .ro, .start = 1, .len = 4 }, t.entries.items[0]); // ello
    try expectRender("ello", &t);
}

test "RO delete at end" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "Hello");
    defer t.deinit(gpa);

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 5 }, t.entries.items[0]); // Hello

    try t.delete(gpa, 4);

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 4 }, t.entries.items[0]); // Hell
    try expectRender("Hell", &t);
}

test "RO delete split" {
    const gpa = testing.allocator;

    var t: PieceTable = try .init(gpa, "abc123");
    defer t.deinit(gpa);

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 6 }, t.entries.items[0]); // abc123

    try t.delete(gpa, 3);

    try expectEntry(.{ .buffer = .ro, .start = 0, .len = 3 }, t.entries.items[0]); // abc
    try expectEntry(.{ .buffer = .ro, .start = 4, .len = 2 }, t.entries.items[1]); // 23
    try expectRender("abc23", &t);
}

fn expectRender(comptime expected: []const u8, t: *const PieceTable) !void {
    var buf: [expected.len]u8 = undefined;
    const result = try t.renderBuf(&buf);
    try testing.expectEqualStrings(expected, result);
}

fn expectEntry(comptime expected: PieceTable.Entry, actual: PieceTable.Entry) !void {
    try testing.expectEqualDeep(expected, actual);
}
