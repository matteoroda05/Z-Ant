# `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`

## Role

`cmsis_qlinearconv.zig` is the QLinearConv-specific CMSIS-NN **runtime** bridge.
It adapts Z-Ant's QLinearConv activations to CMSIS-NN's `arm_convolve_wrapper_s8`
ABI.

It assumes the **static** data is already prepared. The filter (OHWI `i8`), bias
(`i32`), and per-channel requant multiplier/shift arrays are computed once at
code-generation time (see `prepare.md`) and emitted into `static_parameters.zig`
as `cmsis_` constants. This file no longer converts filters/biases/requant at
runtime — it only does the input-dependent work (layout transpose, `u8`→`i8`
activation shift, the CMSIS call, and the output writeback).

It is not called directly by generated model code. Generated QLinearConv code
calls a dispatch symbol; the dispatch function decides at compile time whether to
import this file and which bridge to call.

## Generated-Code Dispatch Path

For a preparable QLinearConv node (one that `IR_zant.cmsis.isCmsisSupported(...)`
accepts) on a CMSIS build, the CMSIS call becomes reachable through this path:

1. `src/codegen/predict/emit.zig` or `src/codegen/predict/predict.zig` walks
   graph nodes and calls `node.write_op(writer)`.
2. `NodeZant.write_op(...)` delegates to `Op_union.write_op(...)`, which for a
   QLinearConv node calls `QLinearConv.write_op(...)`.
3. `QLinearConv.write_op(...)` emits generated model code that calls
   `tensMath.qlinear_conv_dispatch_cmsis_prepared(...)`, passing the input,
   zero-points, and the node's `cmsis_` constants.
4. `zant_math_standard.zig` exports `qlinear_conv_dispatch_cmsis_prepared` from
   `utils_qlinearconv.zig`.
5. `qlinearconv_dispatch_cmsis_prepared(...)` imports `cmsis_qlinearconv.zig` and
   calls `qlinearconvNchw(...)`.

Non-preparable nodes (e.g. `group != 1`) instead have `write_op` emit the generic
`tensMath.qlinear_conv_dispatch(...)`, which is now **embedded-only** — it no
longer tries a runtime CMSIS bridge (see `supporting_changes.md`).

Generated model code therefore names a dispatch symbol, not `qlinearconvNchw(...)`
or `qlinearconvNhwc(...)` directly.

## Public Bridge Functions

Both public functions assume the filter/bias/requant constants are already
prepared (passed in as `const` slices, typically flash-resident). They differ
only in the activation layout, i.e. whether a transpose is needed:

`qlinearconvNchw(...)` — input and output tensors use Z-Ant's `[N, C, H, W]`
layout, so it **does** the transpose. It:

- validates the bridge case (`i8`/`u8` activation, `auto_pad` NOTSET/empty,
  rank-4, `group == 1`, `filter_shape[0] == out_channels`, slice lengths ≥ OC);
- converts input activations from NCHW to NHWC through `IR_zant.cmsis.layout`;
- converts activations into signed `i8` through `IR_zant.cmsis.quant`;
- computes the activation offsets from the input/output zero-points;
- calls `runCmsisConvolve(...)` with the precomputed filter/bias/requant slices;
- writes the signed NHWC output back into the caller-owned NCHW output tensor.

`qlinearconvNhwc(...)` — input and output tensors already use CMSIS's
`[N, H, W, C]` layout, so it does **no** transpose. It performs the same steps
minus the two layout conversions, writing the signed output back into the
caller-owned NHWC output tensor. It is not currently emitted by the generator
(Z-Ant stores activations NCHW); it is provided for a future NHWC-native path.

## Local Helpers

- `runCmsisConvolve(...)`: the single private "common function" that actually
  calls the CMSIS-NN kernel. It builds the params/dims records, sizes the scratch
  buffer, and calls `arm_convolve_wrapper_s8` once all buffers are ready. Both
  public bridges feed into it, so the kernel call lives in exactly one place. Its
  filter/bias/multiplier/shift parameters are `const` slices (flash-resident in
  the prepared path), hence the internal `@constCast`s.
- `dims(...)`: creates a CMSIS `cmsis_nn_dims` record from logical dimensions.
- `readDimPair(...)`: reads optional two-element stride, padding, or dilation
  attributes with a default.
- `isCmsisActivation(...)`: limits the current bridge to `i8` and `u8`
  activations.

## Motivation

Z-Ant's QLinearConv runtime is built around NCHW tensors; CMSIS-NN expects a
different ABI (NHWC activations, OHWI filters, per-channel requant). This file is
the narrow runtime translation layer. Because all static preparation happens at
code-generation time, the runtime bridge is now layout-only and does no repeated
filter/bias/requant work.

## Current Boundaries

This is not yet a complete QLinearConv accelerator. It targets the standard
`arm_convolve_wrapper_s8` path and deliberately rejects cases that need
additional CMSIS handling, such as grouped convolution — which is why those nodes
stay on the embedded path. There is also no generated-code option yet that selects
`qlinearconvNhwc(...)`; it is a callable entry point, but dispatch/generator
layout selection would need a separate change before generated models use it.
