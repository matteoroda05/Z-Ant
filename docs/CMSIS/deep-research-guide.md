# CMSIS-NN Integration Plan for Z-Ant Feature Branch

## What the earlier CMSIS integration actually did

The older `feat/CMSIS-integration` branch implemented CMSIS-NN as a build-time optional backend. It introduced a dedicated `cmsis_flags.zig` file, added a boolean `enable_cmsis` field into `ZantOptions`, and exported that flag through `build_options` so runtime Zig code could make a compile-time dispatch decision. In the same branch, the build system conditionally linked CMSIS support into many artifacts through helper functions such as `configureCmsisModuleIncludes()` and `configureCmsisSupport()`. fileciteturn56file0L3-L3 fileciteturn46file0L3-L3 fileciteturn47file0L3-L3 fileciteturn14file0L3-L3 fileciteturn51file0L3-L3

That build helper expected a very specific vendored directory layout under `third_party/`: `CMSIS-NN`, `CMSIS_5/CMSIS/Core/Include`, and `CMSIS-DSP/{Include,PrivateInclude}`. It then compiled a **manual**, hand-maintained list of CMSIS-NN C files, and passed these C flags to them: `-DOPTIONAL_RESTRICT_KEYWORD=__restrict`, `-fbuiltin`, `-Ofast`, and `-fno-math-errno`. The exact old source list centered on the s8 convolution path: `arm_convolve_wrapper_s8.c`, `arm_convolve_1x1_s8_fast.c`, `arm_convolve_1x1_s8.c`, `arm_convolve_1_x_n_s8.c`, `arm_convolve_s8.c`, `arm_convolve_get_buffer_sizes_s8.c`, the depthwise s8 wrappers/kernels, the s8 matmul support kernels, the q7/q15 and s8/s16 conversion helpers, plus an extra `arm_dot_prod_f32.c` unit from CMSIS-DSP. fileciteturn9file0L3-L3

On the runtime side, the old branch added a substantial Zig wrapper around CMSIS-NN’s convolution APIs. That wrapper computed per-channel multipliers and shifts, converted Z-Ant tensors into CMSIS-compatible dimensions, allocated scratch buffers from an arena allocator, queried workspace size with the CMSIS `*_get_buffer_size` helpers, packed weights into CMSIS-expected memory layouts, and handled three execution modes: standard convolution, depthwise convolution, and grouped convolution. It also converted unsigned activations into the signed `s8` domain expected by CMSIS, then reordered the result back into Z-Ant’s output convention. fileciteturn10file0L3-L3 fileciteturn11file0L3-L3 fileciteturn41file0L3-L3

Those runtime choices match the CMSIS-NN public API. For the s8 wrapper path, CMSIS expects input activations in **NHWC** form, filters in `[C_OUT, H, W, C_IN]`, bias as `int32`, output in **NHWC**, and a scratch size returned by `arm_convolve_wrapper_s8_get_buffer_size()`. The depthwise wrapper similarly expects `[1, H, W, C_OUT]` filters and has its own wrapper buffer-size API. CMSIS’s own wrapper source shows that `arm_convolve_wrapper_s8()` dynamically dispatches to `arm_convolve_1x1_s8_fast`, `arm_convolve_1x1_s8`, `arm_convolve_1_x_n_s8`, or generic `arm_convolve_s8`, which is why the earlier branch needed more than a single C file. citeturn7view0turn8view0turn19view0turn19view1

The weak point of the older implementation was not the wrapper logic itself, but the integration discipline around it. The old `mod_cmsis.zig` hard-coded `targetIsCortex: bool = true`, which means the compile-time gate was not actually target-derived. The old guide also still documented a manual source edit that swapped `cmsis_nn.qlinearconv` for `cmsis_nn.qlinearconvWithTranspose` when transpose handling was needed. In other words, the branch had working CMSIS-specific logic, but it still relied on a few brittle conventions that should not be carried forward unchanged. fileciteturn13file0L3-L3 fileciteturn15file0L3-L3 fileciteturn40file0L3-L3

The good news is that the current `feature` branch already has a cleaner insertion point than the old architecture did. QLinearConv is now centralized under `src/codegen/IR_zant/op_union/operators/op_qlinearconv/`. The front-end codegen file already emits calls to `tensMath.qlinear_conv_dispatch`, and `zant_math_standard.zig` already re-exports that dispatch symbol. The current dispatch function, however, still always returns the embedded-Zig fallback. At the same time, the current `feature` build configuration no longer exposes any CMSIS-specific option in `ZantOptions` or in `docs/BUILD_FLAGS.md`. So the feature branch is structurally ready for CMSIS-NN, but the actual wiring is missing. fileciteturn45file0L3-L3 fileciteturn44file0L3-L3 fileciteturn37file0L3-L3 fileciteturn18file0L3-L3 fileciteturn38file0L3-L3

## How to reproduce the older work in the feature branch architecture

The key practical observation is that the `feature` branch does **not** need a wholesale QLinearConv rewrite. The current code-generation front-end already targets `qlinear_conv_dispatch`, and the math layer already exports it. That means the replica branch should keep the current feature-branch front-end and fallback kernels, then port the old CMSIS backend into the dispatch choke point. fileciteturn45file0L3-L3 fileciteturn44file0L3-L3 fileciteturn32file0L3-L3 fileciteturn37file0L3-L3

### Which files should be kept, copied, or adapted

**Keep essentially unchanged in `feature`:**  
`src/codegen/IR_zant/op_union/operators/op_qlinearconv/op_qlinearconv.zig` should stay as the code-generation front-end, because it already emits `qlinear_conv_dispatch`. `src/codegen/IR_zant/op_union/operators/zant_math_standard.zig` should also stay, because it already re-exports `qlinear_conv_dispatch`. The current `zant_qlinearconv.zig` file should remain the fallback implementation for non-CMSIS builds and unsupported type/layout combinations. fileciteturn45file0L3-L3 fileciteturn44file0L3-L3 fileciteturn32file0L3-L3

**Copy and adapt from `feat/CMSIS-integration`:**  
The old `src/Core/Tensor/Cmsis/wrappers/cmsis_nn.zig` is the most valuable porting asset. Its core logic should be copied into a new file inside the current QLinearConv folder, for example `src/codegen/IR_zant/op_union/operators/op_qlinearconv/cmsis_qlinearconv.zig`, and then adapted to current imports, current tensor types, and the current operator folder structure. The old `zantBuild/cmsis_flags.zig` should be restored in the new build architecture. The old CMSIS acquisition scripts—`fetch_cmsis_nn.sh`, `fetch_cmsis_5.sh`, and `fetch_cmsis_dsp.sh`—are also worth carrying forward because they encode the expected vendor layout under `third_party/`. fileciteturn10file0L3-L3 fileciteturn11file0L3-L3 fileciteturn56file0L3-L3 fileciteturn55file0L3-L3 fileciteturn53file0L3-L3 fileciteturn54file0L3-L3

**Adapt, but do not copy verbatim:**  
The old `mod_cmsis.zig` should not be copied as-is because of its hard-coded Cortex assumption. The old `build.zig` CMSIS wiring should also not be copied mechanically, because the `feature` branch now routes modules differently: current `IR_zant` is created in `zantModules.zig`, and `build_options` is currently attached only to `zant_utils_mod` and `codegen_mod`, not to `IR_zant_mod`. Since the CMSIS dispatch lives under `IR_zant`, the new build flag must be made visible there. fileciteturn13file0L3-L3 fileciteturn20file0L3-L3 fileciteturn42file0L3-L3

### The exact replica path in the new architecture

The first step is to reintroduce the CMSIS build option into the current build-option graph. In the old branch, `cmsis_flags.zig` exposed `-Denable_CMSIS`, and `zantStepOptions.zig` exported an internal `enable_cmsis` boolean via `build_options`. The same model still fits the `feature` architecture well; it just needs to be added back into the current `ZantOptions` and `build_step_option` flow. fileciteturn56file0L3-L3 fileciteturn46file0L3-L3 fileciteturn47file0L3-L3 fileciteturn18file0L3-L3 fileciteturn19file0L3-L3

A practical compatibility-friendly implementation would look like this:

```zig
// zantBuild/cmsis_flags.zig
const std = @import("std");

pub const Cmsis_flags = struct {
    enable_cmsis: bool,

    pub fn init(b: *std.Build) !Cmsis_flags {
        return .{
            .enable_cmsis =
                b.option(bool, "enable_CMSIS", "Enable CMSIS support") orelse
                b.option(bool, "enable_cmsis", "Enable CMSIS support") orelse
                false,
        };
    }
};
```

The second step is to make `build_options` visible inside `IR_zant_mod`. Right now the current feature branch creates `IR_zant_mod` with only the `zant_utils` import, while `build_options` is attached to `zant_utils_mod` and `codegen_mod`. Because the future CMSIS dispatch will sit in `IR_zant/op_union/operators/op_qlinearconv/utils_qlinearconv.zig`, that file must be able to `@import("build_options")`. So `zantModules.init()` needs one additional line: attach `build_options` to `IR_zant_mod`. fileciteturn20file0L3-L3 fileciteturn42file0L3-L3

```zig
// inside zantBuild/zantStepOptions.zig
build_options.addOption(bool, "enable_cmsis", zantOptions.cmsis_flags.enable_cmsis);

// inside zantBuild/zantModules.zig
IR_zant_mod.addOptions("build_options", zantStepOptions.build_step_option);
```

The third step is to reintroduce a CMSIS build helper for include paths and C-source linkage. In the old branch that helper lived in `zantBuild/utils.zig`. In the `feature` branch, it is cleaner to add a dedicated file such as `zantBuild/cmsis_build.zig` rather than restoring a generic `utils.zig`. That helper should do two separate jobs: one function to add include paths to the `IR_zant` module so Zig `@cImport` can see CMSIS headers, and a second function to add C sources plus C flags to the actual compile artifacts that will execute the kernels. The old branch already encoded the expected vendor paths and the exact baseline source list, so it is the best starting point. fileciteturn9file0L3-L3 fileciteturn55file0L3-L3 fileciteturn53file0L3-L3 fileciteturn54file0L3-L3

The fourth step is the most important runtime choice: **port the old NCHW-bridge wrapper, not the NHWC-only wrapper, as the default CMSIS path**. This is the right starting point because the current `feature` branch still interprets tensors in NCHW order inside `zant_qlinearconv.zig`, where the shape is read as batch, channels, height, width. By contrast, the old CMSIS wrapper had one path that assumed data was already NHWC and another path that explicitly converted from NCHW to NHWC and back. In practice, that makes the old transpose-bridge path the appropriate default for a faithful `feature`-branch replica. That is an inference from the current operator’s tensor indexing and from the old wrapper’s explicit NCHW⇄NHWC conversions. fileciteturn32file0L3-L3 fileciteturn10file0L3-L3 fileciteturn11file0L3-L3

The fifth step is to change only the body of `qlinearconv_dispatch()` in `utils_qlinearconv.zig`. That file is already the single backend choke point. It even contains a comment saying “Direct CMSIS-NN wrapper,” but currently returns `qlinearconv_embedded_lean()`. So the replica branch should keep the current file and add a compile-time gate there. The front-end generator does **not** need to be touched. fileciteturn37file0L3-L3 fileciteturn45file0L3-L3

```zig
// inside utils_qlinearconv.zig
const build_options = @import("build_options");
const cmsis_qlinearconv = @import("cmsis_qlinearconv.zig");

inline fn cmsisEnabled() bool {
    return comptime @hasDecl(build_options, "enable_cmsis") and build_options.enable_cmsis;
}

// keep the existing signature
pub fn qlinearconv_dispatch(...) !void {
    if (comptime cmsisEnabled()) {
        return cmsis_qlinearconv.qlinearconv_nchw_bridge(...);
    }
    return qlinearconv_embedded_lean(...);
}
```

The sixth step is to link CMSIS C sources only into the compile artifacts that actually need them. For an exact old-style replica, that at least means the generated static library, generated model executable, generated tests, benchmarks, and any ARM-targeted unit tests that execute QLinearConv. The current `feature` build already centralizes target and CPU selection through `-Dtarget` and `-Dcpu`, so those same artifact targets can be reused. A typical target build command remains aligned with the current CLI: `zig build lib -Dmodel=<model> -Dtarget=thumb-freestanding -Dcpu=cortex_m7`; the replica branch would simply add the restored CMSIS switch to that flow. fileciteturn16file0L3-L3 fileciteturn38file0L3-L3 fileciteturn40file0L3-L3

The seventh step is validation. Reuse the old one-op QLinearConv generation workflow and embedded smoke tests as a regression harness, but do **not** carry forward the old manual instruction that required editing code to switch wrapper variants. The new replica branch should make that choice internally and deterministically. The existing tensor utility layer in `feature` already re-exports NCHW/NHWC conversion helpers, so if you prefer not to keep the old hand-written permutation loops, you can refactor the wrapper to reuse those current helpers instead. fileciteturn40file0L3-L3 fileciteturn50file0L3-L3

## Major improvements without large refactors

The first high-value improvement is to make the compile flags **CPU-aware** instead of unconditional. The older branch always passed `-DOPTIONAL_RESTRICT_KEYWORD=__restrict`, but ARM’s current CMSIS-NN guidance says that this is generally recommended for Cortex-M7, while Cortex-M4 and Cortex-M33 often do not benefit in the same way. The same guidance says that `CMSIS_NN_USE_REQUANTIZE_INLINE_ASSEMBLY` is typically faster on Cortex-M4 but slower on other cores, and that `CMSIS_NN_USE_SINGLE_ROUNDING` changes numeric behavior. So the replica branch should keep the old baseline flags for strict reproduction, but immediately upgrade them into a per-CPU policy instead of a one-size-fits-all list. fileciteturn9file0L3-L3 citeturn4view0turn10view0turn10view1turn10view2

The second high-value improvement is to **narrow CMSIS linkage to actual ARM runtime artifacts**. The old branch linked CMSIS support into code-generation and parsing executables largely for configuration symmetry, but CMSIS-NN’s own documentation says host compilation is not supported out of the box. That makes the old “link everything” pattern a maintenance burden rather than a real requirement. A better immediate design is: keep `enable_cmsis` visible everywhere that needs the compile-time symbol, but compile and link CMSIS C sources only into artifacts that are both ARM-targeted and actually execute CMSIS kernels. fileciteturn14file0L3-L3 fileciteturn16file0L3-L3 citeturn4view0

The third high-value improvement is to eliminate the old manual layout switch entirely. The earlier workflow still documented a hand edit that swapped wrapper entry points depending on whether transpose handling was needed. The `feature` branch already has the right abstraction to remove that footgun: one dispatch function, one backend decision point, and existing tensor layout helpers. The replica branch should therefore expose a single CMSIS QLinearConv backend that accepts the current Z-Ant tensor ABI and internally performs the necessary NCHW→NHWC and NHWC→NCHW transformations when CMSIS is selected. fileciteturn40file0L3-L3 fileciteturn37file0L3-L3 fileciteturn50file0L3-L3

The fourth high-value improvement is to stop freezing the fragile hand-written CMSIS source list forever. For a first replica, keeping the old exact list is reasonable because it minimizes risk. But upstream CMSIS-NN builds its convolution library by taking the whole `ConvolutionFunctions` directory, and the library itself is maintained as a coherent source tree with its own build logic. The moment the replica branch is stable, the Zig side should move toward upstream-aligned source discovery or a dedicated static library target, because that reduces the chance that a future CMSIS wrapper change silently introduces a missing dependency. fileciteturn9file0L3-L3 citeturn13view0turn16view0

The fifth high-value improvement is reproducibility. The old fetch scripts defaulted to floating refs such as `main` or `develop`. That is enough for a prototype, but not for a long-lived accelerator backend. The replica branch should pin CMSIS-NN, CMSIS_5, and CMSIS-DSP to explicit commits or tags, then surface those pins in documentation and CI. That is especially important here because the port is based on feature-branch code plus an older integration branch plus a live upstream CMSIS tree. fileciteturn55file0L3-L3 fileciteturn53file0L3-L3 fileciteturn54file0L3-L3

## Major refactoring opportunities

The cleanest longer-term refactor is to create a dedicated accelerator package, rather than leaving CMSIS-NN logic buried inside the QLinearConv operator folder. Right now the natural quick port target is `op_qlinearconv/`. That is correct for the replica branch. But once the replica works, a better architecture is something like `src/codegen/IR_zant/accelerators/cmsis_nn/`, with shared code for tensor layout conversion, quantization parameter conversion, scratch-buffer handling, and backend gating. That would let future CMSIS-backed operators—such as pooling or fully connected layers—reuse the same integration surface instead of reimplementing the same bridge logic multiple times. The current `feature` branch already hints at this need by centralizing math exports and by re-exporting layout helpers at the tensor level. fileciteturn44file0L3-L3 fileciteturn50file0L3-L3

A second major refactor is to build CMSIS-NN as its own static library target inside Zig and then link that target where needed, instead of splicing raw C files into each runtime artifact. Upstream CMSIS-NN’s own CMake builds a single `cmsis-nn` static library, applies optimization at the target level, exposes the public `Include` directory, and then adds the source subtree beneath it. Mirroring that structure inside Z-Ant would reduce duplication, centralize compile flags, and make it much easier to broaden support beyond QLinearConv. citeturn16view0turn13view0

A third major refactor is to decide whether Z-Ant wants **runtime layout conversion** or **graph/codegen-time layout canonicalization** for accelerator paths. The replica branch should absolutely keep runtime conversion, because it is the least invasive way to get feature-branch CMSIS support working. But a stronger long-term design would normalize selected subgraphs or emitted kernels into the memory layout that a backend expects. In that world, the CMSIS backend could become much closer to zero-copy for already-quantized NNHWC-friendly graphs, and the wrapper would shrink into a pure ABI adapter rather than also acting as a tensor-layout transformer. The current tensor module already exposes NCHW↔NHWC conversion helpers, which means the abstraction boundary exists; it just has not been elevated into a graph-level decision yet. fileciteturn50file0L3-L3 fileciteturn32file0L3-L3

A fourth major refactor is to split **host-side planning** from **target-side kernel execution**. CMSIS-NN exposes host-intended buffer-size helpers such as `arm_convolve_wrapper_s8_get_buffer_size_dsp` and `arm_depthwise_conv_wrapper_s8_get_buffer_size_dsp/mve`, and upstream also now documents optional Python bindings that expose those helpers. That opens the door to a future design where codegen or planning tools compute workspace requirements on the host without attempting to build or run the full ARM-target kernel path in host executables. citeturn7view0turn19view1turn4view0

## Minor improvements

The first minor improvement is interface polish. The restored flag should ideally accept both `-Denable_CMSIS` and `-Denable_cmsis` for backward compatibility, but the documentation should standardize on one spelling internally and externally. The current `feature` documentation lists many build flags but no CMSIS switch, so `docs/BUILD_FLAGS.md` must be updated the moment the replica branch lands. fileciteturn56file0L3-L3 fileciteturn38file0L3-L3

The second minor improvement is test coverage. The replica branch should add a tight regression matrix around QLinearConv: standard convolution, depthwise, grouped convolution, `u8` activations, `i8` activations, and at least one shape/layout test that explicitly verifies the NCHW↔NHWC bridge. The old integration work already had one-op workflows and embedded flashing notes that can be reused as reference material for building those tests. fileciteturn40file0L3-L3

The third minor improvement is documentation cleanup. The old docs are useful historical notes, but they still reflect manual code edits, board-specific shape hand-editing, and branch-era structure names. Those documents should be rewritten so that the new replica branch describes a **single** supported path: enable the flag, vendor the dependencies, target an ARM Cortex-M CPU, and let dispatch select the CMSIS path automatically. fileciteturn40file0L3-L3

The fourth minor improvement is CI. At minimum, add a non-host cross-build smoke job for one QLinearConv model with `-Denable_CMSIS` and an ARM target such as `cortex_m7`. That is the fastest way to catch missing include paths, drifting source lists, and conditional-flag regressions. The current feature branch already exposes `-Dtarget` and `-Dcpu`, so CI can use the existing CLI surface. fileciteturn38file0L3-L3 fileciteturn16file0L3-L3

## Important implementation notes and current gaps

For the CMSIS-NN convolution path itself, there are several **non-negotiable runtime formalisms**. CMSIS wrapper APIs operate on signed quantized activations; the s8 wrapper expects NHWC activations and `[C_OUT, H, W, C_IN]` filters, while the depthwise wrapper expects `[1, H, W, C_OUT]` filters. The runtime must also provide per-channel multiplier and shift arrays, and it must allocate the scratch buffer size returned by the matching wrapper getter. That is why the old wrapper’s conversion, packing, and buffer-size logic is worth preserving instead of rewriting from scratch during the initial port. citeturn7view0turn19view0turn19view1 fileciteturn10file0L3-L3 fileciteturn11file0L3-L3

On the compiler-flag side, the baseline replica should carry forward the old branch’s effective essentials: compile the CMSIS C units at a high optimization level, keep builtins available, and target a real Cortex-M CPU. CMSIS-NN’s current documentation says the default optimization is `-Ofast`, warns against `-fno-builtin`, and also warns that `-ffreestanding` implicitly enables `-fno-builtin`. Since Z-Ant’s embedded build examples currently use `thumb-freestanding`, the old branch’s explicit `-fbuiltin` on CMSIS translation units is a sensible local correction and should remain part of the replica baseline. fileciteturn9file0L3-L3 fileciteturn38file0L3-L3 citeturn4view0turn16view0

It is also important to separate **mandatory** from **conditional** flags. `ARM_MATH_DSP` and `ARM_MATH_MVEI` are not normally flags that you should hardcode; CMSIS documentation describes them as feature-flag macros derived from the chosen processor or architecture, and gives a Cortex-M4 `-mcpu` example where `ARM_MATH_DSP` is enabled automatically. By contrast, `ARM_MATH_AUTOVECTORIZE` is user-set and only relevant when MVE is active, particularly at `-O0`. `OPTIONAL_RESTRICT_KEYWORD=__restrict` is a performance tuning option, especially relevant to Cortex‑M7. `CMSIS_NN_USE_REQUANTIZE_INLINE_ASSEMBLY` is a conditional optimization that tends to help Cortex‑M4 more than Cortex‑M7. `CMSIS_NN_USE_SINGLE_ROUNDING` is correctness-sensitive because it changes the requantization rule. citeturn4view1turn4view0turn10view0turn10view1turn10view2turn10view3

The current `feature` branch is missing **all** of the CMSIS integration essentials: there is no current CMSIS flag in `ZantOptions`, no `enable_cmsis` in `build_step_option`, no CMSIS build helper, no CMSIS header visibility on `IR_zant_mod`, and the current `qlinearconv_dispatch` still routes directly to the embedded fallback. So if the question is whether the needed flags and hooks are already present in `feature`, the answer is no: the abstraction point is present, but the actual CMSIS plumbing is not. fileciteturn18file0L3-L3 fileciteturn19file0L3-L3 fileciteturn20file0L3-L3 fileciteturn37file0L3-L3

The main things that are not up to date with current CMSIS practice are also clear. The older branch’s hard-coded `targetIsCortex` gate is stale and should be removed. Its manual source list is serviceable for an initial replica, but not ideal for a maintained backend because upstream treats CMSIS-NN as a coherent source-tree library. Its unconditional restrict macro should become CPU-sensitive. Its tendency to link CMSIS into host tools is at odds with upstream’s explicit “host not supported out of the box” note. Those are the first things that should be corrected after the replica branch proves the port. fileciteturn13file0L3-L3 fileciteturn9file0L3-L3 citeturn16view0turn4view0

The most precise short conclusion is this: the **smallest correct port** for the `feature` branch is to restore the old build-option plumbing, add CMSIS header/source linkage back into the new build architecture, transplant the old CMSIS QLinearConv wrapper into the current operator folder, and make `qlinearconv_dispatch` call an adapted **NCHW-bridge** CMSIS backend when `enable_cmsis` is on. That reproduces the old work in the new architecture with the least churn, while leaving the feature-branch front-end and fallback kernels intact. fileciteturn45file0L3-L3 fileciteturn32file0L3-L3 fileciteturn10file0L3-L3 fileciteturn11file0L3-L3