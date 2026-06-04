# `src/codegen/IR_zant/cmsis/mod_cmsis.zig`

## Role

`mod_cmsis.zig` is the IR-side CMSIS-NN usage gate. Code under `IR_zant` should
query this module when it needs to know whether CMSIS-NN is enabled for the
current build.

## Current Decision

The module imports compile-time build options:

```zig
const build_options = @import("build_options");
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

This keeps the module compile-safe if a build path imports `IR_zant` without
all CMSIS-related build options being exported.

## Behavior Boundaries

This module does not:

- add CMSIS sources;
- add CMSIS include paths;
- call CMSIS kernels;
- change QLinearConv dispatch;
- inspect Zig target metadata directly.

It only answers the compile-time question: should CMSIS-NN be considered active
for this build?
