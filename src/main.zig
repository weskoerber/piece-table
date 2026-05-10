//! Piece table test program.
//!
//! Running this program will open and read stdin, reading input lines. Each
//! input line is formatted as follows: `[index] string`, were the index is
//! optional, and delimited from the string by a space.
//!
//! For example, to produce the string `Hello, world!` by inserting `world!`
//! first, then `Hello, ` next, you would submit two lines:
//!   1. `0 world!`
//!   2. `0 Hello, `
//!
//! If the index is omitted, or is not a valid integer, the index assumes the
//! end of the buffer. The above example is identical to:
//!   1. `world!`
//!   2. `Hello, `

const std = @import("std");
const PieceTable = @import("piece_table").PieceTable;

var stdout_buf: [1024]u8 = undefined;
var stdin_buf: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var table: PieceTable = try .init(init.gpa, "");
    defer table.deinit(init.gpa);

    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var length: usize = 0;
    while (true) {
        const line = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);

        const index: usize, const str: []const u8 = if (std.ascii.isDigit(line[0]))
            if (std.mem.findScalar(u8, line, ' ')) |pos|
                .{ std.fmt.parseInt(usize, line[0..pos], 10) catch length, line[pos + 1 ..] }
            else
                .{ length, line }
        else
            .{ length, line };

        table.insert(init.gpa, index, str) catch |err| switch (err) {
            error.OutOfBounds => std.log.err("index {d} was out of bounds", .{index}),
            else => |e| return e,
        };

        try stdout.writeAll("* ");
        length = try table.render(stdout);
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}
