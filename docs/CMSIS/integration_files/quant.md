# `src/codegen/IR_zant/cmsis/quant.zig`

## Role

`quant.zig` contains reusable quantization adapters for CMSIS-NN backends. It
translates the current QLinearConv tensor values and quantization metadata into
the signed `s8` contract expected by CMSIS-NN convolution APIs.

## Public Types

- `RequantParams`: owns per-output-channel CMSIS multiplier and shift arrays.
- `ActivationOffsets`: stores CMSIS input/output offsets and activation clamp
  bounds.
- `PreparedBias`: owns the `i32` bias array passed to CMSIS.
- `PackedFilter`: owns the signed `i8` filter buffer after zero-point
  adjustment.
- `PreparedActivation`: owns an activation tensor converted into the signed
  `i8` CMSIS domain.

## Public Functions

- `makePerChannelRequantParams(...)`: computes `(x_scale * w_scale) / y_scale`
  for every output channel and converts each scale into CMSIS multiplier/shift
  form.
- `makeActivationOffsets(...)`: converts `i8` or `u8` QLinearConv zero-points
  into CMSIS signed-offset fields.
- `prepareBiasI32(...)`: creates the CMSIS-compatible `i32` bias buffer,
  including zero bias when no bias tensor exists.
- `prepareFilterS8(...)`: subtracts scalar or per-channel weight zero-points
  from layout-reordered filters and clamps values to `i8`.
- `prepareActivationS8(...)`: converts NHWC activations from `i8` or `u8` into
  the signed `i8` storage CMSIS consumes.
- `writeS8NhwcOutputToNchw(...)`: converts signed CMSIS NHWC output back into
  the existing Z-Ant NCHW output tensor and restores `u8` output domain when
  needed.

## Motivation

CMSIS-NN does not accept ONNX/Z-Ant quantized tensors directly. The convolution
wrapper expects signed activations, signed filters, `i32` bias, per-channel
requantization arrays, and signed offset fields. This file collects those
conversions so QLinearConv is the first user but not the owner of the logic.

## Boundaries

This file does not call CMSIS C functions and does not perform tensor layout
permutation. It prepares numeric data for an operator bridge that will call
CMSIS after layout conversion has already happened.

