# `src/codegen/IR_zant/cmsis/prepare.zig`

## Role

`prepare.zig` performs the **code-generation-time** CMSIS-NN preparation for
QLinearConv. It computes the static constants a prepared node needs — the OHWI
`i8` filter, the `i32` bias, and the per-channel requant multiplier/shift arrays
— so the runtime CMSIS path no longer recomputes them on every inference.

It is **host-safe**: it never imports the CMSIS vendor headers
(`@cImport("arm_nnfunctions.h")`), so it runs inside the lib-gen tool on a normal
host where no CMSIS sources exist. It reuses the existing numeric primitives in
`layout.zig` and `quant.zig`, so the constants it emits are byte-identical to
what the on-the-fly runtime bridge would compute.

For now this file holds only `qlinearconv_*` functions. When a second operator
gains CMSIS support it adds its own `<op>_*` functions here.

## Public API

- `qlinearconv_isSupported(op: *const QLinearConv) bool` — the single per-node
  eligibility gate. Returns `true` only for a QLinearConv node the current
  CMSIS-NN integration can handle: `i8`/`u8` activations & weights, `auto_pad`
  NOTSET/empty, `group == 1`, a rank-4 initializer weight with non-zero dims,
  three valid `f32` scale initializers (with `y_scale[0] != 0`), a supported
  `w_zero_point` type, and — if present — an `i32` bias initializer of length 1
  or `>= out_channels`. When CMSIS gains wider support (e.g. `group > 1`), relax
  the checks here.
- `Prepared` — owns the precomputed `filter_s8`, `filter_shape` (`[4]usize`),
  `bias_i32`, `multipliers`, and `shifts`. Caller frees it with `deinit`.
- `qlinearconv_prepare(alloc, op) !Prepared` — dispatches on the weight type and
  builds the constants by reusing `oihwToCmsisFilterLayout` → `prepareFilterS8`
  → `prepareBiasI32` → `makePerChannelRequantParams`.

## Consumers

- **`isCmsisSupported`** (in `mod_cmsis.zig`) dispatches on the operator type and
  delegates the qlinearconv case to `qlinearconv_isSupported`.
- **`parameters.zig`** (`write_cmsis_prepared`) calls `qlinearconv_prepare` and
  emits the results into `static_parameters.zig` as `cmsis_`-prefixed constants.
- **`op_qlinearconv.zig`** (`write_op`) calls `qlinearconv_isSupported` to decide
  whether to emit the prepared dispatch call.

## Emitted constants and naming

`write_cmsis_prepared` emits five constants per prepared node using a hybrid
scheme (weight `<w>`, bias `<b>`, output `<out>`, all sanitized names):

| Constant     | Symbol                              | Keyed by |
|--------------|-------------------------------------|----------|
| filter (i8)  | `cmsis_tensor_<w>`                   | weight   |
| filter_shape | `cmsis_tensor_<w>_filter_shape`     | weight   |
| bias (i32)   | `cmsis_tensor_<b>` / `cmsis_tensor_<out>_bias` when no bias | bias / output |
| multiplier   | `cmsis_tensor_<out>_multiplier`     | output   |
| shift        | `cmsis_tensor_<out>_shift`          | output   |

The requant arrays are output-keyed because they depend on the node's scales
(per-node), while the filter depends only on the weight+zero-point; emission is
deduped by symbol name so a weight shared by two prepared nodes is written once.

## Flash / drop-originals behavior

On CMSIS builds, a prepared node's **original filter and bias initializers are
dropped** from `static_parameters.zig` (see `parameters.zig` `buildExcludedInitializers`)
— the folded-in `cmsis_` versions replace them, so the filter is not stored
twice. Scale and zero-point tensors are kept (the input/output zero-points are
still read at runtime for the activation offsets). Because `qlinearconv_isSupported`
already validated the node at codegen, the runtime prepared bridge has no embedded
fallback and needs no original tensors.

## Weight zero-point coercion

`coerceWeightZeroPointI32` reproduces the name-keyed zero-point coercion that
`parameters.zig` applies when it stores zero-point tensors (weight zero-points —
name contains `zero_point` and `const_fold_opt` — are stored as `i8`; other
zero-points as `u8`). This guarantees the prepared filter matches what the
reference path would compute from the generated weight zero-point.
