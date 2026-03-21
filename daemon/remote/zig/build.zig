const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "daemon version string") orelse "dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "cmuxd-remote",
        .root_module = mod,
    });
    exe.linkLibC();
    configureOpenSSL(exe);
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    unit_tests.linkLibC();
    configureOpenSSL(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);
}

fn configureOpenSSL(step: *std.Build.Step.Compile) void {
    const include_candidates = [_][]const u8{
        "/opt/homebrew/include",
        "/opt/homebrew/opt/openssl@3/include",
        "/usr/local/include",
        "/usr/local/opt/openssl@3/include",
    };
    for (include_candidates) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        step.root_module.addIncludePath(.{ .cwd_relative = path });
    }

    const lib_candidates = [_][]const u8{
        "/opt/homebrew/lib",
        "/opt/homebrew/opt/openssl@3/lib",
        "/usr/local/lib",
        "/usr/local/opt/openssl@3/lib",
    };
    for (lib_candidates) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        step.addLibraryPath(.{ .cwd_relative = path });
    }

    step.linkSystemLibrary("ssl");
    step.linkSystemLibrary("crypto");
}
