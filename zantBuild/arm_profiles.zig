const std = @import("std");

/// Public Cortex-M targets supported by Z-Ant's Arm build layer.
pub const ArmProfileId = enum {
    cortex_m7_fpv5_d16_softfp,
    cortex_m4_fpv4_sp_d16_softfp,
};

/// The complete target and GNU multilib selection for one Cortex-M profile.
pub const ArmProfile = struct {
    id: ArmProfileId,
    zig_target: []const u8,
    zig_cpu_features: []const u8,
    gnu_flags: []const []const u8,

    /// Builds the exact Zig target query required by this profile.
    pub fn targetQuery(self: ArmProfile) !std.Target.Query {
        return std.Target.Query.parse(.{
            .arch_os_abi = self.zig_target,
            .cpu_features = self.zig_cpu_features,
        });
    }
};

const cortex_m7_fpv5_d16_softfp = ArmProfile{
    .id = .cortex_m7_fpv5_d16_softfp,
    .zig_target = "thumb-freestanding-eabi",
    .zig_cpu_features = "cortex_m7+fp_armv8d16",
    .gnu_flags = &.{
        "-mcpu=cortex-m7",
        "-mfpu=fpv5-d16",
        "-mfloat-abi=softfp",
        "-mthumb",
    },
};

const cortex_m4_fpv4_sp_d16_softfp = ArmProfile{
    .id = .cortex_m4_fpv4_sp_d16_softfp,
    .zig_target = "thumb-freestanding-eabi",
    .zig_cpu_features = "cortex_m4+vfp4d16sp",
    .gnu_flags = &.{
        "-mcpu=cortex-m4",
        "-mfpu=fpv4-sp-d16",
        "-mfloat-abi=softfp",
        "-mthumb",
    },
};

/// Returns the immutable metadata for a public Arm profile.
pub fn lookup(id: ArmProfileId) ArmProfile {
    return switch (id) {
        .cortex_m7_fpv5_d16_softfp => cortex_m7_fpv5_d16_softfp,
        .cortex_m4_fpv4_sp_d16_softfp => cortex_m4_fpv4_sp_d16_softfp,
    };
}

test "Cortex-M7 profile has the exact Zig and GNU mapping" {
    const profile = lookup(.cortex_m7_fpv5_d16_softfp);

    try std.testing.expectEqualStrings("thumb-freestanding-eabi", profile.zig_target);
    try std.testing.expectEqualStrings("cortex_m7+fp_armv8d16", profile.zig_cpu_features);
    try std.testing.expectEqualSlices([]const u8, &.{
        "-mcpu=cortex-m7",
        "-mfpu=fpv5-d16",
        "-mfloat-abi=softfp",
        "-mthumb",
    }, profile.gnu_flags);
    _ = try profile.targetQuery();
}

test "Cortex-M4 profile has the exact Zig and GNU mapping" {
    const profile = lookup(.cortex_m4_fpv4_sp_d16_softfp);

    try std.testing.expectEqualStrings("thumb-freestanding-eabi", profile.zig_target);
    try std.testing.expectEqualStrings("cortex_m4+vfp4d16sp", profile.zig_cpu_features);
    try std.testing.expectEqualSlices([]const u8, &.{
        "-mcpu=cortex-m4",
        "-mfpu=fpv4-sp-d16",
        "-mfloat-abi=softfp",
        "-mthumb",
    }, profile.gnu_flags);
    _ = try profile.targetQuery();
}
