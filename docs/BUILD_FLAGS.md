# Z-Ant Build Configuration Flags

The Z-Ant build system is highly configurable. You can pass these flags to the `zig build` command using `-D[flag]=[value]`.

| Flag | Type | Default | Description | Relevant Steps |
|------|------|---------|-------------|----------------|
| **General Build Options** | | | | |
| `-Darm_profile` | enum | `null` | Select a complete public Cortex-M configuration: `cortex_m7_fpv5_d16_softfp` or `cortex_m4_fpv4_sp_d16_softfp`. | Cortex-M builds |
| `-Darm_toolchain` | enum | `managed` with an Arm profile | Select `managed` or `external` Arm GNU Toolchain provider. | Cortex-M builds |
| `-Darm_toolchain_path` | string | `null` | Absolute external Arm GNU Toolchain root. Required only with `-Darm_toolchain=external`. | Cortex-M builds |
| `-Dtarget` | string | `"native"` | Target architecture (e.g., `thumb-freestanding`, `x86_64-linux`) | All |
| `-Dcpu` | string | `null` | CPU model (e.g., `cortex_m33`, `cortex-m7`). CMSIS auto-detection treats values starting with `cortex_m`, `cortex-m`, or `cortexm` as Cortex-M, case-insensitively. | All |
| `-Doptimize` | enum | `Debug` | Optimization level (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) | All |
| `-Dtrace_allocator` | bool | `true` | Use a tracing allocator for memory debugging | All |
| `-Dallocator` | string | `"raw_c_allocator"` | Underlying allocator to use | All |
| `-Denable_CMSIS` | bool | `false` | Request CMSIS-NN usage. This requires an Arm profile or a legacy Cortex-M `-Dcpu` hint. | Build modules |
| **Codegen & Model Options** | | | | |
| `-Dmodel` | string | `"mnist-8"` | Name of the model to process | `lib-gen`, `lib-exe`, `lib`, `lib-test` |
| `-Dmodel_path` | string | `datasets/...` | Path to the ONNX model file. Defaults to `datasets/models/{model}/{model}.onnx` | `lib-gen`, `lib-exe` |
| `-Dgenerated_path` | string | `generated/{model}/` | Output directory for generated code | `lib-gen`, `lib-exe`, `lib` |
| `-Doutput_path` | string | `""` | Custom output directory for the compiled static library | `lib` |
| `-Dshape` | string | `""` | Input tensor shape override (e.g., "1,3,224,224") | `lib-gen`, `lib-exe` |
| `-Dtype` | string | `"f32"` | Input tensor data type | `lib-gen`, `lib-exe` |
| `-Doutput_type` | string | `"f32"` | Output tensor data type | `lib-gen`, `lib-exe` |
| `-Dcomm` | bool | `false` | Generate code with comments included | `lib-gen`, `lib-exe` |
| `-Ddynamic` | bool | `true` | Enable dynamic memory allocation | `lib-gen`, `lib-exe` |
| `-Dstatic_planning` | string | `disabled` | Use with `-Ddynamic=false` to generate a compile-time memory plan. Simply use `enabled` to enable static planning. Other options are `pressure_then_size`, `pressure_then_liveness`, `liveness_first`, `size_first`, `first_step`, and their inverse variants (append `_inverse_first_step`; not valid with `disabled` or `enabled`). See `static_memory_planning.md` for more details. | `lib-gen`, `lib-exe` |
| `-Dforce_bnb` | bool | `false` | Use with `-Ddynamic=false` and `-Dstatic_planning` ≠ `disabled` to force branch-and-bound static planning. Note: on large models, this can be very slow. | `lib-gen`, `lib-exe` |
| `-Dfuse` | bool | `false` | Enable Kernel fusion optimization | `lib-gen`, `lib-exe` |
| `-Ddo_export` | bool | `false` | Generate exportable functions (for shared libs/FFI) | `lib-gen`, `lib-exe` |
| `-Dv` | string | `"v1"` | Codegen version to use | `lib-gen`, `lib-exe` |
| `-Dlog` | bool | `false` | Enable verbose logging during generation | `lib-gen`, `lib-exe` |
| `-Dxip` | bool | `false` | Enable XIP (Execute In Place) for neural network weights | `lib-gen`, `lib-exe` |
| `-Duse_tensor_pool` | bool | `false` | Allocate large tensor arrays to a specific `tensor_pool` section | Embedded targets |
| **Testing & Benchmarking** | | | | |
| `-Denable_user_tests` | bool | `false` | Generate user-defined test code | `lib-gen`, `lib-exe` |
| `-Dop` | string | `"all"` | Limit testing to a specific operator name | `test` |
| `-Dtest_name` | string | `""` | Specify a specific test case name to run | `test` |
| `-Dfull` | bool | `false` | Run the full benchmark suite | `benchmark` |
### Arm Cortex-M Profiles and Toolchain

Select a complete Cortex-M configuration with a public Arm profile:

```sh
zig build lib -Dmodel=my_model \
  -Darm_profile=cortex_m7_fpv5_d16_softfp
```

The profile supplies the target, CPU features, FPU, floating-point ABI, Thumb
mode, and GNU multilib selection. The default provider is the managed Arm GNU
Toolchain 15.2.Rel1 installation. An external complete `arm-none-eabi`
toolchain can be supplied instead. See the
[Arm GNU Toolchain guide](toolchains/arm-gnu-toolchain.md) for installation,
provider selection, supported profiles, and the current integration boundary.

### CMSIS-NN Integration Switch

Request CMSIS-NN usage with:

```sh
zig build lib -Dmodel=my_model \
  -Darm_profile=cortex_m7_fpv5_d16_softfp \
  -Denable_CMSIS=true
```

This exports `build_options.enable_cmsis` and
`build_options.target_is_cortex_m` to Zig modules. An Arm profile identifies a
Cortex-M target directly. Without a profile, the legacy CPU check remains
available and accepts `cortex_m`, `cortex-m`, or `cortexm` prefixes,
case-insensitively. A legacy Cortex-M `-Dcpu` hint may still be used on a native
build to exercise host-side CMSIS code generation.

### Common Commands

* **Generate Library:** `zig build lib-gen -Dmodel=my_model`
* **Generate a static memory plan:** `zig build lib-gen -Dmodel=my_model -Ddynamic=false -Dstatic_planning=enabled`
* **Generate a static memory plan with branch-and-bound**: `zig build lib-gen -Dmodel=my_model -Ddynamic=false -Dstatic_planning=enabled -Dforce_bnb=true`
* **Compile Cortex-M7 Static Lib:** `zig build lib -Dmodel=my_model -Darm_profile=cortex_m7_fpv5_d16_softfp`
* **Compile Cortex-M7 Static Lib with CMSIS requested:** `zig build lib -Dmodel=my_model -Darm_profile=cortex_m7_fpv5_d16_softfp -Denable_CMSIS=true`
* **Run Unit Tests:** `zig build test`
* **Run Benchmarks:** `zig build benchmark -Dfull=true`
