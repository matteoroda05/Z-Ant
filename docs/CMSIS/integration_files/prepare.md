# `src/codegen/IR_zant/cmsis/prepare.zig`

## Role

`prepare.zig` owns QLinearConv's CMSIS classification and code-generation-time
preparation. It is host-safe and never imports CMSIS C headers, allowing model
generation to prepare filters, biases, and requant arrays on a normal host.

## Classification

```zig
pub const CmsisKind = enum { none, standard, depthwise };
pub fn qlinearconv_classify(op: *const QLinearConv) CmsisKind
```

This is the single QLinearConv CMSIS classification source used by parameter
generation and `QLinearConv.write_op(...)`.

Common accepted properties include `i8`/`u8` activations and weights, matching
input/output activation types, NOTSET/empty `auto_pad`, initializer weights and
scales, supported weight zero-points, and a valid optional `i32` bias.

Classification then applies this precedence:

- `.standard` when `group == 1`, preserving the existing standard-convolution
  path, including the one-input-channel degenerate depthwise interpretation;
- `.depthwise` when input/output are rank 4 with batch 1, `group == C_in`, the
  weight is `[C_out, 1, H, W]`, `C_out % C_in == 0`, `ch_mult >= 1`, output
  channels match `C_out`, and dilation is unit;
- `.none` for every other case, which keeps the embedded dispatcher.

`qlinearconv_isSupported(...)` remains a boolean compatibility helper defined
as `qlinearconv_classify(op) != .none`.

## `Prepared`

The owned preparation result contains:

- `kind`;
- signed `filter_s8` and `filter_shape`;
- `bias_i32`;
- per-channel `multipliers` and `shifts`;
- `ch_mult` (`1` for standard convolution).

The caller releases all owned buffers with `Prepared.deinit(...)`.

## Standard preparation

The standard path reorders raw OIHW weights to CMSIS OHWI, coerces the weight
zero-point consistently with normal parameter output, and converts the filter to
signed `i8`. It then shares bias and requant preparation with the depthwise path.

## Depthwise preparation

The depthwise path deliberately prepares signed filter values while the filter
is still `[C_out, 1, H, W]`. This ensures a per-channel weight zero-point indexes
axis 0 correctly. Only afterward does it reorder the signed filter to
`[1, H, W, C_out]`.

The final bias and per-channel multiplier/shift generation reuses
`prepareBiasI32(...)` and `makePerChannelRequantParams(...)`, exactly as the
standard path does.

## Consumers and emission

- `op_qlinearconv.zig` exposes the optional CMSIS hooks and switches locally on
  `CmsisKind` when emitting runtime code.
- `op_qlinearconv/cmsis_parameters.zig` calls `qlinearconv_prepare(...)` and
  provides its data to the generic emitter.
- `parameters.zig` knows neither QLinearConv nor `CmsisKind`; it invokes only the
  generic capability layer documented in `parameter_codegen.md`.

Prepared symbols are output-keyed as documented in `cmsis_parameters.md`.

## Extension boundary

True grouped convolution can add a future `.grouped` classifier and local
preparation branch here. The generic CMSIS parameter writer and hook discovery
do not need to change.
