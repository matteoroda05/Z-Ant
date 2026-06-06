# `src/codegen/IR_zant/cmsis/cmsis_test.zig`

## Role

`cmsis_test.zig` contains focused tests for the reusable CMSIS helper layer. It
does not call CMSIS C kernels; it validates the pure Zig layout and quantization
adapters that the QLinearConv bridge depends on.

## Test Cases

- `CMSIS layout converts NHWC output into NCHW destination`: verifies CMSIS
  output can be copied into an already allocated Z-Ant output tensor.
- `CMSIS layout packs OIHW filters into OHWI`: verifies standard convolution
  filters are reordered into CMSIS layout.
- `CMSIS quant prepares per-channel requant params and packed filters`: checks
  requant array allocation and signed filter packing with per-channel
  zero-points.
- `CMSIS quant converts u8 activation and output domains`: verifies the unsigned
  ONNX-style activation domain is shifted into and out of CMSIS signed `i8`.

## Motivation

The CMSIS bridge depends on layout and quantization conversions before the C
kernel call is possible. These tests give that shared helper layer coverage
without requiring vendored CMSIS-NN headers or source files.

