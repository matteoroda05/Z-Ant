# `zantBuild/cmsis_flags.zig`

## Role

`zantBuild/cmsis_flags.zig` is the build-system entry point for CMSIS-NN
selection flags. It reads the user-facing Zig build options and stores the
result in `Cmsis_flags`.

## Exported State

`Cmsis_flags` currently stores:

- `enable_cmsis`: set by `-Denable_CMSIS=true`.
- `target_is_cortex_m`: derived from the `-Dcpu` string.

## CPU Detection

This file reads the raw `-Dcpu` value from Zig's parsed user input:

```zig
const cpu = readCpuOption(b);
```

`cpuIsCortexM(cpu)` returns true only when the CPU string starts with one of
these prefixes, case-insensitively:

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

The detection only trusts explicit Cortex-M-looking CPU names. If the user does
not pass `-Dcpu`, `target_is_cortex_m` remains false.

This prevents `-Denable_CMSIS=true` from enabling CMSIS on unknown, host, or
non-Cortex-M builds. `-Dcpu=cortex_m*` is valid for host (native-target) builds
too: `build.zig` only feeds `-Dcpu` into the native target-query resolution
when cross-compiling, so this file's independent read of `-Dcpu` (via
`b.user_input_options`) still activates the gate without corrupting the host
target.

### Future Target Detection

This file already computes `target_is_cortex_m` from `-Dcpu`. In the future,
that check could use Zig target/CPU metadata instead, while still exporting the
same boolean:

```zig
build_options.target_is_cortex_m
```

So `mod_cmsis.zig` can keep using:

```zig
enable_cmsis and target_is_cortex_m
```

The actual decision to use CMSIS is made in `mod_cmsis.zig`; this file only
collects and derives the build flags.
