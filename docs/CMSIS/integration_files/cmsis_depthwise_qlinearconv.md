# `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_depthwise_qlinearconv.zig`

## Role

`cmsis_depthwise_qlinearconv.zig` is the prepared QLinearConv runtime bridge for
CMSIS-NN depthwise convolution. It adapts Z-Ant NCHW activations and prepared
`[1, H, W, C_out]` signed filters to `arm_depthwise_conv_wrapper_s8`.

The file is reached only through the lazy depthwise dispatcher in
`utils_qlinearconv.zig`. Consequently, non-CMSIS builds do not need to resolve
its `@cImport("arm_nnfunctions.h")`.

## Public bridge

`qlinearconvDepthwiseNchw(...)` receives the input/output tensors, activation
zero-points, prepared filter/bias/requant slices, `ch_mult`, convolution
attributes, and group value.

It validates the runtime side of the first-cut contract:

- `i8` or `u8` activation type;
- NOTSET/empty `auto_pad`;
- rank-4 input and output with batch size 1;
- unit dilation;
- `group == C_in` and `ch_mult >= 1`;
- `C_out == C_in * ch_mult`;
- filter shape `[1, H, W, C_out]` and matching buffer length;
- bias, multiplier, and shift lengths covering every output channel.

Unsupported nodes should already have been classified `.none` during code
generation. The bridge deliberately has no embedded fallback.

## Runtime flow

1. Convert the input from NCHW to NHWC.
2. Convert `u8` activations into CMSIS-NN's signed `i8` domain when required.
3. Allocate a signed NHWC output tensor.
4. Derive CMSIS input/output offsets from the activation zero-points.
5. Call the private depthwise runner.
6. Convert the signed NHWC result into the caller-owned NCHW output tensor.

Static filter conversion, bias conversion, and requant calculation do not occur
at runtime; they are completed by `prepare.zig` during code generation.

## CMSIS wrapper selection

`runDepthwiseConvolve(...)` creates `cmsis_nn_dw_conv_params`, including
`ch_mult`, and calls:

```text
arm_depthwise_conv_wrapper_s8_get_buffer_size(...)
arm_depthwise_conv_wrapper_s8(...)
```

Z-Ant does not independently choose a depthwise kernel. The wrapper selects the
appropriate CMSIS-NN implementation from the target features and concrete
dimensions, including its 3x3 route, optimized `ch_mult == 1` route, generic
`ch_mult > 1` route, or internal multiplier-of-four specialization. The wrapper
buffer-size getter follows the same selection.

Scratch memory is allocated only when the getter returns a positive size. It is
cleared before release. Prepared flash-resident slices are passed to the C API
with narrow internal `@constCast`s because the CMSIS declarations are not const
qualified even though the kernel does not own those buffers.

## Current boundary

The generated path is NCHW and batch 1. True grouped convolution and NHWC-native
generated dispatch remain separate future work. Host numeric tests and M4/M7
static-library cross-builds pass; firmware execution and performance validation
remain pending board access.
