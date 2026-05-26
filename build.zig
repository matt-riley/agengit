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

    const resolve_prefix_bench = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/resolve_prefix.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .imports = &.{
                .{ .name = "test_support", .module = test_support_module },
            },
        }),
    });
    const run_resolve_prefix_bench = b.addRunArtifact(resolve_prefix_bench);
    if (b.args) |args| {
        run_resolve_prefix_bench.addArgs(args);
    }
    const bench_resolve_prefix_step = b.step("bench-resolve-prefix", "Run object-prefix resolution benchmark");
    bench_resolve_prefix_step.dependOn(&run_resolve_prefix_bench.step);

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

    const check_docs = b.addExecutable(.{
        .name = "check-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_docs.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        }),
    });
    const run_check_docs = b.addRunArtifact(check_docs);
    const check_docs_step = b.step("check-docs", "Check markdown links");
    check_docs_step.dependOn(&run_check_docs.step);

    const check_config = b.addExecutable(.{
        .name = "check-config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_config.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        }),
    });
    const run_check_config = b.addRunArtifact(check_config);
    const check_config_step = b.step("check-config", "Validate release metadata config");
    check_config_step.dependOn(&run_check_config.step);

    const fmt_paths = &.{ "src", "tests", "bench", "tools", "build.zig", "build.zig.zon" };

    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = fmt_paths,
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const check_step = b.step("check-fmt", "Check formatting");
    const check_fmt = b.addFmt(.{
        .paths = fmt_paths,
        .check = true,
    });
    check_step.dependOn(&check_fmt.step);

    const verify_step = b.step("check", "Run format, docs, config, and unit checks");
    verify_step.dependOn(check_step);
    verify_step.dependOn(check_docs_step);
    verify_step.dependOn(check_config_step);
    verify_step.dependOn(test_step);
}
