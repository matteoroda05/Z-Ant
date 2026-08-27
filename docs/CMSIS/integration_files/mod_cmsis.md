# `src/codegen/IR_zant/cmsis/mod_cmsis.zig`

## Role

`mod_cmsis.zig` is the public IR-side CMSIS helper surface and build-usage gate.
Code under `IR_zant` queries this module rather than importing build options or
individual CMSIS helper files directly.

## Exports

```zig
pub const layout = @import("layout.zig");
pub const parameter_codegen = @import("parameter_codegen.zig");
pub const quant = @import("quant.zig");
pub const prepare = @import("prepare.zig");
```

- `layout` owns reusable CMSIS tensor-layout transformations.
- `parameter_codegen` discovers optional operator capabilities and owns generic
  prepared-constant emission and initializer-use analysis.
- `quant` owns signed-domain, bias, offset, and requant helpers.
- `prepare` owns QLinearConv classification and codegen-time preparation.

## Node capability gate

```zig
pub fn isCmsisSupported(node: anytype) bool
```

This compatibility entry point delegates to
`parameter_codegen.isSupported(node)`. The generic capability layer uses
`inline else` and `@hasDecl` to call the active operator payload's optional
`cmsis_is_supported` method. Operators without the method return `false`
automatically; `mod_cmsis.zig` contains no operator-specific switch.

See `parameter_codegen.md` for the complete hook and initializer-exclusion
contract.

## Build usage gate

```zig
pub fn cmsisUsed() bool
```

The module reads build options through `zant_utils.build_options` and returns
true only for:

```text
enable_cmsis and target_is_cortex_m
```

Each field is guarded with `@hasDecl`, keeping compilation safe for option
modules that do not expose CMSIS fields.

## Behavior boundaries

This module does not add C sources or include paths, call CMSIS kernels, classify
QLinearConv itself, or inspect Zig target metadata. Build wiring remains in
`zantBuild/cmsis_build.zig`; operator eligibility remains operator-owned.

The pure Zig layout, parameter, quantization, and preparation exports do not
activate CMSIS by themselves.
