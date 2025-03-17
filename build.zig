const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_resid = b.dependency("resid", .{});
    const mod_resid = dep_resid.module("resid");

    const exe = b.addExecutable(.{
        .name = "zid-dump",
        .root_source_file = b.path("src/sidxport.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("resid", mod_resid);
    b.installArtifact(exe);
}
