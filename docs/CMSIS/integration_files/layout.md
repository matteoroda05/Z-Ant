# `src/codegen/IR_zant/cmsis/layout.zig`

## Role

`layout.zig` contains reusable tensor-layout helpers for CMSIS-NN backends. It
only moves elements; signed-domain conversion, zero-point handling, bias
preparation, and requantization remain in `quant.zig`.

## Functions

- `nchwToNhwc(...)` converts Z-Ant activations from `[N, C, H, W]` to CMSIS-NN
  `[N, H, W, C]` by delegating to the existing generic tensor utility.
- `nhwcToNchwInto(...)` copies a CMSIS-NN output into an already allocated Z-Ant
  output tensor, preserving generated-code allocation ownership.
- `oihwToCmsisFilterLayout(...)` reorders standard convolution filters from
  `[O, I/group, H, W]` to `[O, H, W, I/group]`.
- `oihwToCmsisDepthwiseLayout(...)` reorders a signed depthwise filter from
  `[C_out, 1, H, W]` to `[1, H, W, C_out]` and validates a non-zero integer
  channel multiplier.
- `validateNhwcToNchwShapes(...)` is the private guard for output-layout copies.

## Depthwise ordering rule

Depthwise weight zero-points are per output channel, which is axis 0 in ONNX
OIHW. `prepare.zig` therefore calls `prepareFilterS8(...)` before
`oihwToCmsisDepthwiseLayout(...)`. Reordering unsigned weights first would lose
the axis information needed to subtract the correct per-channel zero-point.

The depthwise helper receives already signed values and performs only this
mapping:

```text
[C_out, 1, H, W] -> [1, H, W, C_out]
```

The same prepared format is used for every `ch_mult >= 1`; kernel selection is
left to the CMSIS-NN depthwise wrapper at runtime.
