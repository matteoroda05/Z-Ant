# CMSIS-NN QLinearConv — State of the Art (2026-08-27)

Current snapshot of the CMSIS-NN QLinearConv integration after adding depthwise
acceleration and validating both supported Cortex-M archive profiles.

## Current state

- **Vendor acquisition is available.** `scripts/fetch_cmsis_nn.sh`,
  `scripts/fetch_cmsis_5.sh`, and `scripts/fetch_cmsis_dsp.sh` install CMSIS-NN
  `v7.0.0`, CMSIS_5 `5.9.0`, and CMSIS-DSP `v1.17.0` under `third_party/`.
- **Build wiring is complete for the current source set.**
  `zantBuild/cmsis_build.zig` supplies the required include paths, curated
  CMSIS-NN C sources, target flags, resolved GCC/newlib system headers, and
  `linkLibC()` for artifacts that execute CMSIS kernels. It does not bundle
  `libc.a`, `libm.a`, or `libgcc` into Z-Ant's static archive.
- **Architecture gating is explicit.** CMSIS code generation is active only
  when `enable_cmsis and target_is_cortex_m` is true. Public managed profiles
  exist for Cortex-M4 and Cortex-M7.
- **Prepared parameter generation is operator-owned and extensible.** The
  generic CMSIS layer discovers optional operator hooks at compile time, owns
  formatting/deduplication, and omits an original initializer only when every
  use is replaced.
- **Prepared symbols are output-keyed.** Each prepared node receives its own
  filter, filter shape, bias, multiplier, and shift namespace, even when nodes
  share original initializers.
- **Standard QLinearConv is accelerated** through
  `arm_convolve_wrapper_s8` for the existing supported `group == 1` surface.
- **Depthwise QLinearConv is accelerated** through
  `arm_depthwise_conv_wrapper_s8` for rank-4 batch-1 tensors with
  `group == C_in`, weights `[C_out, 1, H, W]`, integer `ch_mult >= 1`, matching
  activation types, NOTSET/empty padding mode, and unit dilation.
- **The CMSIS wrapper owns kernel selection.** Z-Ant supplies `ch_mult` and
  dimensions once; CMSIS-NN chooses its 3x3, optimized `ch_mult == 1`, generic
  `ch_mult > 1`, or multiplier-of-four implementation and matching scratch size.
- **Unsupported QLinearConv shapes remain correct.** They are classified
  `.none` and use the embedded path; the prepared runtime bridges contain no
  embedded fallback.

## Validation completed

### Host tests

The normal host suite passes with CMSIS-only runtime tests skipped:

```bash
zig build test --summary all
```

Result: 259 passed, 3 skipped.

The CMSIS-enabled host suite compiles and links the curated source set and runs
the depthwise numeric tests:

```bash
zig build test -Denable_CMSIS=true -Dcpu=cortex_m7 --summary all
```

Result: 262 passed. This includes deterministic signed `ch_mult == 1` and
unsigned `ch_mult > 1` depthwise comparisons, prepared-filter layout coverage,
capability discovery, shared-initializer protection, symbol isolation, and
runtime rejection checks.

### Generated `beer` library

CMSIS-enabled model generation and generated-library execution pass:

```bash
zig build lib-gen -Dmodel=beer -Denable_CMSIS=true -Dcpu=cortex_m7 --summary all
zig build lib-test -Dmodel=beer -Denable_CMSIS=true -Dcpu=cortex_m7 --summary all
```

All six depthwise QLinearConv nodes now call
`qlinear_conv_dispatch_cmsis_depthwise_prepared`; their prepared filter shapes
are `[1, 3, 3, C_out]`. The remaining 15 QLinearConv nodes use the standard
prepared dispatcher.

### Cortex-M static-library cross-builds

Both managed profiles build the CMSIS-enabled `beer` static library:

```bash
zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Denable_CMSIS=true

zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m4_fpv4_sp_d16_softfp \
  -Denable_CMSIS=true
```

These results prove that the generated library and registered CMSIS source set
compile for both profiles. They do not constitute firmware linking, flashing,
on-device numeric correctness, or performance validation.

## Remaining work

### 1. Hardware correctness and performance

Integrate the static library into a complete Cortex-M firmware image, including
startup code, linker script, runtime libraries, and board I/O. Compare standard
and depthwise outputs with the embedded reference and measure latency and memory
use on M4/M7 hardware. This remains pending board access.

### 2. Generic grouped convolution

True grouped QLinearConv (`1 < group < C_in`) still uses the embedded path. Its
future support should add a local `.grouped` classification plus QLinearConv
preparation/runtime behavior without changing `parameters.zig` or the generic
CMSIS capability layer.

### 3. NHWC-native generation

Generated models still use NCHW bridges and perform runtime layout conversion.
NHWC-native wiring can remove those transposes for compatible models.

### 4. Optional optimization controls

Future options include an external CMSIS path, `ARM_MATH_AUTOVECTORIZE`, CMSIS
requantization switches, and CPU-specific `OPTIONAL_RESTRICT_KEYWORD` handling.

## Priority order

1. Complete firmware integration when the target board is available.
2. Validate standard and depthwise numeric correctness on Cortex-M hardware.
3. Measure performance and scratch/static memory on Cortex-M4 and Cortex-M7.
4. Add true grouped QLinearConv through the local operator capability boundary.
5. Add NHWC-native generation and optional optimization controls as needed.
