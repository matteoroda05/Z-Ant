const std = @import("std");

const ArmBuildConfig = @import("arm_toolchain.zig").ArmBuildConfig;
const CmsisFlags = @import("cmsis_flags.zig").Cmsis_flags;

/// Header search paths needed by Zig `@cImport` and C compilation when the
/// CMSIS-NN QLinearConv backend is enabled.
const include_paths = [_][]const u8{
    "third_party/CMSIS-NN",
    "third_party/CMSIS-NN/Include",
    "third_party/CMSIS-NN/Source",
    "third_party/CMSIS_5/CMSIS/Core/Include",
    "third_party/CMSIS-DSP/Include",
    "third_party/CMSIS-DSP/PrivateInclude",
};

/// Baseline C compiler flags for the vendored CMSIS-NN sources.
///
/// These keep builtins available for CMSIS under freestanding targets and
/// compile the C kernels with optimization independent of the surrounding Zig
/// optimization mode.
const c_flags = [_][]const u8{
    "-DOPTIONAL_RESTRICT_KEYWORD=__restrict",
    "-fbuiltin",
    "-O3",
    "-ffast-math",
    "-fno-math-errno",
};

/// Curated source set currently used by the QLinearConv CMSIS-NN vertical slice.
///
/// The list is intentionally centralized here so operator code does not need
/// to know how CMSIS-NN's C implementation is assembled into build artifacts.
const c_sources = [_][]const u8{
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_wrapper_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_1x1_s8_fast.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_1x1_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_1_x_n_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_convolve_get_buffer_sizes_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_depthwise_conv_wrapper_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_depthwise_conv_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_depthwise_conv_3x3_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_depthwise_conv_s8_opt.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_depthwise_conv_get_buffer_sizes_s8.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_nn_mat_mult_kernel_s8_s16.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_nn_mat_mult_kernel_row_offset_s8_s16.c",
    "third_party/CMSIS-NN/Source/ConvolutionFunctions/arm_nn_mat_mult_s8.c",
    "third_party/CMSIS-NN/Source/NNSupportFunctions/arm_nn_mat_mult_nt_t_s8.c",
    "third_party/CMSIS-NN/Source/NNSupportFunctions/arm_nn_vec_mat_mult_t_s8.c",
    "third_party/CMSIS-NN/Source/NNSupportFunctions/arm_q7_to_q15_with_offset.c",
    "third_party/CMSIS-NN/Source/NNSupportFunctions/arm_s8_to_s16_unordered_with_offset.c",
    "third_party/CMSIS-DSP/Source/BasicMathFunctions/arm_dot_prod_f32.c",
};

/// Adds CMSIS and resolved Arm toolchain include paths to a Zig module when the
/// CMSIS backend is selected.
///
/// This is what allows files under `IR_zant` to use `@cImport` for CMSIS
/// headers and lets vendored CMSIS C sources use the selected toolchain's GCC
/// and newlib headers without affecting non-CMSIS builds.
pub fn configureCmsisModuleIncludes(
    b: *std.Build,
    module: *std.Build.Module,
    flags: CmsisFlags,
    arm_build: ArmBuildConfig,
) void {
    if (!cmsisRequested(flags)) return;

    for (include_paths) |path| {
        module.addIncludePath(b.path(path));
    }

    if (arm_build.toolchain) |toolchain| {
        module.addSystemIncludePath(.{ .cwd_relative = toolchain.gcc_include });
        module.addSystemIncludePath(.{ .cwd_relative = toolchain.newlib_include });
    }
}

/// Links the current CMSIS-NN C source set into a runtime artifact when the
/// CMSIS backend is selected.
///
/// This should be applied only to artifacts that may execute CMSIS kernels,
/// such as generated model libraries, generated model tests, benchmarks, and
/// relevant IR/runtime tests. This does not attach the toolchain's libc, libm,
/// or libgcc archives.
pub fn configureCmsisRuntimeArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    flags: CmsisFlags,
    arm_build: ArmBuildConfig,
) void {
    if (!cmsisRequested(flags)) return;

    configureCmsisModuleIncludes(b, artifact.root_module, flags, arm_build);
    artifact.root_module.addCSourceFiles(.{
        .root = b.path(""),
        .files = &c_sources,
        .flags = &c_flags,
        .language = .c,
    });
    artifact.linkLibC();
}

/// Mirrors the runtime CMSIS gate at build time so include paths and C sources
/// are only attached for requested Cortex-M CMSIS builds.
fn cmsisRequested(flags: CmsisFlags) bool {
    return flags.enable_cmsis and flags.target_is_cortex_m;
}
