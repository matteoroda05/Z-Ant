const std = @import("std");
const IR_zant = @import("IR_zant");

const Tensor = IR_zant.core.tensor.Tensor;

/// Owns the per-output-channel CMSIS requantization arrays.
///
/// `multipliers` and `shifts` are passed directly to
/// `cmsis_nn_per_channel_quant_params`.
pub const RequantParams = struct {
    allocator: *const std.mem.Allocator,
    multipliers: []i32,
    shifts: []i32,

    /// Releases the multiplier and shift arrays allocated by
    /// `makePerChannelRequantParams`.
    pub fn deinit(self: *RequantParams) void {
        self.allocator.free(self.multipliers);
        self.allocator.free(self.shifts);
    }
};

/// Stores the signed activation offsets and clamp range expected by CMSIS-NN.
pub const ActivationOffsets = struct {
    input_offset: i32,
    output_offset: i32,
    activation_min: i32,
    activation_max: i32,
};

/// Owns CMSIS-compatible `i32` bias storage.
pub const PreparedBias = struct {
    allocator: *const std.mem.Allocator,
    data: []i32,

    /// Releases the prepared bias array allocated by `prepareBiasI32`.
    pub fn deinit(self: *PreparedBias) void {
        self.allocator.free(self.data);
    }
};

/// Owns a signed `i8` filter buffer after zero-point adjustment and clamping.
pub const PackedFilter = struct {
    allocator: *const std.mem.Allocator,
    data: []i8,

    /// Releases the packed filter buffer allocated by `prepareFilterS8`.
    pub fn deinit(self: *PackedFilter) void {
        self.allocator.free(self.data);
    }
};

/// Owns an activation tensor converted into the signed `i8` CMSIS domain.
pub const PreparedActivation = struct {
    tensor: Tensor(i8),

    /// Releases the prepared activation tensor allocated by
    /// `prepareActivationS8`.
    pub fn deinit(self: *PreparedActivation) void {
        self.tensor.deinit();
    }
};

/// Builds per-output-channel CMSIS requantization parameters.
///
/// For every output channel, this computes the effective scale
/// `(x_scale * w_scale[channel]) / y_scale` and converts it into the
/// multiplier/shift representation consumed by CMSIS-NN convolution wrappers.
/// `w_scale` may be scalar or per-output-channel.
pub fn makePerChannelRequantParams(
    allocator: *const std.mem.Allocator,
    x_scale: anytype,
    w_scale: anytype,
    y_scale: anytype,
    out_channels: usize,
) !RequantParams {
    if (out_channels == 0) return error.InvalidQuantizationShape;

    const x_scale_value = try readScaleAt(x_scale, 0);
    const y_scale_value = try readScaleAt(y_scale, 0);
    if (y_scale_value == 0.0) return error.InvalidQuantizationScale;

    const multipliers = try allocator.alloc(i32, out_channels);
    errdefer allocator.free(multipliers);
    const shifts = try allocator.alloc(i32, out_channels);
    errdefer allocator.free(shifts);

    const w_scale_len = scaleLen(w_scale);
    for (0..out_channels) |channel| {
        const w_index = if (w_scale_len == out_channels) channel else 0;
        const w_scale_value = try readScaleAt(w_scale, w_index);
        const scale = (x_scale_value * w_scale_value) / y_scale_value;
        quantizeMultiplier(scale, &multipliers[channel], &shifts[channel]);
    }

    return .{
        .allocator = allocator,
        .multipliers = multipliers,
        .shifts = shifts,
    };
}

/// Converts QLinearConv activation zero-points into CMSIS signed-offset fields.
///
/// ONNX-style `u8` activations are shifted into the signed `s8` domain by
/// subtracting 128. Native `i8` activations keep their zero-point unchanged.
pub fn makeActivationOffsets(comptime InputType: type, x_zero_point: anytype, y_zero_point: anytype) ActivationOffsets {
    const input_zero_point = zeroPointToS8(InputType, readScalarZP(x_zero_point));
    const output_zero_point = zeroPointToS8(InputType, readScalarZP(y_zero_point));

    return .{
        .input_offset = -input_zero_point,
        .output_offset = output_zero_point,
        .activation_min = std.math.minInt(i8),
        .activation_max = std.math.maxInt(i8),
    };
}

/// Prepares a CMSIS-compatible `i32` bias array for all output channels.
///
/// If the QLinearConv node has no bias tensor, this creates a zero-filled bias
/// buffer. Scalar bias tensors are broadcast; per-channel tensors are copied
/// channel by channel.
pub fn prepareBiasI32(
    comptime BiasType: type,
    allocator: *const std.mem.Allocator,
    bias: ?*const Tensor(BiasType),
    out_channels: usize,
) !PreparedBias {
    if (out_channels == 0) return error.InvalidQuantizationShape;

    const data = try allocator.alloc(i32, out_channels);
    errdefer allocator.free(data);

    if (bias) |bias_tensor| {
        if (bias_tensor.data.len != 1 and bias_tensor.data.len < out_channels) {
            return error.InvalidBiasShape;
        }

        for (0..out_channels) |channel| {
            const bias_index = if (bias_tensor.data.len == 1) 0 else channel;
            data[channel] = numberToI32(BiasType, bias_tensor.data[bias_index]);
        }
    } else {
        @memset(data, 0);
    }

    return .{ .allocator = allocator, .data = data };
}

/// Packs already layout-reordered filters into the signed `i8` domain expected
/// by CMSIS-NN.
///
/// The helper subtracts scalar or per-output-channel weight zero-points from
/// each filter value and clamps the result to `i8`.
pub fn prepareFilterS8(
    comptime WeightType: type,
    allocator: *const std.mem.Allocator,
    filters_cmsis_layout: *const Tensor(WeightType),
    w_zero_point: anytype,
    out_channels: usize,
) !PackedFilter {
    if (filters_cmsis_layout.shape.len != 4) return error.InvalidShape;
    if (filters_cmsis_layout.shape[0] != out_channels) return error.ShapeMismatch;

    const data = try allocator.alloc(i8, filters_cmsis_layout.data.len);
    errdefer allocator.free(data);

    const channel_stride = filters_cmsis_layout.shape[1] * filters_cmsis_layout.shape[2] * filters_cmsis_layout.shape[3];
    for (filters_cmsis_layout.data, 0..) |value, index| {
        const channel = index / channel_stride;
        const zero_point = readPerChannelZP(w_zero_point, channel);
        const centered = numberToI32(WeightType, value) - zero_point;
        data[index] = clampToI8(centered);
    }

    return .{ .allocator = allocator, .data = data };
}

/// Converts an NHWC activation tensor into signed `i8` storage for CMSIS-NN.
///
/// `i8` values are copied as-is. `u8` values are shifted by `-128` so the same
/// logical quantized activations are represented in CMSIS's signed domain.
pub fn prepareActivationS8(
    comptime InputType: type,
    allocator: *const std.mem.Allocator,
    input_nhwc: *const Tensor(InputType),
) !PreparedActivation {
    if (input_nhwc.shape.len != 4) return error.InvalidShape;

    var tensor = try Tensor(i8).fromShape(allocator, input_nhwc.shape);
    errdefer tensor.deinit();

    for (input_nhwc.data, 0..) |value, index| {
        tensor.data[index] = activationToS8(InputType, value);
    }

    return .{ .tensor = tensor };
}

/// Converts signed CMSIS NHWC output into the existing Z-Ant NCHW output tensor.
///
/// `i8` output values are copied as-is. `u8` output values are shifted back by
/// `+128` to restore the unsigned QLinearConv output domain.
pub fn writeS8NhwcOutputToNchw(comptime OutputType: type, output_nhwc: *const Tensor(i8), output_nchw: *Tensor(OutputType)) !void {
    if (output_nhwc.shape.len != 4 or output_nchw.shape.len != 4) return error.InvalidShape;

    const n_count = output_nchw.shape[0];
    const channels = output_nchw.shape[1];
    const height = output_nchw.shape[2];
    const width = output_nchw.shape[3];

    if (output_nhwc.shape[0] != n_count or output_nhwc.shape[1] != height or output_nhwc.shape[2] != width or output_nhwc.shape[3] != channels) {
        return error.ShapeMismatch;
    }
    if (output_nhwc.data.len != output_nchw.data.len) return error.ShapeMismatch;

    for (0..n_count) |n| {
        for (0..channels) |c| {
            for (0..height) |h| {
                for (0..width) |w| {
                    const nhwc_index = ((n * height + h) * width + w) * channels + c;
                    const nchw_index = ((n * channels + c) * height + h) * width + w;
                    output_nchw.data[nchw_index] = s8OutputToType(OutputType, output_nhwc.data[nhwc_index]);
                }
            }
        }
    }
}

/// Converts signed CMSIS NHWC output into an existing Z-Ant NHWC output tensor.
///
/// This preserves element order and only converts from CMSIS's signed `i8`
/// output domain back into the generated tensor's activation type.
pub fn writeS8NhwcOutputToNhwc(comptime OutputType: type, output_s8_nhwc: *const Tensor(i8), output_nhwc: *Tensor(OutputType)) !void {
    if (output_s8_nhwc.shape.len != 4 or output_nhwc.shape.len != 4) return error.InvalidShape;
    if (output_s8_nhwc.data.len != output_nhwc.data.len) return error.ShapeMismatch;

    for (output_s8_nhwc.shape, 0..) |dimension, index| {
        if (dimension != output_nhwc.shape[index]) return error.ShapeMismatch;
    }

    for (output_s8_nhwc.data, 0..) |value, index| {
        output_nhwc.data[index] = s8OutputToType(OutputType, value);
    }
}

/// Returns the length of a supported scalar, array, slice, vector, optional, or
/// tensor-like scale representation.
fn scaleLen(scale_any: anytype) usize {
    const ScaleType = @TypeOf(scale_any);
    const info = @typeInfo(ScaleType);

    return switch (info) {
        .pointer => switch (info.pointer.size) {
            .one => scaleLen(scale_any.*),
            .slice => scale_any.len,
            .many, .c => 0,
        },
        .optional => if (scale_any) |payload| scaleLen(payload) else 0,
        .array => info.array.len,
        .vector => info.vector.len,
        .@"struct" => if (@hasField(ScaleType, "data")) scale_any.data.len else 0,
        else => 1,
    };
}

/// Reads a scale value as `f32`, supporting scalar and tensor-like scale
/// representations used by generated QLinearConv calls.
fn readScaleAt(scale_any: anytype, index: usize) !f32 {
    const ScaleType = @TypeOf(scale_any);
    const info = @typeInfo(ScaleType);

    return switch (info) {
        .pointer => switch (info.pointer.size) {
            .one => readScaleAt(scale_any.*, index),
            .slice => blk: {
                if (scale_any.len == 0) break :blk error.InvalidQuantizationScale;
                const actual_index = if (scale_any.len == 1) 0 else index;
                if (actual_index >= scale_any.len) break :blk error.InvalidQuantizationShape;
                break :blk numberToF32(@TypeOf(scale_any[actual_index]), scale_any[actual_index]);
            },
            .many, .c => numberToF32(@TypeOf(scale_any[index]), scale_any[index]),
        },
        .optional => if (scale_any) |payload| readScaleAt(payload, index) else error.InvalidQuantizationScale,
        .array => blk: {
            if (info.array.len == 0) break :blk error.InvalidQuantizationScale;
            const actual_index = if (info.array.len == 1) 0 else index;
            if (actual_index >= info.array.len) break :blk error.InvalidQuantizationShape;
            break :blk numberToF32(@TypeOf(scale_any[actual_index]), scale_any[actual_index]);
        },
        .vector => blk: {
            if (info.vector.len == 0) break :blk error.InvalidQuantizationScale;
            const actual_index = if (info.vector.len == 1) 0 else index;
            if (actual_index >= info.vector.len) break :blk error.InvalidQuantizationShape;
            break :blk numberToF32(@TypeOf(scale_any[actual_index]), scale_any[actual_index]);
        },
        .@"struct" => if (@hasField(ScaleType, "data")) blk: {
            if (scale_any.data.len == 0) break :blk error.InvalidQuantizationScale;
            const actual_index = if (scale_any.data.len == 1) 0 else index;
            if (actual_index >= scale_any.data.len) break :blk error.InvalidQuantizationShape;
            break :blk numberToF32(@TypeOf(scale_any.data[actual_index]), scale_any.data[actual_index]);
        } else error.InvalidQuantizationScale,
        .float, .comptime_float, .int, .comptime_int => numberToF32(ScaleType, scale_any),
        else => error.InvalidQuantizationScale,
    };
}

/// Reads a scalar zero-point from the supported generated-code zero-point
/// representations. Missing or empty zero-point values default to zero.
fn readScalarZP(zp_any: anytype) i32 {
    const ZPType = @TypeOf(zp_any);
    const info = @typeInfo(ZPType);

    return switch (info) {
        .pointer => switch (info.pointer.size) {
            .one => readScalarZP(zp_any.*),
            .slice => if (zp_any.len == 0) 0 else numberToI32(@TypeOf(zp_any[0]), zp_any[0]),
            .many, .c => numberToI32(@TypeOf(zp_any[0]), zp_any[0]),
        },
        .optional => if (zp_any) |payload| readScalarZP(payload) else 0,
        .array => if (info.array.len == 0) 0 else numberToI32(@TypeOf(zp_any[0]), zp_any[0]),
        .vector => if (info.vector.len == 0) 0 else numberToI32(@TypeOf(zp_any[0]), zp_any[0]),
        .@"struct" => if (@hasField(ZPType, "data")) blk: {
            if (zp_any.data.len == 0) break :blk 0;
            break :blk numberToI32(@TypeOf(zp_any.data[0]), zp_any.data[0]);
        } else 0,
        .int, .comptime_int => numberToI32(ZPType, zp_any),
        else => 0,
    };
}

/// Reads a per-output-channel zero-point, falling back to scalar zero-point
/// behavior when the representation has only one value.
fn readPerChannelZP(zp_any: anytype, channel: usize) i32 {
    const ZPType = @TypeOf(zp_any);
    const info = @typeInfo(ZPType);

    return switch (info) {
        .pointer => switch (info.pointer.size) {
            .one => readPerChannelZP(zp_any.*, channel),
            .slice => blk: {
                if (zp_any.len == 0) break :blk 0;
                const index = if (zp_any.len == 1) 0 else @min(channel, zp_any.len - 1);
                break :blk numberToI32(@TypeOf(zp_any[index]), zp_any[index]);
            },
            .many, .c => @compileError("unsupported per-channel zero-point pointer representation"),
        },
        .optional => if (zp_any) |payload| readPerChannelZP(payload, channel) else 0,
        .array => blk: {
            if (info.array.len == 0) break :blk 0;
            const index = if (info.array.len == 1) 0 else @min(channel, info.array.len - 1);
            break :blk numberToI32(@TypeOf(zp_any[index]), zp_any[index]);
        },
        .vector => blk: {
            if (info.vector.len == 0) break :blk 0;
            const index = if (info.vector.len == 1) 0 else @min(channel, info.vector.len - 1);
            break :blk numberToI32(@TypeOf(zp_any[index]), zp_any[index]);
        },
        .@"struct" => if (@hasField(ZPType, "data")) blk: {
            if (zp_any.data.len == 0) break :blk 0;
            const index = if (zp_any.data.len == 1) 0 else @min(channel, zp_any.data.len - 1);
            break :blk numberToI32(@TypeOf(zp_any.data[index]), zp_any.data[index]);
        } else 0,
        .int, .comptime_int => numberToI32(ZPType, zp_any),
        else => 0,
    };
}

/// Converts supported numeric scale values into `f32`.
fn numberToF32(comptime T: type, value: T) f32 {
    return switch (@typeInfo(T)) {
        .float, .comptime_float => @as(f32, @floatCast(value)),
        .int, .comptime_int => @as(f32, @floatFromInt(value)),
        else => @compileError("unsupported scale type"),
    };
}

/// Converts supported numeric zero-point, bias, or filter values into `i32`.
fn numberToI32(comptime T: type, value: T) i32 {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @as(i32, @intCast(value)),
        .float, .comptime_float => @as(i32, @intFromFloat(value)),
        else => @compileError("unsupported integer conversion type"),
    };
}

/// Converts an activation zero-point into the signed `s8` domain used by
/// CMSIS-NN convolution parameters.
fn zeroPointToS8(comptime T: type, zero_point: i32) i32 {
    return switch (T) {
        u8 => zero_point - 128,
        i8 => zero_point,
        else => @compileError("CMSIS-NN QLinearConv supports i8/u8 activations only"),
    };
}

/// Converts a single activation value into the signed `i8` domain used by
/// CMSIS-NN.
fn activationToS8(comptime T: type, value: T) i8 {
    return switch (T) {
        u8 => @as(i8, @intCast(@as(i16, @intCast(value)) - 128)),
        i8 => value,
        else => @compileError("CMSIS-NN QLinearConv supports i8/u8 activations only"),
    };
}

/// Converts a single signed CMSIS output value back into the generated output
/// tensor's activation type.
fn s8OutputToType(comptime T: type, value: i8) T {
    return switch (T) {
        u8 => @as(u8, @intCast(@as(i16, @intCast(value)) + 128)),
        i8 => value,
        else => @compileError("CMSIS-NN QLinearConv supports i8/u8 activations only"),
    };
}

/// Clamps an intermediate signed integer into the `i8` range accepted by
/// CMSIS-NN filter and activation buffers.
fn clampToI8(value: i32) i8 {
    const clamped = std.math.clamp(value, std.math.minInt(i8), std.math.maxInt(i8));
    return @as(i8, @intCast(clamped));
}

/// Converts a floating-point effective scale into CMSIS-style fixed-point
/// multiplier and shift values.
fn quantizeMultiplier(scale: f32, multiplier: *i32, shift: *i32) void {
    if (scale == 0.0) {
        multiplier.* = 0;
        shift.* = 0;
        return;
    }

    var sig = scale;
    var exp: i32 = 0;

    while (sig >= 1.0) {
        sig /= 2.0;
        exp += 1;
    }
    while (sig < 0.5) {
        sig *= 2.0;
        exp -= 1;
    }

    const raw = @round(sig * @as(f32, @floatFromInt(@as(i64, 1) << 31)));
    const fixed_point_multiplier = if (raw > @as(f32, @floatFromInt(std.math.maxInt(i32))))
        std.math.maxInt(i32)
    else
        @as(i32, @intFromFloat(raw));

    multiplier.* = fixed_point_multiplier;
    shift.* = exp;
}
