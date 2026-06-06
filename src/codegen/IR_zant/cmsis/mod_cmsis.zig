pub const layout = @import("layout.zig");
pub const quant = @import("quant.zig");

pub fn cmsisUsed(comptime build_options: type) bool {
    return comptime (cmsisForced(build_options) or
        (@hasDecl(build_options, "enable_cmsis") and
            build_options.enable_cmsis and
            @hasDecl(build_options, "target_is_cortex_m") and
            build_options.target_is_cortex_m));
}

pub fn cmsisForced(comptime build_options: type) bool {
    return comptime (@hasDecl(build_options, "force_cmsis") and build_options.force_cmsis);
}
