const std = @import("std");

pub const Cmsis_flags = struct {
    enable_cmsis: bool,
    force_cmsis: bool,
    target_is_cortex_m: bool,

    pub fn init(b: *std.Build) !Cmsis_flags {
        const enable_cmsis = b.option(bool, "enable_CMSIS", "Enable CMSIS-NN backend support") orelse false;
        const force_cmsis = b.option(bool, "force_CMSIS", "Force CMSIS-NN backend support") orelse false;
        const cpu = readCpuOption(b);
        const target_is_cortex_m = cpuIsCortexM(cpu);

        return Cmsis_flags{
            .enable_cmsis = enable_cmsis,
            .force_cmsis = force_cmsis,
            .target_is_cortex_m = target_is_cortex_m,
        };
    }
};

fn readCpuOption(b: *std.Build) []const u8 {
    const option = b.user_input_options.get("cpu") orelse return "";
    return switch (option.value) {
        .scalar => |cpu| cpu,
        else => "",
    };
}

fn cpuIsCortexM(cpu: []const u8) bool {
    return startsWithIgnoreCase(cpu, "cortex_m") or
        startsWithIgnoreCase(cpu, "cortex-m") or
        startsWithIgnoreCase(cpu, "cortexm");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;

    for (prefix, 0..) |prefix_char, index| {
        const value_char = value[index];
        if (value_char != prefix_char and value_char != toUpperAscii(prefix_char)) return false;
    }

    return true;
}

fn toUpperAscii(value: u8) u8 {
    if (value >= 'a' and value <= 'z') {
        return value - ('a' - 'A');
    }

    return value;
}
