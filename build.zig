const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "C library link mode") orelse .static;

    const test_filters = b.option([]const []const u8, "test-filters", "Test filter") orelse &.{};

    const mod = b.addModule("piece_table", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "piece_table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "piece_table", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const ffi = b.addLibrary(.{
        .name = "piece_table",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/ffi/ffi.zig"),
            .imports = &.{
                .{ .name = "piece_table", .module = mod },
            },
        }),
    });
    b.installArtifact(ffi);
    const ffi_header = b.path("src/ffi/ffi.h");

    const ffi_step = b.step("ffi", "Build the C library");
    const install_ffi = b.addInstallArtifact(ffi, .{});
    const install_ffi_h = b.addInstallHeaderFile(ffi_header, "piece_table/piece_table.h");
    ffi_step.dependOn(&install_ffi.step);
    ffi_step.dependOn(&install_ffi_h.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
