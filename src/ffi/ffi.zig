const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const PieceTable = @import("piece_table").PieceTable;

pub const PieceTableFfi = anyopaque;

const gpa = std.heap.smp_allocator;

pub export fn pt_init(pt: **PieceTableFfi, buffer: [*:0]const u8, buffer_len: usize) i32 {
    const t = gpa.create(PieceTable) catch |err| switch (err) {
        Allocator.Error.OutOfMemory => return 1,
    };

    t.* = PieceTable.init(gpa, buffer[0..buffer_len]) catch |err| switch (err) {
        Allocator.Error.OutOfMemory => return 1,
    };

    pt.* = t;

    return 0;
}

pub export fn pt_deinit(pt: *PieceTableFfi) void {
    var t: *PieceTable = @ptrCast(@alignCast(pt));
    t.deinit(gpa);
    gpa.destroy(t);
}

pub export fn pt_append(pt: *PieceTableFfi, buffer: [*:0]const u8, buffer_len: usize) i32 {
    var t: *PieceTable = @ptrCast(@alignCast(pt));

    t.append(gpa, buffer[0..buffer_len]) catch |err| switch (err) {
        PieceTable.AppendError.OutOfMemory => return 1,
    };

    return 0;
}

pub export fn pt_insert(pt: *PieceTableFfi, index: usize, buffer: [*:0]const u8, buffer_len: usize) i32 {
    var t: *PieceTable = @ptrCast(@alignCast(pt));

    t.insert(gpa, index, buffer[0..buffer_len]) catch |err| switch (err) {
        PieceTable.InsertError.OutOfMemory => return 1,
        PieceTable.InsertError.OutOfBounds => return 2,
    };

    return 0;
}

pub export fn pt_delete(pt: *PieceTableFfi, index: usize) i32 {
    var t: *PieceTable = @ptrCast(@alignCast(pt));

    t.delete(gpa, index) catch |err| switch (err) {
        PieceTable.DeleteError.OutOfMemory => return 1,
        PieceTable.DeleteError.OutOfBounds => return 2,
    };

    return 0;
}

pub export fn pt_render(pt: *PieceTable, buffer: [*:0]u8, buffer_len: usize) i32 {
    var t: *PieceTable = @ptrCast(@alignCast(pt));

    var w: std.Io.Writer = .fixed(buffer[0..buffer_len]);
    _ = t.render(&w) catch |err| switch (err) {
        PieceTable.RenderError.WriteFailed => return 3,
    };

    return 0;
}

pub export fn pt_length(pt: *PieceTable) usize {
    var t: *const PieceTable = @ptrCast(@alignCast(pt));

    return t.length();
}
