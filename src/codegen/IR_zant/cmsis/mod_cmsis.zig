pub const layout = @import("layout.zig");
pub const quant = @import("quant.zig");

const zant_utils = @import("zant_utils");

pub fn cmsisUsed() bool {
    const build_options = zant_utils.build_options;
    return comptime (cmsisForced() or
        (@hasDecl(build_options, "enable_cmsis") and
            build_options.enable_cmsis and
            @hasDecl(build_options, "target_is_cortex_m") and
            build_options.target_is_cortex_m));
}

pub fn cmsisForced() bool {
    const build_options = zant_utils.build_options;
    return comptime (@hasDecl(build_options, "force_cmsis") and build_options.force_cmsis);
}
