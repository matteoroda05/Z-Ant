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
  `target_is_cortex_m` from a selected Arm profile or, when no profile is
  selected, from the legacy `-Dcpu` Cortex-M hint. CMSIS is used only when
  `enable_cmsis and target_is_cortex_m`.
- **The Arm build layer is available.** It provides public Cortex-M7 and
  Cortex-M4 profiles plus managed and external complete Arm GNU Toolchain
  providers. Managed mode is pinned to 15.2.Rel1. The build resolves and checks
  the selected newlib headers and libraries. CMSIS modules and C sources now
  receive the resolved GCC and newlib system include paths; the runtime
  archives are not bundled into Z-Ant's static library.
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
- **Current validation:** `zig build test` passes with 258 tests. The optional
  host CMSIS build also passes all 258 tests after completing the curated source
  list. The seven Arm profile and provider-option tests pass, including missing
  and invalid toolchain-path errors. A real managed Cortex-M7 or Cortex-M4
  compiler/multilib resolution has not yet been validated on this checkout.

## Current validation boundary

### Host CMSIS source-list validation passes

The following command compiles and links the curated CMSIS-NN source set and
passes all 258 tests:

```bash
zig build test -Denable_CMSIS=true -Dcpu=cortex_m7
```

The source list now includes
`arm_nn_mat_mult_kernel_row_offset_s8_s16.c`, which supplies the transitive
implementation used by `arm_convolve_s8.c`.

### Managed Cortex-M cross-build has not been run yet

The preferred Cortex-M7 command is:

```bash
zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Denable_CMSIS=true
```

The Arm toolchain resolver locates and validates the profile-compatible GCC
include directory, newlib include directory, `libc.a`, `libm.a`, and `libgcc`.
`cmsis_build.zig` now receives that configuration and adds the GCC/newlib
directories as system include paths. The managed toolchain is not installed in
this checkout, so the Cortex-M7 build has not yet confirmed that CMSIS compiles
past `string.h` or exposed the next compiler error.

The next step is to install the pinned managed toolchain and run the Cortex-M7
cross-build, then repeat with the Cortex-M4 profile. The resolved `libc.a`,
`libm.a`, and `libgcc` archives remain reserved for a later final-executable or
firmware-link decision. See the
[Arm GNU Toolchain guide](../toolchains/arm-gnu-toolchain.md) and the detailed
[Arm build layer notes](integration_files/arm_build_layer.md).

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

1. Install the managed 15.2.Rel1 toolchain and validate the Cortex-M7 profile,
   header paths, and multilib resolution.
2. Repeat the static-library cross-build with the Cortex-M4 profile and fix any
   remaining header or C-source errors.
3. Decide and implement final-executable linking with the resolved runtime
   archives when that validation artifact is introduced.
4. Add depthwise QLinearConv acceleration.
5. Validate numeric correctness and performance on Cortex-M hardware or QEMU.
6. Add generic grouped convolution support.
7. Wire NHWC-native generation and optional optimization controls as needed.
