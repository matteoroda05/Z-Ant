# CMSIS-NN QLinearConv — State of the Art (2026-07-07)

Brief snapshot of where the rebuilt CMSIS-NN QLinearConv integration stands, and
a deeper look at what is still missing to reach parity with (and go beyond) the
outdated `feat/CMSIS-integration` branch described in `deep-research-report.md`.

## Current state (what works today)

- **Build wiring is in place.** `zantBuild/cmsis_build.zig` attaches CMSIS include
  paths, a curated C-source list, the per-file C flags
  (`-DOPTIONAL_RESTRICT_KEYWORD=__restrict -fbuiltin -Ofast -fno-math-errno`),
  and `linkLibC()` to the artifacts that may run CMSIS kernels.
- **The architecture gate is real** (the old branch's hardcoded
  `targetIsCortex = true` is gone): `cmsis_flags.zig` derives
  `target_is_cortex_m` from `-Dcpu` via `cpuIsCortexM`, and
  `cmsisUsed() = enable_cmsis and target_is_cortex_m`.
- **Codegen-time preparation.** `IR_zant/cmsis/prepare.zig` precomputes the static
  CMSIS data (OHWI `i8` filter, `i32` bias, per-channel multiplier/shift) at
  lib-gen and emits it into `static_parameters.zig` as `cmsis_` constants; the
  original filter/bias are dropped from flash for prepared nodes.
- **Layout-only runtime bridge.** `cmsis_qlinearconv.zig` is reduced to two public
  prepared bridges (`qlinearconvNchw`, `qlinearconvNhwc`) over a single private
  kernel call (`runCmsisConvolve` → `arm_convolve_wrapper_s8`). Runtime does only
  the input-dependent work (NCHW↔NHWC transpose, `u8`→`i8` shift, offsets,
  writeback).
- **Supported surface today:** standard convolution, `group == 1`, `i8`/`u8`
  activations & weights, `auto_pad` NOTSET/empty, initializer weights/scales.
  Everything else falls back to Z-Ant's embedded (native, non-accelerated) path.
- **Verified:** `zig build test` passes; CMSIS and non-CMSIS lib-gen on `beer`
  generate the expected symbols. The generated CMSIS lib is verified by symbol
  inspection only — it is not yet built for a device (see below).

## What is still missing

### 1. Actual CMSIS-NN kernel sources are not vendored (blocking for any real build)
`cmsis_build.zig` references `third_party/CMSIS-NN/…`, `third_party/CMSIS_5/…`,
and `third_party/CMSIS-DSP/…`, but **none of those directories exist in the repo**.
The build wiring is complete, but there is no C code to compile or link. Until the
CMSIS-NN (+ CMSIS Core + the one CMSIS-DSP file) trees are vendored or added as
submodules, no device/CMSIS build can actually link `arm_convolve_wrapper_s8`.
This is the first hard prerequisite for everything else.

### 2. Grouped convolution (`group > 1`) is not CMSIS-accelerated
`qlinearconv_isSupported` returns `false` for `group != 1`, so grouped nodes take
the slow embedded path. The old branch handled true grouped conv by looping the
standard wrapper over channel-sliced groups and re-interleaving the outputs.
Reaching parity needs: a grouped `prepare.zig` path (per-group filter slicing) and
a grouped runtime bridge (per-group `runCmsisConvolve` + interleave).

### 3. Depthwise convolution is not CMSIS-accelerated (highest-impact gap)
Depthwise is the extreme `group == in_channels` case and dominates MobileNet-style
models — on `beer`, 6 of 21 QLinearConv nodes are non-preparable for exactly this
reason. CMSIS handles it with a **different** kernel (`arm_depthwise_conv_wrapper_s8`)
and a **different** filter layout (`[1, H, W, C_out]`) and buffer-size getter. The
relevant C sources are already in `cmsis_build.zig`'s list, so the wiring
anticipates it, but there is currently no depthwise prepare path and no depthwise
bridge. This is the single most valuable addition for real models and should be
tracked separately from generic grouped conv.

### 4. No on-hardware validation
The generated CMSIS lib cannot compile on the host (`@cImport("arm_nnfunctions.h")`
needs the vendor headers + a Cortex-M toolchain). Once #1 is done, the updated path
needs a real Cortex-M4/M7 (or QEMU) run to confirm numeric correctness against the
embedded reference and to measure latency/flash. No such test exists yet.

### 5. NHWC-native path is not wired (minor)
`qlinearconvNhwc` exists but the generator always emits the NCHW call, so the
transpose is always paid. Auto-selecting the NHWC bridge for NHWC models (or a
model-level layout pass) would remove the runtime transpose entirely. Optional.

### 6. Optional CMSIS configurability / future-proofing (optimization stage)
Not required for M4/M7 correctness, but needed for a robust, tunable backend:
`ARM_MATH_AUTOVECTORIZE` (Helium / Cortex-M55/M85), the requantization switches
`CMSIS_NN_USE_SINGLE_ROUNDING` and `CMSIS_NN_USE_REQUANTIZE_INLINE_ASSEMBLY`,
making `OPTIONAL_RESTRICT_KEYWORD` conditional by CPU family, and restoring a
configurable external CMSIS path instead of a hardcoded `third_party` layout.
Also minor build ergonomics: making `-Dcpu=cortex_m*` usable for lib-gen without
the native-target parse failure.

## Priority order

1. Vendor the CMSIS-NN / CMSIS Core / CMSIS-DSP sources (#1) — unblocks builds.
2. Depthwise support (#3) — biggest real-model coverage win.
3. On-hardware validation of the current + depthwise paths (#4).
4. Generic grouped conv (#2).
5. NHWC wiring (#5) and configurability/optimization knobs (#6) as needed.
