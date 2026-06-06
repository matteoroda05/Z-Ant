# `src/codegen/IR_zant/cmsis/mod_cmsis.zig`

## Role

`mod_cmsis.zig` is the IR-side CMSIS-NN usage gate. Code under `IR_zant` should
query this module when it needs to know whether CMSIS-NN is enabled for the
current build. It also re-exports the shared CMSIS helper packages.

## Exports

The module currently exposes:

```zig
pub const layout = @import("layout.zig");
pub const quant = @import("quant.zig");
```

Why this matters: callers can use `IR_zant.cmsis.layout` and
`IR_zant.cmsis.quant` as the shared CMSIS helper surface instead of importing
individual files from operator-specific folders.

## Current Decision

The module does not import `build_options` at file scope. The caller passes the
options module into `cmsisUsed()`:

```zig
pub fn cmsisUsed(comptime build_options: type) bool
```

`cmsisUsed()` returns true when either:

- `force_cmsis` exists and is true; or
- `enable_cmsis` exists and is true, and `target_is_cortex_m` exists and is
  true.

In compact form:

```zig
force_cmsis or (enable_cmsis and target_is_cortex_m)
```

The forced branch is implemented through:

```zig
pub fn cmsisForced(comptime build_options: type) bool
```

`cmsisForced()` returns true only when `force_cmsis` exists and is true. This is
used by QLinearConv dispatch to decide whether unsupported CMSIS bridge cases
may fall back to the embedded implementation or must fail visibly.

## Why `@hasDecl` Is Used

Each field access is guarded with `@hasDecl(build_options, "...")`.

This keeps the decision compile-safe when some CMSIS-related fields are missing
from the provided options module.

## Behavior Boundaries

This module does not:

- add CMSIS sources;
- add CMSIS include paths;
- call CMSIS kernels;
- require `build_options` just to be imported;
- inspect Zig target metadata directly.

Its decision functions only answer compile-time questions about whether CMSIS-NN
should be considered active or forced for this build. Code that calls them
should pass `@import("build_options")`.

The layout and quant exports are pure Zig helper modules. They do not import
`build_options` and do not activate CMSIS by themselves.
