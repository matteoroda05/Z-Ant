# `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`

## Role

`cmsis_qlinearconv.zig` is the QLinearConv-specific CMSIS-NN bridge. It adapts
the existing Z-Ant QLinearConv dispatch signature to CMSIS-NN's
`arm_convolve_wrapper_s8` ABI.

It is not called directly by generated model code. Generated QLinearConv code
calls `tensMath.qlinear_conv_dispatch(...)`; the dispatch function decides at
compile time whether to import this file and call the CMSIS bridge.

## Generated-Code Dispatch Path

The CMSIS call becomes reachable through this path:

1. `src/codegen/predict/emit.zig` or `src/codegen/predict/predict.zig` walks
   graph nodes and calls `node.write_op(writer)`.
2. `NodeZant.write_op(...)` delegates to `Op_union.write_op(...)`.
3. For a QLinearConv node, `Op_union.write_op(...)` calls
   `QLinearConv.write_op(...)`.
4. `QLinearConv.write_op(...)` writes generated model code that calls
   `tensMath.qlinear_conv_dispatch(...)`.
5. `zant_math_standard.zig` exports `qlinear_conv_dispatch` from
   `utils_qlinearconv.zig`.
6. `qlinearconv_dispatch(...)` checks `IR_zant.cmsis.cmsisUsed(build_options)`
   at compile time. If CMSIS is active, it imports `cmsis_qlinearconv.zig` and
   calls `qlinearconvNchwBridge(...)`; otherwise it calls the embedded fallback.

Generated model code therefore names the dispatch symbol, not
`qlinearconvNchwBridge(...)` or `qlinearconvNhwcBridge(...)` directly.

## Public Bridge Functions

`qlinearconvNchwBridge(...)` receives the same tensor arguments as the existing
QLinearConv dispatch path and performs the CMSIS-specific runtime adaptation:

- rejects unsupported bridge cases such as non-`i8/u8` tensors, active
  `auto_pad`, or `group != 1`;
- converts input activations from NCHW to NHWC through `IR_zant.cmsis.layout`;
- converts activations into signed `i8` through `IR_zant.cmsis.quant`;
- reorders filters from OIHW to OHWI;
- packs filters into signed `i8` after zero-point adjustment;
- prepares `i32` bias and per-channel requantization parameters;
- builds CMSIS dimension, convolution, activation, and quantization structs;
- asks CMSIS for scratch-buffer size;
- calls `arm_convolve_wrapper_s8`;
- writes the signed NHWC output back into the caller-owned NCHW output tensor.

`qlinearconvNhwcBridge(...)` is the NHWC-direct variant. It assumes the
activation input and output tensors already use `[N, H, W, C]`, so it skips only
the NCHW-to-NHWC input conversion and the NHWC-to-NCHW output conversion. It
still performs the remaining CMSIS adaptations:

- rejects the same unsupported type, `auto_pad`, rank, and group cases;
- converts NHWC activations into signed `i8`;
- reorders filters from OIHW to OHWI;
- packs filters into signed `i8` after zero-point adjustment;
- prepares `i32` bias and per-channel requantization parameters;
- builds CMSIS dimension, convolution, activation, and quantization structs;
- asks CMSIS for scratch-buffer size;
- calls `arm_convolve_wrapper_s8`;
- writes signed CMSIS NHWC output back into the caller-owned NHWC output tensor.

The current generated QLinearConv path still calls the NCHW dispatch route.
`qlinearconvNhwcBridge(...)` is available for a future path where Z-Ant has
already transformed the relevant activation tensors to NHWC before the CMSIS
bridge is selected.

## Local Helpers

- `validateBridgeInputs(...)`: validates bridge-wide CMSIS requirements and
  returns the resolved group count.
- `qlinearconvCmsisNhwcCore(...)`: owns the shared CMSIS-NN call sequence once
  the caller has normalized the activation tensors to NHWC.
- `dims(...)`: creates a CMSIS `cmsis_nn_dims` record from logical dimensions.
- `readDimPair(...)`: reads optional two-element stride, padding, or dilation
  attributes with a default.
- `isCmsisActivation(...)`: limits the current bridge to `i8` and `u8`
  activations.
- `isCmsisWeight(...)`: limits the current bridge to `i8` and `u8` weights.

## Motivation

The current Z-Ant QLinearConv runtime is built around NCHW tensors and the
existing embedded implementation. CMSIS-NN expects a different ABI. This bridge
is the narrow translation layer that lets `qlinearconv_dispatch()` try CMSIS
without changing the generator or the public QLinearConv dispatch signature.

## Current Boundaries

This is not yet a complete QLinearConv accelerator. It currently targets the
standard `arm_convolve_wrapper_s8` path and deliberately rejects cases that
need additional CMSIS handling, such as grouped convolution.

There is no generated-code option yet that selects the NHWC-direct bridge. The
new method is a callable bridge entry point, but dispatch/generator layout
selection would need a separate change before generated models use it
automatically.
