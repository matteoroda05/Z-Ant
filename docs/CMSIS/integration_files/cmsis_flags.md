# `zantBuild/cmsis_flags.zig`

## Role

`zantBuild/cmsis_flags.zig` is the build-system entry point for CMSIS-NN
selection flags. It reads `-Denable_CMSIS` and derives CMSIS target state from
the shared Arm build configuration.

## Exported State

`Cmsis_flags` currently stores:

- `enable_cmsis`: set by `-Denable_CMSIS=true`.
- `target_is_cortex_m`: true for an explicit Arm profile; otherwise derived
  from the legacy `-Dcpu` hint.

## CPU Detection

`-Dcpu` is parsed once by `ArmBuildConfig` in `zantBuild/arm_toolchain.zig`.
`Cmsis_flags.init()` receives that configuration:

```zig
pub fn init(b: *std.Build, arm_build: ArmBuildConfig) !Cmsis_flags
```

When `arm_build.profile` is set, `target_is_cortex_m` is true because the
profile is an explicit Cortex-M selection. Without a profile,
`cpuIsCortexM(arm_build.legacy_cpu_hint)` preserves the old CPU-prefix check.
It matches these prefixes case-insensitively:

- `cortex_m`
- `cortex-m`
- `cortexm`

Examples that match:

- `cortex_m33`
- `cortex-m7`
- `CORTEXM4`

Examples that do not match:

- empty `-Dcpu`
- `aarch64`
- `cortex-a53`
- `arm1176jzf_s`

### Why The Detection Is Conservative

The detection only trusts an explicit profile or an explicit Cortex-M-looking
legacy CPU name. If neither is supplied, `target_is_cortex_m` remains false.

This prevents `-Denable_CMSIS=true` from enabling CMSIS on unknown, host, or
non-Cortex-M builds. `-Dcpu=cortex_m*` is still valid for host
(native-target) builds: the shared configuration retains it as
`legacy_cpu_hint`, so CMSIS code generation can use the existing gate without
changing the host target.

The actual decision to use CMSIS is made in `mod_cmsis.zig`; this file only
collects `enable_cmsis` and derives `target_is_cortex_m`.
