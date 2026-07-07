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
pub const prepare = @import("prepare.zig");
```

Why this matters: callers can use `IR_zant.cmsis.layout`,
`IR_zant.cmsis.quant`, and `IR_zant.cmsis.prepare` as the shared CMSIS helper
surface instead of importing individual files from operator-specific folders.

## `isCmsisSupported`

```zig
pub fn isCmsisSupported(node: anytype) bool
```

The single gate the code generator consults to decide whether a node can be
accelerated by CMSIS-NN today. It dispatches on the operator type and delegates
per-node eligibility to the operator-specific checker in `prepare.zig`
(`.qlinearconv => prepare.qlinearconv_isSupported(...)`, else `false`). Only
QLinearConv can currently return `true`. `node` is taken as `anytype` so this
file does not import the node/op-union modules that would form an import cycle.

See `prepare.md` for how the generator uses this gate to precompute and emit the
`cmsis_` constants and to drop the replaced originals.

## Current Decision

The module reads build options through the `zant_utils` owner module. Callers do
not pass or import `build_options` directly:

```zig
const zant_utils = @import("zant_utils");

pub fn cmsisUsed() bool
```

`cmsisUsed()` returns true when `enable_cmsis` exists and is true, and
`target_is_cortex_m` exists and is true.

In compact form:

```zig
enable_cmsis and target_is_cortex_m
```

## Why `@hasDecl` Is Used

Each field access is guarded with `@hasDecl(build_options, "...")` after
loading `build_options` from `zant_utils.build_options`.

This keeps the decision compile-safe when some CMSIS-related fields are missing
from the options module owned by `zant_utils`.

## Behavior Boundaries

This module does not:

- add CMSIS sources;
- add CMSIS include paths;
- call CMSIS kernels;
- require QLinearConv utilities to import `build_options`;
- inspect Zig target metadata directly.

Its decision function only answers a compile-time question about whether
CMSIS-NN should be considered active for this build. Code that calls it should
use `IR_zant.cmsis.cmsisUsed()`.

The layout and quant exports are pure Zig helper modules. They do not import
`build_options` and do not activate CMSIS by themselves.
