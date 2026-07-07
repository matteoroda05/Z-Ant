pub const layout = @import("layout.zig");
pub const quant = @import("quant.zig");
pub const prepare = @import("prepare.zig");

const zant_utils = @import("zant_utils");

/// Returns whether the current CMSIS-NN integration can accelerate this node.
///
/// This is the single gate the code generator consults. It dispatches on the
/// operator type and delegates the per-node eligibility to the operator-specific
/// checker in `prepare.zig`. Today only QLinearConv can return `true`.
///
/// `node` is taken as `anytype` (rather than `*const NodeZant`) so this file does
/// not import the node/op-union modules that would form an import cycle.
pub fn isCmsisSupported(node: anytype) bool {
    return switch (node.op) {
        .qlinearconv => |*q| prepare.qlinearconv_isSupported(q),
        else => false,
    };
}

pub fn cmsisUsed() bool {
    const build_options = zant_utils.build_options;
    return comptime (@hasDecl(build_options, "enable_cmsis") and
        build_options.enable_cmsis and
        @hasDecl(build_options, "target_is_cortex_m") and
        build_options.target_is_cortex_m);
}
