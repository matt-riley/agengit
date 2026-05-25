const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_c = b.option(std.zig.SanitizeC, "sanitize-c", "Enable C-family undefined behavior sanitizers") orelse .full;

    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const hook_module = b.createModule(.{
        .root_source_file = b.path("src/hook.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    const test_support_module = b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
        },
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .imports = &.{
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "agit",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run agit");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .imports = &.{
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/all.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        }),
    });

    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.step.dependOn(b.getInstallStep());

    const test_e2e_step = b.step("test-e2e", "Run end-to-end tests");
    test_e2e_step.dependOn(&run_e2e_tests.step);

    const property_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/property/all.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .imports = &.{
                .{ .name = "test_support", .module = test_support_module },
            },
        }),
    });
    const run_property_tests = b.addRunArtifact(property_tests);
    const test_property_step = b.step("test-property", "Run property-based recorder/reindex tests");
    test_property_step.dependOn(&run_property_tests.step);

    const durable_bench = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/durable.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .imports = &.{
                .{
                    .name = "fs_util",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/util/fs.zig"),
                        .target = target,
                        .optimize = optimize,
                        .sanitize_c = sanitize_c,
                    }),
                },
            },
        }),
    });
    const run_durable_bench = b.addRunArtifact(durable_bench);
    const bench_durable_step = b.step("bench-durable", "Run durable-write microbenchmark");
    bench_durable_step.dependOn(&run_durable_bench.step);

    const fuzz_hooks = b.addExecutable(.{
        .name = "fuzz-hooks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/hooks.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .imports = &.{
                .{ .name = "hook", .module = hook_module },
            },
        }),
    });
    const run_fuzz_hooks = b.addRunArtifact(fuzz_hooks);
    if (b.args) |args| {
        run_fuzz_hooks.addArgs(args);
    }
    const fuzz_hooks_step = b.step("fuzz-hooks", "Run bounded hook payload fuzz harnesses");
    fuzz_hooks_step.dependOn(&run_fuzz_hooks.step);

    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "tests", "bench", "build.zig" },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const check_step = b.step("check-fmt", "Check formatting");
    const check_fmt = b.addFmt(.{
        .paths = &.{ "src", "tests", "bench", "build.zig" },
        .check = true,
    });
    check_step.dependOn(&check_fmt.step);
}
