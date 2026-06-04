# `src/codegen/IR_zant/cmsis/mod_cmsis.zig`

## Role

`mod_cmsis.zig` is the IR-side CMSIS-NN usage gate. Code under `IR_zant` should
query this module when it needs to know whether CMSIS-NN is enabled for the
current build.

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

## Why `@hasDecl` Is Used

Each field access is guarded with `@hasDecl(build_options, "...")`.

This keeps the decision compile-safe when some CMSIS-related fields are missing
from the provided options module.

## Behavior Boundaries

This module does not:

- add CMSIS sources;
- add CMSIS include paths;
- call CMSIS kernels;
- change QLinearConv dispatch;
- require `build_options` just to be imported;
- inspect Zig target metadata directly.

It only answers the compile-time question: should CMSIS-NN be considered active
for this build? Code that calls it should pass `@import("build_options")`.
