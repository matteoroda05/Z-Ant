# `src/codegen/IR_zant/cmsis/layout.zig`

## Role

`layout.zig` contains reusable tensor-layout helpers for CMSIS-NN backends.
It keeps CMSIS layout adaptation out of individual operator folders, so future
CMSIS-backed operators can reuse the same conversion surface.

## Functions

- `nchwToNhwc(...)`: converts Z-Ant activation tensors from `[N, C, H, W]` to
  CMSIS-NN's `[N, H, W, C]` input layout. It delegates to the existing generic
  tensor utility instead of duplicating permutation logic.
- `nhwcToNchwInto(...)`: copies a CMSIS-NN `[N, H, W, C]` output tensor into an
  already allocated Z-Ant `[N, C, H, W]` output tensor. This preserves the
  existing generated-code ownership model.
- `oihwToCmsisFilterLayout(...)`: reorders filters from ONNX/Z-Ant
  `[O, I/group, H, W]` into CMSIS standard convolution layout
  `[O, H, W, I/group]`.
- `validateNhwcToNchwShapes(...)`: private guard that checks source/destination
  tensors describe the same logical 4D output before layout copying.

## Motivation

CMSIS-NN convolution wrappers do not use the same memory order as the current
Z-Ant QLinearConv path. This file isolates that ABI difference in one shared
place. It only moves tensor elements; signed quantization conversion,
zero-point handling, and clamping stay in `quant.zig`.

