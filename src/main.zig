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

        try table.insert(init.gpa, index, str);

        try stdout.writeAll("* ");
        length += try table.render(stdout);
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}
