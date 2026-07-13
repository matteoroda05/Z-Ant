const std = @import("std");
const builtin = @import("builtin");

const arm_profiles = @import("arm_profiles.zig");

pub const ArmProfileId = arm_profiles.ArmProfileId;
pub const ArmProfile = arm_profiles.ArmProfile;

pub const ArmToolchainProvider = enum {
    managed,
    external,
};

/// Paths discovered from a complete Arm GNU toolchain. These values are kept in
/// the build layer for the next integration step; they are not runtime options.
pub const ResolvedArmToolchain = struct {
    root: []const u8,
    compiler: []const u8,
    gcc_include: []const u8,
    newlib_include: []const u8,
    libc_a: []const u8,
    libm_a: []const u8,
    libgcc: []const u8,
};

/// Shared configuration parsed before the rest of the Z-Ant build options.
pub const ArmBuildConfig = struct {
    profile: ?ArmProfile,
    target_query: std.Target.Query,
    legacy_cpu_hint: []const u8,
    provider: ArmToolchainProvider,
    toolchain: ?ResolvedArmToolchain,

    pub fn init(b: *std.Build) ArmConfigError!ArmBuildConfig {
        const profile_id = b.option(ArmProfileId, "arm_profile", "Cortex-M Arm profile");
        const provider_option = b.option(ArmToolchainProvider, "arm_toolchain", "Arm toolchain provider: managed or external");
        const toolchain_path = b.option([]const u8, "arm_toolchain_path", "Absolute root of an external Arm toolchain");
        const target_option = b.option([]const u8, "target", "Target architecture (e.g., thumb-freestanding)");
        const cpu_option = b.option([]const u8, "cpu", "CPU model (e.g., cortex_m33)");

        const profile = if (profile_id) |id| arm_profiles.lookup(id) else null;
        validateArmOptions(profile, target_option, cpu_option, provider_option, toolchain_path) catch |err| {
            logArmOptionError(err, profile, target_option, cpu_option);
            return err;
        };

        const provider = provider_option orelse .managed;
        const target_query = if (profile) |selected_profile|
            selected_profile.targetQuery() catch |err| {
                std.log.err("could not construct the Zig target query for Arm profile '{s}': {s}", .{
                    @tagName(selected_profile.id),
                    @errorName(err),
                });
                return error.InvalidTarget;
            }
        else
            parseLegacyTargetQuery(target_option, cpu_option) catch |err| return err;

        const resolved_toolchain = if (profile) |selected_profile|
            resolveToolchain(b, provider, toolchain_path, selected_profile) catch |err| return err
        else
            null;

        return .{
            .profile = profile,
            .target_query = target_query,
            .legacy_cpu_hint = cpu_option orelse "",
            .provider = provider,
            .toolchain = resolved_toolchain,
        };
    }
};

pub const ArmConfigError = error{
    ArmProviderWithoutProfile,
    ArmToolchainPathWithoutProfile,
    ManagedToolchainPathNotAllowed,
    ExternalToolchainPathRequired,
    ExternalToolchainPathNotAbsolute,
    ConflictingArmTarget,
    ConflictingArmCpu,
    InvalidTarget,
    UnsupportedManagedHost,
    InvalidManagedManifest,
    InvalidArmToolchain,
    CompilerQueryFailed,
    OutOfMemory,
};

/// Validates only option relationships. Keeping this pure makes profile and
/// option behaviour testable without an installed Arm toolchain.
pub fn validateArmOptions(
    profile: ?ArmProfile,
    target_option: ?[]const u8,
    cpu_option: ?[]const u8,
    provider_option: ?ArmToolchainProvider,
    toolchain_path: ?[]const u8,
) ArmConfigError!void {
    if (profile) |selected_profile| {
        if (target_option) |target| {
            if (!std.mem.eql(u8, target, selected_profile.zig_target)) {
                return error.ConflictingArmTarget;
            }
        }

        if (cpu_option) |cpu| {
            if (!std.mem.eql(u8, cpu, selected_profile.zig_cpu_features)) {
                return error.ConflictingArmCpu;
            }
        }

        switch (provider_option orelse .managed) {
            .managed => {
                if (toolchain_path != null) return error.ManagedToolchainPathNotAllowed;
            },
            .external => {
                const root = toolchain_path orelse return error.ExternalToolchainPathRequired;
                if (!std.fs.path.isAbsolute(root)) return error.ExternalToolchainPathNotAbsolute;
            },
        }
        return;
    }

    if (provider_option != null) return error.ArmProviderWithoutProfile;
    if (toolchain_path != null) return error.ArmToolchainPathWithoutProfile;
}

fn parseLegacyTargetQuery(target_option: ?[]const u8, cpu_option: ?[]const u8) ArmConfigError!std.Target.Query {
    const target = target_option orelse "native";
    const is_native_target = std.mem.eql(u8, target, "native");

    return std.Target.Query.parse(.{
        .arch_os_abi = target,
        .cpu_features = if (is_native_target) null else cpu_option,
    }) catch |err| {
        std.log.err("could not parse legacy target '{s}': {s}", .{ target, @errorName(err) });
        return error.InvalidTarget;
    };
}

fn logArmOptionError(
    err: ArmConfigError,
    profile: ?ArmProfile,
    target_option: ?[]const u8,
    cpu_option: ?[]const u8,
) void {
    switch (err) {
        error.ArmProviderWithoutProfile => std.log.err("-Darm_toolchain requires -Darm_profile=<profile>", .{}),
        error.ArmToolchainPathWithoutProfile => std.log.err("-Darm_toolchain_path requires -Darm_profile=<profile>", .{}),
        error.ManagedToolchainPathNotAllowed => std.log.err("-Darm_toolchain_path is valid only with -Darm_toolchain=external", .{}),
        error.ExternalToolchainPathRequired => std.log.err("-Darm_toolchain=external requires -Darm_toolchain_path=<absolute-path>", .{}),
        error.ExternalToolchainPathNotAbsolute => std.log.err("-Darm_toolchain_path must be an absolute toolchain root", .{}),
        error.ConflictingArmTarget => std.log.err("Arm profile '{s}' requires -Dtarget={s}, but received -Dtarget={s}", .{
            @tagName(profile.?.id),
            profile.?.zig_target,
            target_option.?,
        }),
        error.ConflictingArmCpu => std.log.err("Arm profile '{s}' requires -Dcpu={s}, but received -Dcpu={s}", .{
            @tagName(profile.?.id),
            profile.?.zig_cpu_features,
            cpu_option.?,
        }),
        else => {},
    }
}

fn resolveToolchain(
    b: *std.Build,
    provider: ArmToolchainProvider,
    external_root: ?[]const u8,
    profile: ArmProfile,
) ArmConfigError!ResolvedArmToolchain {
    const source = switch (provider) {
        .managed => try managedToolchainSource(b),
        .external => blk: {
            const root = external_root orelse return error.ExternalToolchainPathRequired;
            break :blk ToolchainSource{
                .root = root,
                .compiler = b.pathJoin(&.{ root, externalCompilerRelativePath() }),
                .managed_release = null,
            };
        },
    };

    try requireDirectory(source.root, "toolchain root");
    try requireFile(source.compiler, "arm-none-eabi-gcc compiler");

    const dumpmachine = try runCompiler(b, source.compiler, null, "-dumpmachine", "compiler target");
    if (!std.mem.eql(u8, dumpmachine, "arm-none-eabi")) {
        return failToolchainTarget(source.compiler, dumpmachine);
    }

    if (source.managed_release) |release| {
        const version = try runCompiler(b, source.compiler, null, "--version", "managed compiler version");
        if (std.mem.indexOf(u8, version, release) == null) {
            return failManagedVersion(source.compiler, release, version);
        }
    }

    const gcc_include = try queryResolvedDirectory(b, source.compiler, profile, "-print-file-name=include", "GCC include directory", "include");
    const libc_a = try queryResolvedFile(b, source.compiler, profile, "-print-file-name=libc.a", "libc.a", "libc.a");
    const libm_a = try queryResolvedFile(b, source.compiler, profile, "-print-file-name=libm.a", "libm.a", "libm.a");
    const libgcc = try queryResolvedFile(b, source.compiler, profile, "-print-libgcc-file-name", "libgcc", "libgcc.a");
    const newlib_include = try resolveNewlibInclude(b, source.root, source.compiler, profile);

    return .{
        .root = source.root,
        .compiler = source.compiler,
        .gcc_include = gcc_include,
        .newlib_include = newlib_include,
        .libc_a = libc_a,
        .libm_a = libm_a,
        .libgcc = libgcc,
    };
}

const ToolchainSource = struct {
    root: []const u8,
    compiler: []const u8,
    managed_release: ?[]const u8,
};

fn managedToolchainSource(b: *std.Build) ArmConfigError!ToolchainSource {
    const host_key = managedHostKey() orelse {
        std.log.err("no managed Arm GNU Toolchain package is pinned for this host. Use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>", .{});
        return error.UnsupportedManagedHost;
    };

    const manifest_path = b.pathFromRoot("scripts/toolchains/arm_gnu_toolchain_15_2_rel1.json");
    const manifest_contents = std.fs.cwd().readFileAlloc(b.allocator, manifest_path, 1024 * 1024) catch |err| {
        std.log.err("could not read managed Arm toolchain manifest '{s}': {s}", .{ manifest_path, @errorName(err) });
        return error.InvalidManagedManifest;
    };
    defer b.allocator.free(manifest_contents);

    const Manifest = struct {
        release: []const u8,
        target: []const u8,
        hosts: std.json.Value,
    };
    const HostEntry = struct {
        install_directory: []const u8,
        compiler: []const u8,
    };

    var parsed_manifest = std.json.parseFromSlice(Manifest, b.allocator, manifest_contents, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.err("managed Arm toolchain manifest is invalid: {s}", .{@errorName(err)});
        return error.InvalidManagedManifest;
    };
    defer parsed_manifest.deinit();

    if (!std.mem.eql(u8, parsed_manifest.value.target, "arm-none-eabi")) {
        std.log.err("managed Arm toolchain manifest must target arm-none-eabi", .{});
        return error.InvalidManagedManifest;
    }

    const hosts = switch (parsed_manifest.value.hosts) {
        .object => |object| object,
        else => {
            std.log.err("managed Arm toolchain manifest has no hosts object", .{});
            return error.InvalidManagedManifest;
        },
    };
    const host_value = hosts.get(host_key) orelse {
        std.log.err("managed Arm toolchain manifest has no package for host '{s}'", .{host_key});
        return error.InvalidManagedManifest;
    };
    var parsed_host = std.json.parseFromValue(HostEntry, b.allocator, host_value, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.err("managed Arm toolchain manifest entry for '{s}' is invalid: {s}", .{ host_key, @errorName(err) });
        return error.InvalidManagedManifest;
    };
    defer parsed_host.deinit();

    const root = b.pathJoin(&.{
        b.pathFromRoot("third_party/toolchains"),
        parsed_host.value.install_directory,
    });
    const compiler = b.pathJoin(&.{ root, parsed_host.value.compiler });

    return .{
        .root = root,
        .compiler = compiler,
        .managed_release = try b.allocator.dupe(u8, parsed_manifest.value.release),
    };
}

fn managedHostKey() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x86_64",
            .x86 => "windows-x86",
            else => null,
        },
        else => null,
    };
}

fn externalCompilerRelativePath() []const u8 {
    return if (builtin.os.tag == .windows) "bin/arm-none-eabi-gcc.exe" else "bin/arm-none-eabi-gcc";
}

fn resolveNewlibInclude(
    b: *std.Build,
    root: []const u8,
    compiler: []const u8,
    profile: ArmProfile,
) ArmConfigError![]const u8 {
    const sysroot = try runCompiler(b, compiler, profile, "-print-sysroot", "sysroot");
    if (sysroot.len != 0 and std.fs.path.isAbsolute(sysroot) and directoryExists(sysroot)) {
        const sysroot_include = b.pathJoin(&.{ sysroot, "include" });
        const sysroot_string_h = b.pathJoin(&.{ sysroot_include, "string.h" });
        if (directoryExists(sysroot_include) and fileExists(sysroot_string_h)) {
            return sysroot_include;
        }
    }

    const fallback_include = b.pathJoin(&.{ root, "arm-none-eabi", "include" });
    try requireDirectory(fallback_include, "newlib include directory");
    const string_h = b.pathJoin(&.{ fallback_include, "string.h" });
    try requireFile(string_h, "newlib string.h");
    return fallback_include;
}

fn queryResolvedDirectory(
    b: *std.Build,
    compiler: []const u8,
    profile: ArmProfile,
    query: []const u8,
    component: []const u8,
    unresolved_name: []const u8,
) ArmConfigError![]const u8 {
    const path = try runCompiler(b, compiler, profile, query, component);
    try requireResolvedPath(path, component, unresolved_name, true);
    return path;
}

fn queryResolvedFile(
    b: *std.Build,
    compiler: []const u8,
    profile: ArmProfile,
    query: []const u8,
    component: []const u8,
    unresolved_name: []const u8,
) ArmConfigError![]const u8 {
    const path = try runCompiler(b, compiler, profile, query, component);
    try requireResolvedPath(path, component, unresolved_name, false);
    return path;
}

fn runCompiler(
    b: *std.Build,
    compiler: []const u8,
    profile: ?ArmProfile,
    query: []const u8,
    component: []const u8,
) ArmConfigError![]const u8 {
    var argv: [6][]const u8 = undefined;
    var len: usize = 0;
    argv[len] = compiler;
    len += 1;
    if (profile) |selected_profile| {
        for (selected_profile.gnu_flags) |flag| {
            argv[len] = flag;
            len += 1;
        }
    }
    argv[len] = query;
    len += 1;

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv[0..len],
    }) catch |err| {
        std.log.err("Arm toolchain validation failed while querying {s} with '{s}': {s}. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{
            component,
            compiler,
            @errorName(err),
        });
        return error.CompilerQueryFailed;
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {} else {
                return failCompilerQuery(component, compiler, result.term, result.stderr);
            }
        },
        else => return failCompilerQuery(component, compiler, result.term, result.stderr),
    }

    const output = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (output.len == 0) {
        std.log.err("Arm toolchain validation failed: compiler '{s}' returned no value for {s}. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{ compiler, component });
        return error.CompilerQueryFailed;
    }
    return b.allocator.dupe(u8, output) catch return error.OutOfMemory;
}

fn requireResolvedPath(
    path: []const u8,
    component: []const u8,
    unresolved_name: []const u8,
    directory: bool,
) ArmConfigError!void {
    if (std.mem.eql(u8, path, unresolved_name) or !std.fs.path.isAbsolute(path)) {
        return failUnresolvedPath(component, path);
    }

    if (directory) {
        try requireDirectory(path, component);
    } else {
        try requireFile(path, component);
    }
}

fn requireDirectory(path: []const u8, component: []const u8) ArmConfigError!void {
    if (!directoryExists(path)) return failMissingPath(component, path);
}

fn requireFile(path: []const u8, component: []const u8) ArmConfigError!void {
    if (!fileExists(path)) return failMissingPath(component, path);
}

fn directoryExists(path: []const u8) bool {
    var directory = std.fs.openDirAbsolute(path, .{}) catch return false;
    directory.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn failMissingPath(component: []const u8, path: []const u8) ArmConfigError {
    std.log.err("Arm toolchain validation failed: missing {s} at '{s}'. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{ component, path });
    return error.InvalidArmToolchain;
}

fn failUnresolvedPath(component: []const u8, path: []const u8) ArmConfigError {
    std.log.err("Arm toolchain validation failed: {s} resolved to unusable path '{s}'. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{ component, path });
    return error.InvalidArmToolchain;
}

fn failToolchainTarget(compiler: []const u8, target: []const u8) ArmConfigError {
    std.log.err("Arm toolchain validation failed: compiler '{s}' reports target '{s}', expected arm-none-eabi. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{ compiler, target });
    return error.InvalidArmToolchain;
}

fn failManagedVersion(compiler: []const u8, release: []const u8, version: []const u8) ArmConfigError {
    std.log.err("Arm toolchain validation failed: managed compiler '{s}' must identify release {s}, but reported '{s}'. Run ./scripts/fetch_arm_toolchain.py --force or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{ compiler, release, version });
    return error.InvalidArmToolchain;
}

fn failCompilerQuery(
    component: []const u8,
    compiler: []const u8,
    term: std.process.Child.Term,
    stderr: []const u8,
) ArmConfigError {
    const detail = std.mem.trim(u8, stderr, " \t\r\n");
    std.log.err("Arm toolchain validation failed while querying {s} with '{s}' ({any}): {s}. Run ./scripts/fetch_arm_toolchain.py for the managed toolchain or use -Darm_toolchain=external -Darm_toolchain_path=<absolute-path>.", .{
        component,
        compiler,
        term,
        if (detail.len == 0) "no compiler output" else detail,
    });
    return error.CompilerQueryFailed;
}

test "Arm option validation preserves legacy mode without Arm provider options" {
    try validateArmOptions(null, null, null, null, null);
}

test "Arm option validation accepts exact profile overrides" {
    const profile = arm_profiles.lookup(.cortex_m7_fpv5_d16_softfp);
    try validateArmOptions(
        profile,
        "thumb-freestanding-eabi",
        "cortex_m7+fp_armv8d16",
        .external,
        "/opt/arm-gnu-toolchain",
    );
}

test "Arm option validation rejects conflicting profile target and CPU" {
    const profile = arm_profiles.lookup(.cortex_m4_fpv4_sp_d16_softfp);

    try std.testing.expectError(
        error.ConflictingArmTarget,
        validateArmOptions(profile, "native", null, null, null),
    );
    try std.testing.expectError(
        error.ConflictingArmCpu,
        validateArmOptions(profile, null, "cortex_m4", null, null),
    );
}

test "Arm option validation requires an absolute external root" {
    const profile = arm_profiles.lookup(.cortex_m7_fpv5_d16_softfp);

    try std.testing.expectError(
        error.ExternalToolchainPathRequired,
        validateArmOptions(profile, null, null, .external, null),
    );
    try std.testing.expectError(
        error.ExternalToolchainPathNotAbsolute,
        validateArmOptions(profile, null, null, .external, "relative/toolchain"),
    );
}

test "Arm provider options are rejected without a profile" {
    try std.testing.expectError(
        error.ArmProviderWithoutProfile,
        validateArmOptions(null, null, null, .managed, null),
    );
    try std.testing.expectError(
        error.ArmToolchainPathWithoutProfile,
        validateArmOptions(null, null, null, null, "/opt/arm-gnu-toolchain"),
    );
}
