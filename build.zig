const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32_dep = b.dependency("win32", .{});
    const win32 = win32_dep.module("win32");
    const ddui = b.addModule("ddui", .{
        .root_source_file = b.path("ddui.zig"),
    });
    ddui.addImport("win32", win32);

    {
        const exe = b.addExecutable(.{
            .name = "example",
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .win32_manifest = b.path("example/win32.manifest"),
        });
        exe.subsystem = .Windows;
        exe.root_module.addImport("win32", win32);
        exe.root_module.addImport("ddui", ddui);
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
