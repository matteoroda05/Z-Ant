# CMSIS-NN Supporting Changes

This document covers CMSIS-NN integration changes outside the dedicated CMSIS
files documented in this directory, including:

- `zantBuild/cmsis_flags.zig`
- `src/codegen/IR_zant/cmsis/mod_cmsis.zig`
- `src/codegen/IR_zant/cmsis/layout.zig`
- `src/codegen/IR_zant/cmsis/quant.zig`
- `src/codegen/IR_zant/cmsis/cmsis_test.zig`
- `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`
- `src/utils/utils.zig`
- `zantBuild/cmsis_build.zig`

## Purpose

These files connect the CMSIS helper layer to the broader project. They carry
CMSIS decisions into build options, expose the CMSIS package through `IR_zant`,
wire runtime artifacts for CMSIS C linkage, and route preparable QLinearConv
nodes to the codegen-prepared CMSIS bridge.

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

`qlinearconv_dispatch()` is now **embedded-only**: it always calls
`qlinearconv_embedded_lean()`. The previous runtime CMSIS branch (which tried the
on-the-fly `qlinearconvNchwBridge`, falling back to embedded on
`error.UnsupportedCmsisQLinearConv` unless CMSIS was forced) was removed together
with the on-the-fly bridge itself.

Why this matters: CMSIS acceleration is now decided entirely at code-generation
time. A preparable node has `write_op` emit `qlinear_conv_dispatch_cmsis_prepared`
(the codegen-prepared path); any node that reaches the generic
`qlinearconv_dispatch` is one the generator did **not** prepare, and the removed
runtime bridge would have rejected it anyway (e.g. `group != 1`) — so there is
nothing left for this dispatcher to try at runtime. It stays the single backend
decision point for non-preparable nodes without importing `build_options`.

## Code-generation-time CMSIS preparation

These changes move QLinearConv's static CMSIS work (filter OHWI reorder + `i8`
pack, bias→`i32`, per-channel requant) from every runtime call into lib-gen, and
make the runtime CMSIS path layout-only. See `prepare.md` and
`cmsis_qlinearconv.md` for the details; the supporting wiring is:

- **`src/codegen/IR_zant/cmsis/mod_cmsis.zig`** — exports `pub const prepare` and
  adds `isCmsisSupported(node: anytype) bool`, the single op-type gate the
  generator consults (delegates the qlinearconv case to `prepare.qlinearconv_isSupported`).
- **`src/codegen/IR_zant/cmsis/prepare.zig`** (new) — host-safe codegen-time
  preparation; see `prepare.md`.
- **`src/codegen.zig` + `src/codegen/parameter_writer.zig`** — thread the
  linearized node list into the parameters writer
  (`ParametersWriter.write(generated_path, linearizedGraph.items)` →
  `write_parameters(writer, linearizedGraph)`). The parameters phase previously
  saw only a flat tensor map; it needs whole nodes to prepare per-conv constants,
  and it runs before the predict file where `static_parameters.zig` is closed.
- **`src/codegen/parameters/parameters.zig`** — on CMSIS builds:
  `buildExcludedInitializers` collects the prepared nodes' original filter/bias
  names (minus anything a non-prepared node references) and `write_initilizers`
  skips them (drop-originals, no flash duplication); `write_cmsis_prepared`
  emits the five `cmsis_` constants per prepared node (deduped by symbol name)
  into `static_parameters.zig`.
- **`op_qlinearconv/op_qlinearconv.zig`** (`write_op`) — when
  `cmsisUsed() and qlinearconv_isSupported(&self)`, emits
  `tensMath.qlinear_conv_dispatch_cmsis_prepared(...)` referencing the `cmsis_`
  constants (and no original weight/scale/bias); otherwise the standard call.
  `getMathErrorReturn()` is invoked in exactly one branch.
- **`op_qlinearconv/utils_qlinearconv.zig`** — adds
  `qlinearconv_dispatch_cmsis_prepared(...)`, a slim dispatcher (input +
  zero-points + the prepared slices) that calls `qlinearconvNchw(...)` with no
  embedded fallback.
- **`op_qlinearconv/cmsis_qlinearconv.zig`** — reduced to two prepared,
  layout-only public bridges (`qlinearconvNchw` / `qlinearconvNhwc`) over a single
  private CMSIS kernel call (`runCmsisConvolve`); the on-the-fly runtime bridges
  and their filter/bias/requant conversion calls were removed (see
  `cmsis_qlinearconv.md`).
- **`op_union/operators/zant_math_standard.zig`** — exports
  `qlinear_conv_dispatch_cmsis_prepared` (and the `qlinearconv_` alias).

Why this matters: preparable QLinearConv nodes stop recomputing static data on
every inference and no longer store their filter twice in flash, while
non-preparable nodes and non-CMSIS builds are unchanged.
