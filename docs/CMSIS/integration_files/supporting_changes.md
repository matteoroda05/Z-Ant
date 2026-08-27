# CMSIS-NN Supporting Changes

This document covers CMSIS-NN integration changes outside the dedicated CMSIS
files documented in this directory, including:

- `zantBuild/cmsis_flags.zig`
- `zantBuild/arm_profiles.zig`
- `zantBuild/arm_toolchain.zig`
- `zantBuild/zantOptions.zig`
- `build.zig`
- `src/codegen/IR_zant/cmsis/mod_cmsis.zig`
- `src/codegen/IR_zant/cmsis/layout.zig`
- `src/codegen/IR_zant/cmsis/parameter_codegen.zig`
- `src/codegen/IR_zant/cmsis/prepare.zig`
- `src/codegen/IR_zant/cmsis/quant.zig`
- `src/codegen/IR_zant/cmsis/cmsis_test.zig`
- `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`
- `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_depthwise_qlinearconv.zig`
- `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_parameters.zig`
- `src/utils/utils.zig`
- `zantBuild/cmsis_build.zig`
- `scripts/fetch_cmsis_nn.sh`
- `scripts/fetch_cmsis_5.sh`
- `scripts/fetch_cmsis_dsp.sh`

## Purpose

These files connect the CMSIS helper layer to the broader project. They carry
CMSIS decisions into build options, expose the CMSIS package through `IR_zant`,
wire runtime artifacts for CMSIS C linkage, and route preparable QLinearConv
nodes to the appropriate standard or depthwise codegen-prepared CMSIS bridge.

The vendor acquisition scripts are documented together in `scripts.md`.

## `zantBuild/zantOptions.zig`

Initializes the shared Arm build configuration before the CMSIS flag group.

Relevant change:

```zig
const arm_toolchain = @import("arm_toolchain.zig");

arm_build: arm_toolchain.ArmBuildConfig,
cmsis_flags: cmsis.Cmsis_flags,
```

The initialization order is:

```zig
const arm_build = try arm_toolchain.ArmBuildConfig.init(b);

.arm_build = arm_build,
.cmsis_flags = try cmsis.Cmsis_flags.init(b, arm_build),
```

Why this matters: profile, provider, toolchain, target, and legacy CPU parsing
now happen once in `ArmBuildConfig`. CMSIS receives the resulting configuration
instead of independently reading `-Dcpu`. See `arm_build_layer.md` for the
complete option and toolchain flow.

## `zantBuild/zantStepOptions.zig`

Exports the CMSIS decisions into the generated `build_options` module.

Added exported options:

- `enable_cmsis`
- `target_is_cortex_m`

Why this matters: IR code cannot directly read `std.Build` options. It can only
see values exported through build-step options. These fields are what make
`@import("build_options").enable_cmsis` and `target_is_cortex_m` visible at
comptime.

## `zantBuild/zantModules.zig`

Adds `build_options` to the `IR_zant` module:

```zig
IR_zant_mod.addOptions("build_options", zantStepOptions.build_step_option);
```

Why this matters: IR code can reach CMSIS decisions through `IR_zant.cmsis`
without importing `build_options` directly from operator files.

## `src/utils/utils.zig`

Re-exports `build_options` from the `zant_utils` owner module.
This lets `IR_zant.cmsis` read CMSIS flags without operator files importing build options.

## `src/codegen/IR_zant.zig`

Re-exports the CMSIS helper module:

```zig
pub const cmsis = @import("IR_zant/cmsis/mod_cmsis.zig");
```

Why this is safe: `mod_cmsis.zig` reads `build_options` through the existing
`zant_utils` owner module. Operator code imports only `IR_zant.cmsis`.

## `build.zig`

Imports the CMSIS build helper:

```zig
const cmsis_build = @import("zantBuild/cmsis_build.zig");
```

Uses the target query prepared by `ArmBuildConfig`:

```zig
target = b.resolveTargetQuery(zantBuild.zantOptions.arm_build.target_query);
```

This replaces direct target/CPU parsing in `build.zig`. Without an Arm profile,
the shared configuration produces the same legacy query. With a profile, it
uses the exact profile target and CPU features.

Build configuration failures are logged and terminate the build instead of
using `catch unreachable`.

`build.zig` still adds CMSIS include paths to `IR_zant_mod` after target and
optimization resolution:

```zig
cmsis_build.configureCmsisModuleIncludes(
    b,
    zantBuild.zantModules.IR_zant_mod,
    zantBuild.zantOptions.cmsis_flags,
);
```

Why this matters: `cmsis_qlinearconv.zig` uses `@cImport` for
`arm_nnfunctions.h`. The `IR_zant` module needs CMSIS include paths when CMSIS
is active, but normal non-CMSIS builds should not receive those paths.

Adds CMSIS runtime artifact linkage to:

- `ir_tests`
- `lib_model_exe`
- `test_generated_lib`
- `static_lib`
- `test_all_oneOp`
- `benchmark`

Each call uses:

```zig
cmsis_build.configureCmsisRuntimeArtifact(
    b,
    artifact,
    zantBuild.zantOptions.cmsis_flags,
);
```

Why this matters: these artifacts can execute generated or runtime math that
may reach QLinearConv. When CMSIS is active, they need CMSIS include paths,
CMSIS C sources, C flags, and libc linkage. Host-side generation/parsing tools
are intentionally not given CMSIS C source linkage.

## `src/codegen/IR_zant_tests.zig`

Adds the CMSIS helper tests to the IR test aggregation:

```zig
_ = @import("IR_zant/cmsis/cmsis_test.zig");
```

Why this matters: the shared layout, quantization, parameter-capability, and
depthwise runtime helpers are part of `IR_zant`, so their focused tests run with
the IR test suite.

## `src/codegen/IR_zant/op_union/operators/op_qlinearconv/utils_qlinearconv.zig`

`qlinearconv_dispatch()` remains **embedded-only**. Prepared standard and
depthwise nodes use two separate lazy dispatchers:

- `qlinearconv_dispatch_cmsis_prepared(...)` imports the standard CMSIS bridge;
- `qlinearconv_dispatch_cmsis_depthwise_prepared(...)` imports the depthwise
  CMSIS bridge and forwards `ch_mult`.

Neither prepared dispatcher contains an embedded fallback. CMSIS eligibility is
decided during code generation; any `.none` node reaches the embedded-only
dispatcher directly.

## Code-generation-time CMSIS preparation

These changes move QLinearConv's static CMSIS work into lib-gen and leave both
runtime bridges responsible only for input-dependent layout/domain conversion,
scratch allocation, one CMSIS call, and output writeback. The supporting wiring
is:

- **`src/codegen/IR_zant/cmsis/mod_cmsis.zig`** — exports the layout,
  parameter-codegen, quant, and prepare modules. Its compatibility node gate
  delegates to generic capability discovery rather than switching on operators.
- **`src/codegen/IR_zant/cmsis/parameter_codegen.zig`** — discovers optional
  operator hooks with `inline else`/`@hasDecl`, protects shared initializers, and
  owns prepared-array formatting and symbol deduplication. See
  `parameter_codegen.md`.
- **`src/codegen/IR_zant/cmsis/prepare.zig`** — classifies QLinearConv as
  `.none`, `.standard`, or `.depthwise` and prepares the matching filter layout.
  See `prepare.md`.
- **`src/codegen.zig` + `src/codegen/parameter_writer.zig`** — thread the
  linearized node list into the parameters writer
  (`ParametersWriter.write(generated_path, linearizedGraph.items)` →
  `write_parameters(writer, linearizedGraph)`). The parameters phase previously
  saw only a flat tensor map; it needs whole nodes to prepare per-conv constants,
  and it runs before the predict file where `static_parameters.zig` is closed.
- **`src/codegen/parameters/parameters.zig`** — asks the generic CMSIS layer for
  safely excludable initializers, writes ordinary parameters, then asks it to
  emit prepared constants. It contains no operator or CMSIS-kind branch.
- **`op_qlinearconv/cmsis_parameters.zig`** — implements QLinearConv's local
  replacement and emission adapter. All five prepared symbols are keyed by the
  node output. See `cmsis_parameters.md`.
- **`op_qlinearconv/op_qlinearconv.zig`** — exposes the optional CMSIS hooks and
  switches locally on `CmsisKind`: standard and depthwise emit their respective
  prepared dispatcher; `.none` emits the embedded dispatcher.
- **`op_qlinearconv/utils_qlinearconv.zig`** — owns the standard and depthwise
  lazy dispatcher functions without importing build options.
- **`op_qlinearconv/cmsis_qlinearconv.zig`** — reduced to two prepared,
  layout-only public bridges (`qlinearconvNchw` / `qlinearconvNhwc`) over a single
  private CMSIS kernel call (`runCmsisConvolve`); the on-the-fly runtime bridges
  and their filter/bias/requant conversion calls were removed (see
  `cmsis_qlinearconv.md`).
- **`op_qlinearconv/cmsis_depthwise_qlinearconv.zig`** — implements the NCHW
  depthwise bridge over `arm_depthwise_conv_wrapper_s8`, passing `ch_mult` and
  using the wrapper's matching buffer-size getter. See
  `cmsis_depthwise_qlinearconv.md`.
- **`op_union/operators/zant_math_standard.zig`** — exports
  both prepared dispatchers and their backward-compatible aliases.

Why this matters: standard and depthwise QLinearConv nodes avoid repeated static
preparation and unnecessary flash duplication. Future CMSIS operators can use
the same capability boundary without adding branches to the global parameter
writer, while unsupported and non-CMSIS nodes remain unchanged.
