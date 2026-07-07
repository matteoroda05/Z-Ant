//! Code-generation-time CMSIS-NN preparation for QLinearConv.
//!
//! This file is **host-safe**: it never imports the CMSIS vendor headers
//! (`@cImport("arm_nnfunctions.h")`), so it can run inside the lib-gen tool on a
//! normal host where no CMSIS sources exist. It computes the static constants a
//! prepared QLinearConv node needs (OHWI `i8` filter, `i32` bias, per-channel
//! requant multiplier/shift arrays) by reusing the existing numeric primitives
//! in `layout.zig` / `quant.zig`. The parameters writer emits the results into
//! `static_parameters.zig`; the runtime bridge then only does the input/output
//! layout transposes and the CMSIS call.
//!
//! For now this file holds only `qlinearconv_*` functions. Additional CMSIS-
//! supported operators would add their own `<op>_*` functions here later.

const std = @import("std");
const IR_zant = @import("IR_zant");

const QLinearConv = @import("../op_union/operators/op_qlinearconv/op_qlinearconv.zig").QLinearConv;
const Tensor = IR_zant.core.tensor.Tensor;
const TensorCategory = IR_zant.TensorCategory;
const TensorType = IR_zant.tensorZant_lib.TensorType;
const TensorZant = IR_zant.TensorZant;
const utils = IR_zant.utils;

// Import the sibling primitives directly (not via `IR_zant.cmsis`) so this file
// does not import the very package module that imports it.
const cmsis_layout = @import("layout.zig");
const cmsis_quant = @import("quant.zig");

/// Owns the precomputed CMSIS-NN constants for one QLinearConv node.
pub const Prepared = struct {
    filter_s8: []i8,
    filter_shape: [4]usize,
    bias_i32: []i32,
    multipliers: []i32,
    shifts: []i32,

    pub fn deinit(self: *Prepared, alloc: *const std.mem.Allocator) void {
        alloc.free(self.filter_s8);
        alloc.free(self.bias_i32);
        alloc.free(self.multipliers);
        alloc.free(self.shifts);
    }
};

/// Returns whether the current CMSIS-NN integration can prepare this specific
/// QLinearConv node today. Anything this rejects falls back to the normal path.
///
/// When CMSIS gains wider support (e.g. `group > 1`), relax the checks here.
pub fn qlinearconv_isSupported(op: *const QLinearConv) bool {
    if (!isActivationType(op.input_x.ty) or !isActivationType(op.output_y.ty)) return false;
    if (!isWeightType(op.input_w.ty)) return false;
    if (op.auto_pad.len != 0 and !std.mem.eql(u8, op.auto_pad, "NOTSET")) return false;
    if (op.group != 1) return false;

    if (!isInitializerWithData(op.input_w)) return false;
    if (op.input_w.shape.len != 4) return false;
    for (op.input_w.shape) |dimension| {
        if (dimension == 0) return false;
    }
    const out_channels = op.input_w.shape[0];

    if (!scaleInitializerOk(op.input_x_scale, false)) return false;
    if (!scaleInitializerOk(op.input_w_scale, false)) return false;
    if (!scaleInitializerOk(op.input_y_scale, true)) return false;

    if (!isInitializerWithData(op.input_w_zero_point)) return false;
    if (!isSupportedZeroPointType(op.input_w_zero_point.ty)) return false;

    if (op.input_B) |bias| {
        if (bias.name.len != 0) {
            if (!isInitializerWithData(bias)) return false;
            if (bias.ty != .i32) return false;
            const data = bias.ptr.?.get_data_as(i32);
            if (data.len != 1 and data.len < out_channels) return false;
        }
    }

    return true;
}

/// Precomputes the CMSIS-NN constants for a preparable QLinearConv node.
///
/// Caller owns the returned `Prepared` and must `deinit` it. Only call for nodes
/// where `qlinearconv_isSupported` returned `true`.
pub fn qlinearconv_prepare(alloc: *const std.mem.Allocator, op: *const QLinearConv) !Prepared {
    return switch (op.input_w.ty) {
        .u8 => prepareTyped(u8, alloc, op),
        .i8 => prepareTyped(i8, alloc, op),
        else => error.UnsupportedWeightType,
    };
}

fn prepareTyped(comptime WeightType: type, alloc: *const std.mem.Allocator, op: *const QLinearConv) !Prepared {
    const out_channels = op.input_w.shape[0];

    // View the raw OIHW weights, reorder into CMSIS OHWI layout (element move
    // only — group is 1 for preparable nodes).
    var weight_view = Tensor(WeightType).fromConstBuffer(
        alloc,
        op.input_w.ptr.?.get_data_as(WeightType),
        op.input_w.shape,
    );

    var filters_layout = try cmsis_layout.oihwToCmsisFilterLayout(WeightType, alloc, &weight_view, 1);
    defer filters_layout.deinit();

    const filter_shape = [4]usize{
        filters_layout.shape[0],
        filters_layout.shape[1],
        filters_layout.shape[2],
        filters_layout.shape[3],
    };

    // Subtract the (name-coerced) weight zero-point and clamp to i8, exactly as
    // the reference/embedded path would read it from the generated tensor.
    const w_zero_point = try coerceWeightZeroPointI32(alloc, op.input_w_zero_point);
    defer alloc.free(w_zero_point);

    var packed_filter = try cmsis_quant.prepareFilterS8(WeightType, alloc, &filters_layout, w_zero_point, out_channels);
    errdefer packed_filter.deinit();

    var bias_view_storage: Tensor(i32) = undefined;
    var bias_view: ?*const Tensor(i32) = null;
    if (op.input_B) |bias| {
        if (bias.name.len != 0) {
            bias_view_storage = Tensor(i32).fromConstBuffer(alloc, bias.ptr.?.get_data_as(i32), bias.shape);
            bias_view = &bias_view_storage;
        }
    }

    var prepared_bias = try cmsis_quant.prepareBiasI32(i32, alloc, bias_view, out_channels);
    errdefer prepared_bias.deinit();

    var requant = try cmsis_quant.makePerChannelRequantParams(
        alloc,
        op.input_x_scale.ptr.?.get_data_as(f32),
        op.input_w_scale.ptr.?.get_data_as(f32),
        op.input_y_scale.ptr.?.get_data_as(f32),
        out_channels,
    );
    errdefer requant.deinit();

    // Steal the owned buffers into the result (errdefers above only fire on the
    // error paths before this point).
    return .{
        .filter_s8 = packed_filter.data,
        .filter_shape = filter_shape,
        .bias_i32 = prepared_bias.data,
        .multipliers = requant.multipliers,
        .shifts = requant.shifts,
    };
}

/// Reproduces the name-keyed zero-point coercion that `parameters.zig` applies
/// when it emits zero-point tensors, so the prepared filter matches byte-for-byte
/// what the reference path would compute from the generated weight zero-point.
///
/// Weight zero-points (name contains `zero_point` and `const_fold_opt`) are
/// stored as `i8`; other zero-points are stored as `u8`.
fn coerceWeightZeroPointI32(alloc: *const std.mem.Allocator, tz: *const TensorZant) ![]i32 {
    const name = try tz.getNameSanitized();
    const is_zero_point = std.mem.indexOf(u8, name, "zero_point") != null;
    const is_weight_zero_point = is_zero_point and std.mem.indexOf(u8, name, "const_fold_opt") != null;

    if (is_weight_zero_point) {
        return switch (tz.ty) {
            .i32 => blk: {
                const src = tz.ptr.?.get_data_as(i32);
                const out = try alloc.alloc(i32, src.len);
                for (src, 0..) |v, i| out[i] = @max(-128, @min(127, v));
                break :blk out;
            },
            .i8 => blk: {
                const src = tz.ptr.?.get_data_as(i8);
                const out = try alloc.alloc(i32, src.len);
                for (src, 0..) |v, i| out[i] = @as(i32, v);
                break :blk out;
            },
            else => error.UnsupportedWeightZeroPointType,
        };
    } else if (is_zero_point) {
        return switch (tz.ty) {
            .i32 => blk: {
                const src = tz.ptr.?.get_data_as(i32);
                const out = try alloc.alloc(i32, src.len);
                for (src, 0..) |v, i| out[i] = @max(0, @min(255, v));
                break :blk out;
            },
            .i8 => blk: {
                const src = tz.ptr.?.get_data_as(i8);
                const out = try alloc.alloc(i32, src.len);
                for (src, 0..) |v, i| out[i] = @max(0, @min(255, @as(i32, v) + 128));
                break :blk out;
            },
            .u8 => blk: {
                const src = tz.ptr.?.get_data_as(u8);
                const out = try alloc.alloc(i32, src.len);
                for (src, 0..) |v, i| out[i] = @as(i32, v);
                break :blk out;
            },
            else => error.UnsupportedInputZeroPointType,
        };
    }

    // Not a zero-point tensor by name — widen the supported native types as-is.
    return switch (tz.ty) {
        .i32 => blk: {
            const src = tz.ptr.?.get_data_as(i32);
            const out = try alloc.alloc(i32, src.len);
            @memcpy(out, src);
            break :blk out;
        },
        .i8 => blk: {
            const src = tz.ptr.?.get_data_as(i8);
            const out = try alloc.alloc(i32, src.len);
            for (src, 0..) |v, i| out[i] = @as(i32, v);
            break :blk out;
        },
        .u8 => blk: {
            const src = tz.ptr.?.get_data_as(u8);
            const out = try alloc.alloc(i32, src.len);
            for (src, 0..) |v, i| out[i] = @as(i32, v);
            break :blk out;
        },
        else => error.UnsupportedWeightZeroPointType,
    };
}

fn isActivationType(ty: TensorType) bool {
    return ty == .u8 or ty == .i8;
}

fn isWeightType(ty: TensorType) bool {
    return ty == .u8 or ty == .i8;
}

fn isSupportedZeroPointType(ty: TensorType) bool {
    return ty == .i8 or ty == .u8 or ty == .i32;
}

fn isInitializerWithData(tz: *const TensorZant) bool {
    return tz.tc == TensorCategory.INITIALIZER and tz.ptr != null;
}

fn scaleInitializerOk(tz: *const TensorZant, comptime reject_zero: bool) bool {
    if (!isInitializerWithData(tz)) return false;
    if (tz.ty != .f32) return false;
    const data = tz.ptr.?.get_data_as(f32);
    if (data.len == 0) return false;
    if (reject_zero and data[0] == 0.0) return false;
    return true;
}
