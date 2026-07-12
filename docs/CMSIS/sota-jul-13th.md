# CMSIS-NN QLinearConv — State of the Art (2026-07-13)

Current snapshot of the rebuilt CMSIS-NN QLinearConv integration and the work
remaining before it can be validated on a Cortex-M target.

## Current state

- **Vendor acquisition is available.** `scripts/fetch_cmsis_nn.sh`,
  `scripts/fetch_cmsis_5.sh`, and `scripts/fetch_cmsis_dsp.sh` install the three
  dependency trees under `third_party/`. The selected stable versions are
  CMSIS-NN `v7.0.0`, CMSIS_5 `5.9.0`, and CMSIS-DSP `v1.17.0`.

The vendor trees are downloaded locally and are not stored in the repository.
From the repository root, populate a checkout with:

```bash
CMSIS_NN_REF=v7.0.0 ./scripts/fetch_cmsis_nn.sh
CMSIS5_REF=5.9.0 ./scripts/fetch_cmsis_5.sh
CMSIS_DSP_REF=v1.17.0 ./scripts/fetch_cmsis_dsp.sh
```

After these commands, `third_party/CMSIS-NN`, `third_party/CMSIS_5`, and
`third_party/CMSIS-DSP` are present. They were installed in the checkout used
for the validation below, so missing vendor sources are no longer its immediate
build blocker.

- **Build wiring is in place.** `zantBuild/cmsis_build.zig` attaches CMSIS include
  paths, a curated C-source list, the per-file C flags
  (`-DOPTIONAL_RESTRICT_KEYWORD=__restrict -fbuiltin -O3 -ffast-math
  -fno-math-errno`), and `linkLibC()` to artifacts that may run CMSIS kernels.
- **The source list matches CMSIS-NN v7.0.0 paths.** Depthwise and convolution
  matmul files now use `Source/ConvolutionFunctions`; obsolete v7 source names
  were removed. Every currently registered C-source path exists.
- **The architecture gate is real.** `cmsis_flags.zig` derives
  `target_is_cortex_m` from `-Dcpu`, and CMSIS is used only when
  `enable_cmsis and target_is_cortex_m`. Native `lib-gen` accepts
  `-Dcpu=cortex_m*` without parsing it as the host CPU target.
- **Codegen-time preparation works.** `IR_zant/cmsis/prepare.zig` precomputes the
  OHWI `i8` filter, `i32` bias, and per-channel multiplier/shift arrays and emits
  them into `static_parameters.zig`. Replaced filter/bias initializers are not
  duplicated in flash.
- **The runtime bridge is layout-only.** `cmsis_qlinearconv.zig` exposes prepared
  NCHW and NHWC bridges over `arm_convolve_wrapper_s8`. Runtime performs only
  input-dependent conversion, layout handling, offsets, the CMSIS call, and
  output writeback.
- **Supported surface:** standard convolution with `group == 1`, `i8`/`u8`
  activations and weights, `auto_pad` NOTSET/empty, and initializer
  weights/scales. Other cases use the embedded path.
- **Current validation:** `zig build test` passes, CMSIS `lib-gen` for `beer`
  succeeds, and the Cortex-M7 library build now reaches vendor C compilation.

## Current build blocker

### Freestanding C standard-library headers

The current Cortex-M7 command is:

```bash
zig build lib -Dmodel=beer -Dtarget=thumb-freestanding \
  -Dcpu=cortex_m7 -Denable_CMSIS=true
```

Compilation stops because the freestanding environment cannot find
`string.h`, which is included by CMSIS-NN and CMSIS-DSP headers. No compatible
Arm newlib/toolchain include directory is currently discoverable on the host.

The next integration step is to provide a configurable or automatically
discovered Arm newlib include/runtime path. Once those headers are available,
the cross-build must be rerun to identify any remaining missing C sources or
link symbols.

## Remaining acceleration work

### 1. Depthwise convolution

Depthwise QLinearConv is still not CMSIS-accelerated. On `beer`, 6 of 21
QLinearConv nodes use the embedded path because `group != 1`. CMSIS requires the
dedicated `arm_depthwise_conv_wrapper_s8` API, depthwise filter layout, and its
buffer-size getter. The relevant v7 C sources are registered, but there is no
depthwise preparation or runtime bridge yet.

### 2. Generic grouped convolution

`qlinearconv_isSupported` still rejects `group != 1`. Generic grouped support
requires per-group preparation plus runtime slicing/CMSIS calls and output
placement.

### 3. Device or emulator validation

There is no completed Cortex-M4/M7 or QEMU execution validating CMSIS numeric
results against the embedded reference. This remains blocked until the library
cross-build completes.

### 4. NHWC-native generation

`qlinearconvNhwc` exists, but generated models always call the NCHW bridge.
Selecting NHWC for compatible models would avoid runtime transposes.

### 5. Optional configurability and optimization

Future options include a configurable external CMSIS path,
`ARM_MATH_AUTOVECTORIZE`, CMSIS requantization switches, and CPU-specific
handling of `OPTIONAL_RESTRICT_KEYWORD`.

## Priority order

1. Provide the freestanding C-library/newlib headers and runtime support.
2. Complete and validate the Cortex-M library build, reconciling any remaining
   v7 source or linker dependencies.
3. Add depthwise QLinearConv acceleration.
4. Validate numeric correctness and performance on Cortex-M hardware or QEMU.
5. Add generic grouped convolution support.
6. Wire NHWC-native generation and optional optimization controls as needed.
