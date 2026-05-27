const std = @import("std");

pub const Cmsis_flags = struct {
    enable_cmsis: bool,

    pub fn init(b: *std.Build) !Cmsis_flags {
        return Cmsis_flags{
            .enable_cmsis = b.option(bool, "enable_CMSIS", "Enable CMSIS-NN backend support") orelse false,
        };
    }
};
