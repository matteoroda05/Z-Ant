# CMSIS-NN Supporting Changes

This document covers CMSIS-NN integration changes outside the two dedicated
CMSIS files:

- `zantBuild/cmsis_flags.zig`
- `src/codegen/IR_zant/cmsis/mod_cmsis.zig`

The content is based on the diff from commit
`3a31b73cae41a46f4023ff3512da97f5667370ca` to the current working state.

## Purpose

These files do not implement CMSIS-NN kernels. They only make the CMSIS usage
decision available to IR code and prove that the `QLinearConv` area can import
the gate.

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

Why this matters: `mod_cmsis.zig` lives under `IR_zant` and imports
`build_options`. Without this module wiring, IR code would not be able to
compile the CMSIS usage gate.

## Explicit Non-Goals

These supporting changes do not:

- add CMSIS C sources;
- add CMSIS include paths;
- copy a CMSIS wrapper;
- change QLinearConv dispatch;
- implement full Zig target or CPU model detection.
