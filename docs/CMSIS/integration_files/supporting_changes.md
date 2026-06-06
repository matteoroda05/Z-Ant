# CMSIS-NN Supporting Changes

This document covers CMSIS-NN integration changes outside the dedicated CMSIS
files documented in this directory, including:

- `zantBuild/cmsis_flags.zig`
- `src/codegen/IR_zant/cmsis/mod_cmsis.zig`
- `src/codegen/IR_zant/cmsis/layout.zig`
- `src/codegen/IR_zant/cmsis/quant.zig`
- `src/codegen/IR_zant/cmsis/cmsis_test.zig`
- `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`
- `zantBuild/cmsis_build.zig`

## Purpose

These files connect the CMSIS helper layer to the broader project. They carry
CMSIS decisions into build options, expose the CMSIS package through `IR_zant`,
wire runtime artifacts for CMSIS C linkage, and make QLinearConv dispatch able
to try the CMSIS bridge.

## `zantBuild/zantOptions.zig`

Adds the CMSIS flag group to the global build option container.

Relevant change:

```zig
const cmsis = @import("cmsis_flags.zig");

cmsis_flags: cmsis.Cmsis_flags,
```

and initializes it with:

```zig
.cmsis_flags = try cmsis.Cmsis_flags.init(b),
```

Why this matters: `cmsis_flags.zig` reads the CMSIS-related build flags, but
those values need to be carried through `ZantOptions` before other build
helpers can export them to Zig modules.

## `zantBuild/zantStepOptions.zig`

Exports the CMSIS decisions into the generated `build_options` module.

Added exported options:

- `enable_cmsis`
- `force_cmsis`
- `target_is_cortex_m`

Why this matters: IR code cannot directly read `std.Build` options. It can only
see values exported through build-step options. These fields are what make
`@import("build_options").enable_cmsis`, `force_cmsis`, and
`target_is_cortex_m` visible at comptime.

## `zantBuild/zantModules.zig`

Adds `build_options` to the `IR_zant` module:

```zig
IR_zant_mod.addOptions("build_options", zantStepOptions.build_step_option);
```

Why this matters: future IR code that calls `cmsisUsed(...)` can pass
`@import("build_options")` from the module wiring already used by `IR_zant`.

## `src/codegen/IR_zant.zig`

Re-exports the CMSIS helper module:

```zig
pub const cmsis = @import("IR_zant/cmsis/mod_cmsis.zig");
```

Why this is safe: `mod_cmsis.zig` no longer imports `build_options` at file
scope. Importing `IR_zant.cmsis` only loads the helper; callers must pass
`@import("build_options")` when they actually call `cmsisUsed(...)`.

## `build.zig`

Imports the CMSIS build helper:

```zig
const cmsis_build = @import("zantBuild/cmsis_build.zig");
```

Adds CMSIS include paths to `IR_zant_mod` after target/optimization resolution:

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

Why this matters: the shared layout and quantization helpers are part of
`IR_zant`, so their focused tests should run with the IR test suite.

## `src/codegen/IR_zant/op_union/operators/op_qlinearconv/utils_qlinearconv.zig`

Imports generated build options:

```zig
const build_options = @import("build_options");
```

Changes `qlinearconv_dispatch()` from always calling the embedded fallback to
first trying CMSIS when the CMSIS gate is active:

```zig
if (comptime IR_zant.cmsis.cmsisUsed(build_options)) {
    const cmsis_qlinearconv = @import("cmsis_qlinearconv.zig");
    cmsis_qlinearconv.qlinearconvNchwBridge(...);
}
```

If the CMSIS bridge returns `error.UnsupportedCmsisQLinearConv`, dispatch falls
back to `qlinearconv_embedded_lean()` unless `IR_zant.cmsis.cmsisForced(...)` is
true.

Why this matters: `qlinearconv_dispatch()` remains the single backend decision
point. Normal builds keep the existing embedded implementation. CMSIS builds
can try the CMSIS bridge without changing the generator-facing QLinearConv
interface.
