# `zantBuild/cmsis_build.zig`

## Role

`cmsis_build.zig` centralizes build-system work needed by the CMSIS-NN backend.
It keeps CMSIS include paths, C source lists, and C compiler flags out of
operator code and out of repeated `build.zig` call sites.

## Constants

- `include_paths`: CMSIS-NN, CMSIS Core, and CMSIS-DSP include directories
  needed for Zig `@cImport` and CMSIS C compilation.
- `c_flags`: baseline flags for CMSIS C sources:
  `-DOPTIONAL_RESTRICT_KEYWORD=__restrict`, `-fbuiltin`, `-O3`,
  `-ffast-math`, and `-fno-math-errno`. Zig 0.15 rejects the deprecated
  `-Ofast` spelling, so `-O3 -ffast-math` provides the equivalent optimization
  policy.
- `c_sources`: the curated CMSIS-NN/CMSIS-DSP source set used by the
  QLinearConv vertical slice. Its CMSIS-NN `v7.0.0` depthwise and convolution
  matmul files live under `Source/ConvolutionFunctions`; obsolete source names
  that no longer exist in `v7.0.0` are not registered.

## Functions

- `configureCmsisModuleIncludes(...)`: adds CMSIS include paths to a Zig module
  only when CMSIS is requested for the current build. With an Arm profile, it
  also adds the resolved GCC and newlib directories as system include paths.
- `configureCmsisRuntimeArtifact(...)`: adds include paths, C sources, C flags,
  and Zig's libc linkage request to a runtime artifact only when CMSIS is
  requested. It does not attach the resolved newlib, libm, or libgcc archives.
- `cmsisRequested(...)`: mirrors the runtime CMSIS gate at build time:
  `enable_cmsis and target_is_cortex_m`.

## Motivation

CMSIS-NN is a C library, not pure Zig code. A Zig wrapper can compile only if
headers are visible, and a runtime artifact can link only if the needed C files
are included. This file gives the project one controlled build entry point for
that work.

## Vendor acquisition

The three vendor trees are installed under `third_party/` by the scripts
documented in `scripts.md`:

- `third_party/CMSIS-NN`
- `third_party/CMSIS_5`
- `third_party/CMSIS-DSP`

The currently selected stable tags are CMSIS-NN `v7.0.0`, CMSIS_5 `5.9.0`, and
CMSIS-DSP `v1.17.0`. The build helper does not run the fetch scripts itself.

## Current source-list validation

The ordinary native test suite passes with 259 tests and three CMSIS-only tests
skipped. The optional host CMSIS suite passes all 262 tests, including direct
signed and unsigned depthwise wrapper comparisons. The curated list includes
`Source/ConvolutionFunctions/arm_nn_mat_mult_kernel_row_offset_s8_s16.c`, which
supplies the transitive symbol used by `arm_convolve_s8.c`.

The existing source registration also contains the M4/M7 depthwise wrapper and
kernel implementations required by `arm_depthwise_conv_wrapper_s8`; adding the
depthwise Zig bridge required no new source-list entry.

## Current cross-build status

The Arm build layer selects and validates a Cortex-M profile and a complete Arm
GNU Toolchain. Both supported CMSIS static-library profiles pass:

```bash
zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Denable_CMSIS=true

zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m4_fpv4_sp_d16_softfp \
  -Denable_CMSIS=true
```

When the managed toolchain is not installed, this stops before compilation and
prints the expected installation path plus `./scripts/fetch_arm_toolchain.py`.
An external complete toolchain can be selected with
`-Darm_toolchain=external -Darm_toolchain_path=/absolute/path`.

The resolver finds compatible newlib headers and libraries. This helper
adds the resolved GCC and newlib include directories to CMSIS modules and C
compilation, so headers such as `string.h` come from the selected complete
toolchain. It deliberately does not attach or bundle `libc.a`, `libm.a`, or
`libgcc`; those archives belong to a later final-executable or firmware-link
step. The successful M4/M7 static-library cross-builds validate this header and
CMSIS C-source plumbing, but not final firmware linkage or execution.

## Current Boundaries

The helper assumes the vendor trees have already been installed under
`third_party/`. It does not fetch CMSIS sources, attach the resolved Arm runtime
archives, validate arbitrary vendor versions, or build CMSIS-NN as a separate
static library target. See `arm_build_layer.md` for Arm profile and toolchain
resolution details and the
[Arm GNU Toolchain guide](../../toolchains/arm-gnu-toolchain.md) for the public
installation and provider contract.
