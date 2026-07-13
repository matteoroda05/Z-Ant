# Arm build layer

## Purpose

The Arm build layer selects a complete Cortex-M target configuration and checks
that a compatible Arm GNU Toolchain is available. It is implemented by:

- `zantBuild/arm_profiles.zig`
- `zantBuild/arm_toolchain.zig`
- `zantBuild/zantOptions.zig`
- `zantBuild/cmsis_flags.zig`
- `build.zig`

It selects and validates the toolchain data. `cmsis_build.zig` consumes its
resolved GCC and newlib include directories for CMSIS compilation. The layer
does **not** merge newlib libraries into Z-Ant artifacts or perform final
firmware linking.

For user-facing installation and provider instructions, see the
[Arm GNU Toolchain guide](../../toolchains/arm-gnu-toolchain.md).

## Public options

| Option | Meaning |
|---|---|
| `-Darm_profile=<profile>` | Activates an Arm profile. |
| `-Darm_toolchain=managed|external` | Chooses the toolchain provider after a profile is selected. The default is `managed`. |
| `-Darm_toolchain_path=<absolute-path>` | Supplies the root of an external toolchain. It is required only with `-Darm_toolchain=external`. |

`arm_toolchain` and `arm_toolchain_path` are invalid without `arm_profile`.
`arm_toolchain_path` is also invalid in managed mode.

Supported profiles are:

| Profile | Zig target and CPU features | GNU multilib flags |
|---|---|---|
| `cortex_m7_fpv5_d16_softfp` | `thumb-freestanding-eabi`, `cortex_m7+fp_armv8d16` | `-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=softfp -mthumb` |
| `cortex_m4_fpv4_sp_d16_softfp` | `thumb-freestanding-eabi`, `cortex_m4+vfp4d16sp` | `-mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=softfp -mthumb` |

When no `arm_profile` is supplied, Z-Ant keeps the previous native and legacy
`-Dtarget` / `-Dcpu` behaviour. No Arm toolchain is required in that case.

When a profile is supplied, it is the source of truth. An explicit `-Dtarget`
or `-Dcpu` is accepted only when it exactly matches the selected profile.

## Configuration flow

1. `ArmBuildConfig.init()` reads the Arm options and the legacy `target` / `cpu`
   options in one place.
2. With no profile, it constructs the same legacy target query that `build.zig`
   used previously.
3. With a profile, it constructs the exact Thumb freestanding target query and
   validates the selected toolchain.
4. `ZantOptions` passes this configuration to `Cmsis_flags.init()`.
5. `build.zig` resolves `ArmBuildConfig.target_query` instead of parsing target
   options itself.

If configuration fails, `build.zig` logs the reason and exits with a build
failure. It does not use `catch unreachable` for this path.

## CMSIS Cortex-M detection

`cmsis_flags.zig` still owns `-Denable_CMSIS=true`.

For `target_is_cortex_m` it now uses the shared Arm configuration:

- With an Arm profile, the result is `true` because the profile is explicitly a
  Cortex-M target.
- Without an Arm profile, it checks the saved legacy CPU hint for the existing
  `cortex_m`, `cortex-m`, or `cortexm` prefixes.

This preserves host-side CMSIS code-generation behaviour such as
`-Dtarget=native -Dcpu=cortex_m7`. The `-Dcpu` option was moved to the shared
configuration layer; it was not removed.

## Managed provider

Managed mode reads
`scripts/toolchains/arm_gnu_toolchain_15_2_rel1.json`. The manifest is the
single source for the host-specific installation directory and compiler path.

The build never downloads the toolchain. If the expected installation is
missing, it reports the path and suggests:

```bash
./scripts/fetch_arm_toolchain.py
```

For a managed installation, the build requires:

- an `arm-none-eabi-gcc` compiler;
- `-dumpmachine` output equal to `arm-none-eabi`;
- a compiler version that identifies the manifest's pinned release;
- profile-specific GCC include, `libc.a`, `libm.a`, and `libgcc` paths;
- newlib headers containing `string.h`.

## External provider

External mode requires an absolute toolchain root:

```bash
zig build lib \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Darm_toolchain=external \
  -Darm_toolchain_path=/absolute/path/to/arm-gnu-toolchain
```

The build checks the compiler and asks it for the actual selected multilib
paths. It rejects a missing root, a relative root, a compiler for another
target, unresolved outputs such as literal `libc.a`, missing files, and a
profile that the toolchain cannot serve.

External compiler versions are not pinned.

## Newlib discovery and current boundary

The resolver first uses `<sysroot>/include` when `-print-sysroot` returns a
usable sysroot containing `string.h`. Otherwise, it uses:

```text
<toolchain-root>/arm-none-eabi/include
```

After successful validation, the resolved GCC include directory, newlib include
directory, `libc.a`, `libm.a`, and `libgcc` paths remain build-only data in
`ArmBuildConfig`. They are deliberately not exported through runtime
`build_options`. `cmsis_build.zig` receives `ArmBuildConfig` and adds the two
include directories as system include paths when CMSIS and an Arm profile are
selected.

Therefore this layer makes a Cortex-M toolchain selectable and verifiable, but
the real CMSIS Cortex-M cross-build still needs validation with an installed
toolchain. The resolved `libc.a`, `libm.a`, and `libgcc` paths are not attached
or bundled; final executable and firmware linking remain separate follow-up
work.
