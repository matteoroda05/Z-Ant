# `src/codegen/IR_zant/cmsis/cmsis_test.zig`

## Role

`cmsis_test.zig` covers the reusable CMSIS layout/quantization layer and the
prepared depthwise runtime bridge. Pure Zig cases run in every host suite;
kernel cases are compile-time skipped unless CMSIS is enabled for a Cortex-M
configuration hint.

Generic parameter-capability tests live beside their implementation in
`parameter_codegen.zig`.

## Always-enabled helper tests

- NHWC output to caller-owned NCHW output conversion.
- Standard OIHW to OHWI filter packing.
- Depthwise `[C_out,1,H,W]` to `[1,H,W,C_out]` packing for representative
  `ch_mult` values 1, 3, and 4.
- Per-channel requant allocation and signed filter preparation.
- `u8` activation conversion into and out of CMSIS's signed domain.

## CMSIS-enabled runtime tests

- Deterministic signed depthwise convolution with `ch_mult == 1`.
- Deterministic unsigned depthwise convolution with `ch_mult > 1`, bias and
  per-channel requant parameters.
- Rejection of batch greater than one.
- Rejection of dilation greater than one.

These call the exported lazy depthwise dispatcher, which reaches the real
`arm_depthwise_conv_wrapper_s8` implementation linked into the host test
artifact.

## Commands and expected results

```bash
zig build test --summary all
```

Expected current result: 259 passed and 3 CMSIS-only tests skipped.

```bash
zig build test -Denable_CMSIS=true -Dcpu=cortex_m7 --summary all
```

Expected current result: 262/262 passed.

The CMSIS-enabled host run validates deterministic correctness and C-source
linkage. It does not replace Cortex-M firmware execution or performance tests.
