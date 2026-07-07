# CMSIS-NN — Future Flags & Build Knobs

Post-parity tuning options for the CMSIS-NN QLinearConv backend. **None are
required for Cortex-M4/M7 correctness today.** They matter once the vendor sources
are in place and you move to newer chips, chase speed, or need bit-exact output.

There are two distinct groups:

- **CMSIS-NN kernel macros** — compile-time `-D` defines passed to the CMSIS C
  sources (they belong in the `c_flags` list in `zantBuild/cmsis_build.zig`). They
  tune CMSIS itself.
- **Z-Ant build options** — Zig `-D` options and `build.zig` logic. They tune how
  Z-Ant builds/links CMSIS, not the kernels' math.

Background: several kernel macros touch **requantization** — the step that squeezes
the `int32` conv accumulator back into `int8` (per-channel multiply → round → shift).

---

## 1. CMSIS-NN kernel macros

### 1a. Behavior-affecting (can change the output numbers)

| Macro | What it does | Why it's touchy |
|-------|--------------|-----------------|
| `CMSIS_NN_USE_SINGLE_ROUNDING` | Selects "single rounding" instead of the default legacy "double rounding" in requantize (fewer ops, faster on some cores). | Can differ by 1 LSB in the output. Whatever reference you bit-compare against must use the same scheme. It's a **numeric contract**, not a free win. |
| `CMSIS_NN_USE_REQUANTIZE_INLINE_ASSEMBLY` | Hand-written assembly for the requantize step instead of C. Faster on Cortex-M4, slower on some others. | *Mostly* speed, but Arm has observed different results with Arm Compiler on Cortex-M7 — verify on your exact toolchain+core. |

### 1b. Pure performance (same numbers, different speed)

| Macro | What it does | When it matters |
|-------|--------------|-----------------|
| `ARM_MATH_AUTOVECTORIZE` | On Helium/MVE chips (Cortex-M55/M85), uses compiler-auto-vectorized C loops instead of hand-written vector assembly. | Only relevant on Helium targets, and required if building them at `-O0`. Does nothing on M4/M7. Becomes real only if Z-Ant targets M55/M85. |
| `OPTIONAL_RESTRICT_KEYWORD` (make conditional) | Injects `restrict` so the compiler assumes non-overlapping pointers and optimizes harder. Currently set to `__restrict` **unconditionally** and safely. | Arm says it mainly helps int8 conv on Cortex-M7, little/no benefit on M4/M33. "Conditional by CPU" = enable only where it helps. Low priority; current always-on is fine. |

---

## 2. Z-Ant build options

| Option | What it does | Status today |
|--------|--------------|--------------|
| Configurable CMSIS path (e.g. `-Dcmsis_path=…`) | Let the build point at an existing CMSIS install instead of the in-repo `third_party/…` copy. | `cmsis_path` is commented out in `cmsis_flags.zig`; include paths are hardcoded to `third_party/`. Pairs with the "vendor the sources" task (bundled copy *or* external pointer). |

---

## Summary

- **1a** = pick a numeric/rounding contract and make your reference match it.
- **1b** = speed toggles that leave results identical (Helium-only or M7-favoring).
- **2** = build flexibility, no effect on kernel math.

All of this is post-parity: reach for it only after the CMSIS sources are vendored,
depthwise + grouped QLinearConv are in, and you're moving to Helium chips or
squeezing for performance.
