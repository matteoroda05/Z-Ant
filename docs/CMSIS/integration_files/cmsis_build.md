# `zantBuild/cmsis_build.zig`

## Role

`cmsis_build.zig` centralizes build-system work needed by the CMSIS-NN backend.
It keeps CMSIS include paths, C source lists, and C compiler flags out of
operator code and out of repeated `build.zig` call sites.

## Constants

- `include_paths`: CMSIS-NN, CMSIS Core, and CMSIS-DSP include directories
  needed for Zig `@cImport` and CMSIS C compilation.
- `c_flags`: baseline flags for CMSIS C sources, including `-fbuiltin` and
  `-Ofast`.
- `c_sources`: the current minimal CMSIS-NN/CMSIS-DSP source set used by the
  QLinearConv vertical slice.

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

## Current Boundaries

The helper assumes the vendor tree exists under `third_party/`. It does not
fetch CMSIS sources, validate vendor versions, or build CMSIS-NN as a separate
static library target yet.

