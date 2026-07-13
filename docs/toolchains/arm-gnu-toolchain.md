# Arm GNU Toolchain

Z-Ant uses a complete `arm-none-eabi` toolchain for Cortex-M builds. Z-Ant does
not contain its own libc implementation: the toolchain supplies newlib headers,
`libc.a`, `libm.a`, `libgcc`, and the Cortex-M multilib variants.

## Supported managed release

The managed provider is pinned to **Arm GNU Toolchain 15.2.Rel1**. The release
does not change with the Cortex-M profile; the selected profile chooses a
different multilib from the same installation.

Install the managed toolchain from the repository root:

```bash
./scripts/fetch_arm_toolchain.py
```

The fetcher detects the host package, downloads the official archive, verifies
its pinned SHA-256 checksum, and extracts it under
`third_party/toolchains/`. The build never runs the fetcher automatically.

Fetcher flags:

- `-h`, `--help`: show usage and supported hosts.
- `--force`: download and replace the managed 15.2.Rel1 installation again.

There is no version flag. Supporting another managed release requires an
intentional update to the pinned manifest and checksums.

## Build options

| Option | Meaning |
|---|---|
| `-Darm_profile=<profile>` | Select the complete Cortex-M target configuration. |
| `-Darm_toolchain=managed|external` | Select the provider. It defaults to `managed` when a profile is active. |
| `-Darm_toolchain_path=<absolute-path>` | Supply the root of an external toolchain. Required only with `external`. |

Supported profiles:

| Profile | CPU and FPU | Float ABI |
|---|---|---|
| `cortex_m7_fpv5_d16_softfp` | Cortex-M7, FPv5-D16 | `softfp` |
| `cortex_m4_fpv4_sp_d16_softfp` | Cortex-M4, FPv4-SP-D16 | `softfp` |

Example managed selection:

```bash
zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m7_fpv5_d16_softfp
```

When a profile is selected, it supplies the target, CPU features, FPU, float
ABI, Thumb mode, and GNU multilib flags. Do not also pass `-Dtarget` or `-Dcpu`
unless they exactly match the profile values documented by the Arm build layer.

Without `-Darm_profile`, the legacy `-Dtarget` and `-Dcpu` behavior remains
available and no Arm toolchain is resolved.

## Managed provider

Managed mode reads
`scripts/toolchains/arm_gnu_toolchain_15_2_rel1.json` to find the expected
host-specific installation and compiler. It validates:

- the toolchain root and `arm-none-eabi-gcc`;
- the `arm-none-eabi` target triple;
- the pinned release in managed mode;
- the GCC include directory and newlib `string.h`;
- the profile-selected `libc.a`, `libm.a`, and `libgcc` paths.

If the installation is missing, run the fetcher explicitly. The build never
falls back silently to an unrelated system toolchain.

## External provider

Use a complete external toolchain with:

```bash
zig build lib -Dmodel=beer \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Darm_toolchain=external \
  -Darm_toolchain_path=/absolute/path/to/arm-gnu-toolchain
```

The path must be absolute and identify the toolchain root, not only an include
directory or `libc.a`. The expected logical structure is:

```text
<toolchain-root>/
├── bin/arm-none-eabi-gcc
├── arm-none-eabi/include/
├── arm-none-eabi/lib/
└── lib/gcc/arm-none-eabi/<version>/
```

External versions are not pinned, but the compiler must target
`arm-none-eabi` and provide the multilib selected by the profile.

## Current integration boundary

For a CMSIS build with an Arm profile, the build layer now adds the resolved GCC
and newlib include directories as system include paths for CMSIS modules and C
sources. This supplies headers such as `string.h` from the selected complete
toolchain; Z-Ant does not copy those headers into the repository.

The resolved `libc.a`, `libm.a`, and `libgcc` archives are deliberately not
merged into the generated Z-Ant static library. Their use belongs to a later
final-executable or firmware-link step. The managed Cortex-M7 and Cortex-M4
cross-builds still need to be run with an installed toolchain to validate the
header integration and expose any remaining compilation errors.

Startup code, the board memory map, the linker script, final executable
creation, flashing, and hardware execution are separate board-integration
responsibilities and will be reviewed before real-device validation.
