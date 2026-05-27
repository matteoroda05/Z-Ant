const std = @import("std");

const testing = @import("testing_flags.zig");
const codegen = @import("codegen_flags.zig");
const cmsis = @import("cmsis_flags.zig");

pub const ZantOptions = struct {
    testing_flags: testing.Testing_flags,
    codegen_flags: codegen.Codegen_flags,
    cmsis_flags: cmsis.Cmsis_flags,

    pub fn init(b: *std.Build) !ZantOptions {
        return ZantOptions{
            .testing_flags = try testing.Testing_flags.init(b),
            .codegen_flags = try codegen.Codegen_flags.init(b),
            .cmsis_flags = try cmsis.Cmsis_flags.init(b),
        };
    }
};
