const build_options = @import("build_options");

// TODO: Replace this temporary assumption with real target/CPU detection.
// This intentionally reproduces the old feat/CMSIS-integration behavior.
const targetIsCortex: bool = true;

pub fn cmsisUsed() bool {
    return comptime (
        @hasDecl(build_options, "enable_cmsis") and
        build_options.enable_cmsis and
        targetIsCortex
    );
}
