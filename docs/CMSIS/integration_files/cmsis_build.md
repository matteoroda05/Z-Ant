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
  only when CMSIS is requested for the current build.
- `configureCmsisRuntimeArtifact(...)`: adds include paths, C sources, C flags,
  and libc linkage to a runtime artifact only when CMSIS is requested.
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

## Current cross-build status

The configured include directories and C-source paths now exist for the
selected vendor versions. The Cortex-M7 build proceeds into CMSIS C compilation:

```bash
zig build lib -Dmodel=beer -Dtarget=thumb-freestanding \
  -Dcpu=cortex_m7 -Denable_CMSIS=true
```

It currently stops because the `thumb-freestanding` environment cannot find
the C standard-library header `string.h`. The next build-system requirement is
to provide a compatible Arm newlib/toolchain include directory (and its runtime
support where required). Only after that is available can the curated source
set be fully link-validated.

## Current Boundaries

The helper assumes the vendor trees have already been installed under
`third_party/`. It does not fetch CMSIS sources, provide freestanding C-library
headers, validate arbitrary vendor versions, or build CMSIS-NN as a separate
static library target.
