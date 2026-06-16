// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const ztl = @import("ztl");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Logger = @import("Logger.zig");
const Report = @import("Report");
const Timestamp = @import("Timestamp.zig");
const ZigProcess = @import("ZigProcess.zig");

const location = @import("location.zig");
const reporter = @import("reporter.zig");
const setup = @import("setup.zig");
const args_mod = @import("args.zig");

const version: std.SemanticVersion = .{ .major = 0, .minor = 3, .patch = 0 };

fn printHelp(writer: std.io.AnyWriter) void {
    writer.print(
        \\zig-ebuilder {[version]}
        \\System package managers specification generator for Zig projects.
        \\
        \\USAGE:
        \\    {[prog_name]s} [OPTIONS] [path-to-project]
        \\
        \\ARGUMENTS:
        \\    [path-to-project]             build.zig file, or directory containing it
        \\                                  (default: current directory)
        \\
        \\GENERATOR OPTIONS:
        \\    --fetch <strategy>            Dependency resolution strategy (default: plain)
        \\                                  (possible values: none, plain, hashed)
        \\    --template <template>         ZTL template to use (default: gentoo.ebuild)
        \\                                  (possible values: gentoo.ebuild, [custom file path])
        \\    --output-file <path>          Output file (default: depends on project's name and version)
        \\                                  Warning: overwrites file if already exists.
        \\                                  Note: "-" means "output to STDOUT"
        \\
        \\ZIG OPTIONS:
        \\    --zig <path-to-exe>           Path to Zig executable (default: get from PATH)
        \\    --zig-build-args <args>...    Additional arguments for "zig build"
        \\
        \\LOGGING OPTIONS:
        \\    --log-level <level>           Minimum logging level (default: info)
        \\                                  (possible values: err, warn, info, debug)
        \\    --log-time-format <format>    Show time in this format (default: none)
        \\                                  (possible values: none, time, day_time)
        \\    --log-color <when>            Color output mode (default: auto)
        \\                                  (possible values: auto, always, never)
        \\    --log-src-location <when>     Show source location (default: never)
        \\                                  (possible values: always, never)
        \\
        \\GENERAL OPTIONS:
        \\    --help                        Display this help and exit
        \\
        \\NOTES:
        \\ * If "build.zig.zon" file exist, dependencies will be
        \\ resolved from it according to the `--fetch` strategy.
        \\ * 'hashed' fetch strategy needs Zig patching, see README for more info.
        \\
    , .{ .version = version, .prog_name = global.prog_name }) catch {};
}

var global: struct {
    prog_name: [:0]const u8,
    zig_executable: [:0]const u8,
    fetch_mode: Dependencies.FetchMode,
} = .{
    .prog_name = "(name not provided)",
    .zig_executable = "zig",
    .fetch_mode = .plain,
};

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .enable_memory_limit = true,
        .thread_safe = true,
    }) = .init;
    defer switch (gpa_instance.deinit()) {
        .ok => {},
        .leak => @panic("Memory leak detected!"),
    };
    const gpa = gpa_instance.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    // For consistent output of "reuse lint" and "reuse spdx"
    try env_map.put("LC_ALL", "en_US.UTF-8");

    const stdout_file = std.io.getStdOut();
    const stderr_file = std.io.getStdErr();
    const stdout = stdout_file.writer().any();
    const stderr = stderr_file.writer().any();

    var parsed_args = (try args_mod.parse(gpa, stderr)) orelse return;
    defer parsed_args.deinit(gpa);

    if (parsed_args.help) {
        printHelp(stdout);
        return;
    }

    global.prog_name = parsed_args.prog_name;
    global.zig_executable = parsed_args.zig_executable;
    global.fetch_mode = parsed_args.fetch_mode;

    const zig_build_additional_args = parsed_args.zig_build_additional_args;
    const optional_custom_template_path = parsed_args.optional_custom_template_path;
    const file_name = parsed_args.project_path;

    const cwd: location.Dir = .cwd();
    var output_file: ?union(enum) {
        stdout,
        file: location.File,
    } = if (parsed_args.output_file_path) |path|
        if (std.mem.eql(u8, path, "-"))
            .stdout
        else
            .{ .file = cwd.createFile(gpa, path) catch |err| {
                stderr.print("Error when creating output file '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
                return;
            } }
    else
        null;
    defer switch (output_file orelse .stdout) {
        .stdout => {},
        .file => |file| file.deinit(gpa),
    };

    var main_log: Logger = .{
        .shared = &.{ .scretch_pad = gpa },
        .scopes = &.{},
    };

    main_log.info(@src(), "Starting {s} {}", .{ global.prog_name, version });

    var setup_events = try main_log.child("setup");
    defer setup_events.deinit();

    const initial_file_path: []const u8 = if (file_name) |path| blk: {
        const stat = cwd.dir.statFile(path) catch |err| switch (err) {
            error.IsDir => {
                setup_events.info(@src(), "\"{s}\" is a directory, trying to find \"build.zig\" file inside...", .{path});
                break :blk try std.fs.path.join(gpa, &.{ path, "build.zig" });
            },
            error.FileNotFound => {
                setup_events.err(@src(), "File or directory \"{s}\" not found.", .{path});
                return err;
            },
            else => |e| {
                setup_events.err(@src(), "Error when checking type of \"{s}\": {s}.", .{ path, @errorName(e) });
                return e;
            },
        };

        if (stat.kind == .directory) {
            setup_events.info(@src(), "\"{s}\" is a directory, trying to find \"build.zig\" file inside...", .{path});
            break :blk try std.fs.path.join(gpa, &.{ path, "build.zig" });
        } else {
            setup_events.info(@src(), "\"{s}\" is a file, trying to open it...", .{path});
            break :blk try gpa.dupe(u8, path);
        }
    } else cwd: {
        setup_events.info(@src(), "No location given, trying to open \"build.zig\" in current directory...", .{});
        break :cwd try gpa.dupe(u8, "build.zig");
    };
    defer gpa.free(initial_file_path);

    var project_setup: setup.Project = try .open(
        cwd,
        initial_file_path,
        gpa,
        setup_events,
    );
    defer project_setup.deinit(gpa);

    setup_events.info(@src(), "Successfully found \"build.zig\" file!", .{});

    const zig_process = try ZigProcess.init(gpa, cwd, global.zig_executable, &env_map, setup_events);
    defer gpa.free(zig_process.version.raw_string);

    var generator_setup: setup.Generator = try .makeOpen(cwd, env_map, gpa, setup_events);
    defer generator_setup.deinit(gpa);

    const template_text = if (optional_custom_template_path) |custom_template_path|
        cwd.dir.readFileAlloc(gpa, custom_template_path, 1 * 1024 * 1024) catch |err| {
            setup_events.err(@src(), "Error when searching custom template: {s} caused by \"{s}\".", .{ @errorName(err), custom_template_path });

            return error.InvalidTemplate;
        }
    else
        generator_setup.templates.dir.readFileAlloc(gpa, "gentoo.ebuild.ztl", 1 * 1024 * 1024) catch |err| {
            setup_events.err(@src(), "Error when searching gentoo.ebuild template: \"{s}\".", .{@errorName(err)});

            return error.InvalidTemplate;
        };
    defer gpa.free(template_text);

    var template: ztl.Template(void) = .init(gpa, {});
    defer template.deinit();

    var template_errors: ztl.CompileErrorReport = .{};
    template.compile(template_text, .{ .error_report = &template_errors }) catch |err| {
        setup_events.err(@src(), "Error when loading template: {s} caused by \"{s}\": {}", .{
            @errorName(err),
            if (optional_custom_template_path) |custom_template_path| custom_template_path else "(default template)",
            template_errors,
        });
        return error.InvalidTemplate;
    };

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const manifest: ?BuildZigZon = if (project_setup.build_zig_zon) |build_zig_zon_loc| parse: {
        main_log.info(@src(), "Found \"build.zig.zon\" file nearby.", .{});
        break :parse try .read(arena, zig_process.version, build_zig_zon_loc, main_log);
    } else nothing: {
        main_log.warn(@src(), "\"build.zig.zon\" was not found.", .{});
        break :nothing null;
    };

    const project_name, const project_version, const project_summary = if (manifest != null) .{ manifest.?.name, manifest.?.version_raw, manifest.?.summary } else .{ "unknown", "0.0.0", null };

    const dependencies: Dependencies = if (global.fetch_mode != .none and manifest != null) fetch: {
        main_log.info(@src(), "Proceeding to fetch dependencies.", .{});

        var fetch_events = try main_log.child("fetch");
        defer fetch_events.deinit();

        break :fetch try .collect(
            arena,
            //
            project_setup,
            manifest.?,
            generator_setup,
            fetch_events,
            global.fetch_mode,
            zig_process,
        );
    } else nothing: {
        main_log.warn(@src(), "Skipping fetching.", .{});
        break :nothing .empty;
    };

    main_log.info(@src(), "Packages count: {d}", .{dependencies.packages.len});
    main_log.debug(
        @src(),
        "packages = {}",
        .{std.json.fmt(dependencies.packages, .{ .whitespace = .indent_4 })},
    );

    var git_commit_packages_count: usize = 0;
    for (dependencies.packages) |package| switch (package.kind) {
        .tarball => continue,
        .git_ref => git_commit_packages_count += 1,
    };

    const optional_tarball_tarball: ?[]const u8 = if (git_commit_packages_count > 0) path: {
        var archive_arena_instance: std.heap.ArenaAllocator = .init(gpa);
        const archive_arena = archive_arena_instance.allocator();
        defer archive_arena_instance.deinit();

        const tarball_tarball_path = try std.fmt.allocPrint(
            archive_arena,
            "{s}-{s}-git_dependencies.tar.gz",
            .{ project_name, project_version },
        );

        main_log.warn(@src(), "Found dependencies that were not translated from Git commit to tarball format: {d} items. Packing them into one archive...", .{git_commit_packages_count});
        main_log.warn(@src(), "Packing them into one archive {s} ...", .{tarball_tarball_path});

        var tarballs_loc = try generator_setup.cache.makeOpenDir(archive_arena, "git_commit_tarballs");
        defer tarballs_loc.deinit(archive_arena);

        var memory: std.ArrayListUnmanaged(u8) = .empty;
        const memory_writer = memory.writer(archive_arena);

        try Dependencies.pack_git_commits_to_tarball_tarball(
            archive_arena,
            zig_process.version,
            dependencies.packages,
            generator_setup.packages,
            memory_writer,
            main_log,
        );

        main_log.warn(@src(), "Writing to disk...", .{});
        try tarballs_loc.dir.writeFile(.{
            .sub_path = tarball_tarball_path,
            .data = memory.items,
        });

        break :path try std.fs.path.join(arena, &.{ tarballs_loc.string, tarball_tarball_path });
    } else null;

    const report: Report = try reporter.collect(
        gpa,
        //
        &env_map,
        generator_setup,
        main_log,
        zig_build_additional_args,
        project_setup,
        zig_process,
        arena,
    );

    const DownloadableDependency = struct {
        name: []const u8,
        url: []const u8,
        // with_args: []const []const []const u8,
    };

    const downloadable_dependencies = downloadable_dependencies: {
        var tarballs: std.ArrayListUnmanaged(DownloadableDependency) = try .initCapacity(arena, dependencies.packages.len);
        defer tarballs.deinit(arena);
        var git_commits: std.ArrayListUnmanaged(DownloadableDependency) = try .initCapacity(arena, dependencies.packages.len);
        defer git_commits.deinit(arena);

        const new_package_hash_format = zig_process.version.newPackageFormat();

        for (dependencies.packages) |package| {
            const used = check_hash: {
                for (report.used_dependencies_hashes) |used_hash| {
                    if (std.mem.eql(u8, package.hash, used_hash))
                        break :check_hash true;
                } else break :check_hash false;
            };
            _ = used;

            switch (package.kind) {
                .tarball => |kind| {
                    // New package hash format in 0.14 already has name
                    const dependency_file_name = try if (new_package_hash_format)
                        std.fmt.allocPrint(
                            arena,
                            "{s}.{s}",
                            .{ package.hash, @tagName(kind) },
                        )
                    else
                        std.fmt.allocPrint(
                            arena,
                            "{s}-{s}.{s}",
                            .{ package.name orelse "pristine_package", package.hash, @tagName(kind) },
                        );

                    tarballs.appendAssumeCapacity(.{
                        .name = dependency_file_name,
                        .url = try std.fmt.allocPrint(arena, "{}", .{package.uri}),
                    });
                },
                .git_ref => {
                    // New package hash format in 0.14 already has "pristine" notion: N-V
                    const dependency_file_name = if (new_package_hash_format)
                        try std.fmt.allocPrint(
                            arena,
                            "{s}.tar.gz",
                            .{package.hash},
                        )
                    else
                        try std.fmt.allocPrint(
                            arena,
                            "{s}-{s}.tar.gz",
                            .{ package.name orelse "pristine_package", package.hash },
                        );

                    git_commits.appendAssumeCapacity(.{
                        // Assume they are in tarball-tarball already.
                        .name = dependency_file_name,
                        .url = "",
                    });
                },
            }
        }

        break :downloadable_dependencies .{
            .tarball = try tarballs.toOwnedSlice(arena),
            .git_commits = try git_commits.toOwnedSlice(arena),
        };
    };

    const context = .{
        .generator_version = try std.fmt.allocPrint(gpa, "{}", .{version}),
        .year = year: {
            const time: Timestamp = .now();
            break :year time.year;
        },
        .zig_slot = switch (zig_process.version.kind) {
            .live => "9999",
            .release => try std.fmt.allocPrint(arena, "{d}.{d}", .{ zig_process.version.sem_ver.major, zig_process.version.sem_ver.minor }),
        },
        .summary = project_summary,
        .dependencies = downloadable_dependencies,
        .tarball_tarball = optional_tarball_tarball,
        .report = report,
    };
    defer gpa.free(context.generator_version);

    if (output_file == null) {
        main_log.warn(@src(), "\"--output-file\" option was not passed, trying to generate file name...", .{});

        const name = try std.fmt.allocPrint(arena, "{s}-{s}.ebuild", .{ project_name, project_version });
        for (name[0..project_name.len]) |*c|
            switch (c.*) {
                '_' => c.* = '-',
                else => {},
            };

        main_log.warn(@src(), "Generated file name: '{s}'", .{name});
        output_file = .{ .file = cwd.createFile(gpa, name) catch |err| {
            main_log.err(@src(), "Error when creating output file '{s}': {s}\n", .{ name, @errorName(err) });
            return;
        } };
    }

    var render_errors: ztl.RenderErrorReport = .{};
    defer render_errors.deinit();

    const output_writer = switch (output_file.?) {
        .file => |file| file: {
            main_log.info(@src(), "Writing ebuild to '{s}'...", .{file.string});
            break :file file.file.writer().any();
        },
        .stdout => stdout: {
            main_log.info(@src(), "Writing ebuild to the STDOUT...", .{});
            break :stdout stdout;
        },
    };

    template.render(output_writer, context, .{ .error_report = &render_errors }) catch |err| {
        main_log.err(@src(), "Error when writing ebuild: {s} caused by: {}", .{
            @errorName(err),
            render_errors,
        });
        return error.InvalidTemplate;
    };

    main_log.info(@src(), "Ebuild was generated successfully.", .{});

    if (optional_tarball_tarball) |tarball_tarball_path| {
        main_log.warn(@src(), "Note: it appears your project has Git commit dependencies that generator was unable to convert.", .{});
        main_log.warn(@src(), "Please host \"{s}\" somewhere and add it to SRC_URI.", .{tarball_tarball_path});
    }
}

test {
    _ = @import("args.zig");
}
