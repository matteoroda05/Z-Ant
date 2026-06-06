const std = @import("std");
const IR_zant = @import("IR_zant");

const Tensor = IR_zant.core.tensor.Tensor;
const pkg_allocator = IR_zant.pkg_allocator.allocator;
const cmsis_layout = IR_zant.cmsis.layout;
const cmsis_quant = IR_zant.cmsis.quant;

const c = @cImport({
    @cInclude("arm_nnfunctions.h");
});

/// Executes QLinearConv through the CMSIS-NN `arm_convolve_wrapper_s8` path.
///
/// The current Z-Ant QLinearConv ABI uses NCHW activations and OIHW filters.
/// CMSIS-NN expects signed NHWC activations and OHWI filters, so this bridge
/// performs layout conversion, signed-domain conversion, per-channel requant
/// setup, scratch-buffer allocation, the CMSIS call, and output conversion back
/// into the caller-owned NCHW output tensor.
pub fn qlinearconvNchwBridge(
    comptime InputType: anytype,
    comptime WeightType: anytype,
    comptime ScaleType: anytype,
    comptime _: anytype,
    comptime BiasType: anytype,
    x: *const Tensor(InputType),
    x_scale: *const Tensor(ScaleType),
    x_zero_point: anytype,
    w: *const Tensor(WeightType),
    w_scale: *const Tensor(ScaleType),
    w_zero_point: anytype,
    output: *Tensor(InputType),
    y_scale: *const Tensor(ScaleType),
    y_zero_point: anytype,
    bias: ?*const Tensor(BiasType),
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    group: ?usize,
    auto_pad: []const u8,
) !void {
    const actual_group = try validateBridgeInputs(InputType, WeightType, x, w, output, group, auto_pad);

    const out_channels = w.shape[0];
    if (out_channels != output.shape[1]) return error.InvalidDimensions;

    var input_nhwc = try cmsis_layout.nchwToNhwc(InputType, &pkg_allocator, @constCast(x));
    defer {
        input_nhwc.deinit();
        pkg_allocator.destroy(input_nhwc);
    }

    var output_nhwc_shape = [_]usize{
        output.shape[0],
        output.shape[2],
        output.shape[3],
        output.shape[1],
    };
    var output_s8_nhwc = try Tensor(i8).fromShape(&pkg_allocator, &output_nhwc_shape);
    defer output_s8_nhwc.deinit();

    try qlinearconvCmsisNhwcCore(
        InputType,
        WeightType,
        ScaleType,
        BiasType,
        input_nhwc,
        x_scale,
        x_zero_point,
        w,
        w_scale,
        w_zero_point,
        &output_s8_nhwc,
        y_scale,
        y_zero_point,
        bias,
        stride,
        pads,
        dilations,
        actual_group,
    );

    try cmsis_quant.writeS8NhwcOutputToNchw(InputType, &output_s8_nhwc, output);
}

/// Executes QLinearConv when activation tensors already use CMSIS's NHWC layout.
///
/// This bridge assumes `x` and `output` are `[N, H, W, C]` tensors, so it does
/// not perform NCHW/NHWC activation layout conversion. It still performs all
/// other CMSIS adaptations: signed activation conversion, OIHW-to-OHWI filter
/// packing, zero-point handling, bias conversion, requantization setup,
/// scratch-buffer allocation, and the `arm_convolve_wrapper_s8` call.
pub fn qlinearconvNhwcBridge(
    comptime InputType: anytype,
    comptime WeightType: anytype,
    comptime ScaleType: anytype,
    comptime _: anytype,
    comptime BiasType: anytype,
    x: *const Tensor(InputType),
    x_scale: *const Tensor(ScaleType),
    x_zero_point: anytype,
    w: *const Tensor(WeightType),
    w_scale: *const Tensor(ScaleType),
    w_zero_point: anytype,
    output: *Tensor(InputType),
    y_scale: *const Tensor(ScaleType),
    y_zero_point: anytype,
    bias: ?*const Tensor(BiasType),
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    group: ?usize,
    auto_pad: []const u8,
) !void {
    const actual_group = try validateBridgeInputs(InputType, WeightType, x, w, output, group, auto_pad);

    const out_channels = w.shape[0];
    if (out_channels != output.shape[3]) return error.InvalidDimensions;

    var output_s8_nhwc = try Tensor(i8).fromShape(&pkg_allocator, output.shape);
    defer output_s8_nhwc.deinit();

    try qlinearconvCmsisNhwcCore(
        InputType,
        WeightType,
        ScaleType,
        BiasType,
        x,
        x_scale,
        x_zero_point,
        w,
        w_scale,
        w_zero_point,
        &output_s8_nhwc,
        y_scale,
        y_zero_point,
        bias,
        stride,
        pads,
        dilations,
        actual_group,
    );

    try cmsis_quant.writeS8NhwcOutputToNhwc(InputType, &output_s8_nhwc, output);
}

/// Validates layout-independent CMSIS bridge requirements and returns the
/// resolved group count.
fn validateBridgeInputs(
    comptime InputType: anytype,
    comptime WeightType: anytype,
    x: anytype,
    w: anytype,
    output: anytype,
    group: ?usize,
    auto_pad: []const u8,
) !usize {
    if (comptime !isCmsisActivation(InputType) or !isCmsisWeight(WeightType)) {
        return error.UnsupportedCmsisQLinearConv;
    }

    if (auto_pad.len != 0 and !std.mem.eql(u8, auto_pad, "NOTSET")) {
        return error.UnsupportedCmsisQLinearConv;
    }
    if (x.shape.len != 4 or w.shape.len != 4 or output.shape.len != 4) {
        return error.InvalidDimensions;
    }

    const actual_group = group orelse 1;
    if (actual_group != 1) {
        return error.UnsupportedCmsisQLinearConv;
    }

    return actual_group;
}

/// Runs the shared CMSIS-NN convolution path after inputs and outputs have been
/// normalized to CMSIS's NHWC activation layout.
fn qlinearconvCmsisNhwcCore(
    comptime InputType: anytype,
    comptime WeightType: anytype,
    comptime ScaleType: anytype,
    comptime BiasType: anytype,
    input_nhwc: *const Tensor(InputType),
    x_scale: *const Tensor(ScaleType),
    x_zero_point: anytype,
    w: *const Tensor(WeightType),
    w_scale: *const Tensor(ScaleType),
    w_zero_point: anytype,
    output_s8_nhwc: *Tensor(i8),
    y_scale: *const Tensor(ScaleType),
    y_zero_point: anytype,
    bias: ?*const Tensor(BiasType),
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    actual_group: usize,
) !void {
    if (input_nhwc.shape.len != 4 or output_s8_nhwc.shape.len != 4) return error.InvalidShape;

    const out_channels = w.shape[0];
    if (out_channels != output_s8_nhwc.shape[3]) return error.InvalidDimensions;

    var context = c.cmsis_nn_context{
        .buf = null,
        .size = 0,
    };

    var input_s8 = try cmsis_quant.prepareActivationS8(InputType, &pkg_allocator, input_nhwc);
    defer input_s8.deinit();

    var filters_cmsis_layout = try cmsis_layout.oihwToCmsisFilterLayout(WeightType, &pkg_allocator, w, actual_group);
    defer filters_cmsis_layout.deinit();

    var filters_s8 = try cmsis_quant.prepareFilterS8(WeightType, &pkg_allocator, &filters_cmsis_layout, w_zero_point, out_channels);
    defer filters_s8.deinit();

    var bias_i32 = try cmsis_quant.prepareBiasI32(BiasType, &pkg_allocator, bias, out_channels);
    defer bias_i32.deinit();

    var requant = try cmsis_quant.makePerChannelRequantParams(&pkg_allocator, x_scale, w_scale, y_scale, out_channels);
    defer requant.deinit();

    const offsets = cmsis_quant.makeActivationOffsets(InputType, x_zero_point, y_zero_point);

    const stride_h = readDimPair(stride, 0, 1);
    const stride_w = readDimPair(stride, 1, stride_h);
    const pad_h = readDimPair(pads, 0, 0);
    const pad_w = readDimPair(pads, 1, 0);
    const dilation_h = readDimPair(dilations, 0, 1);
    const dilation_w = readDimPair(dilations, 1, dilation_h);

    var conv_params = c.cmsis_nn_conv_params{
        .input_offset = @intCast(offsets.input_offset),
        .output_offset = @intCast(offsets.output_offset),
        .stride = .{
            .w = @intCast(stride_w),
            .h = @intCast(stride_h),
        },
        .padding = .{
            .w = @intCast(pad_w),
            .h = @intCast(pad_h),
        },
        .dilation = .{
            .w = @intCast(dilation_w),
            .h = @intCast(dilation_h),
        },
        .activation = .{
            .min = @intCast(offsets.activation_min),
            .max = @intCast(offsets.activation_max),
        },
    };
    var quant_params = c.cmsis_nn_per_channel_quant_params{
        .multiplier = requant.multipliers.ptr,
        .shift = requant.shifts.ptr,
    };
    var input_dims = dims(
        input_s8.tensor.shape[0],
        input_s8.tensor.shape[1],
        input_s8.tensor.shape[2],
        input_s8.tensor.shape[3],
    );
    var filter_dims = dims(
        filters_cmsis_layout.shape[0],
        filters_cmsis_layout.shape[1],
        filters_cmsis_layout.shape[2],
        filters_cmsis_layout.shape[3],
    );
    var bias_dims = dims(1, 1, 1, out_channels);
    var output_dims = dims(
        output_s8_nhwc.shape[0],
        output_s8_nhwc.shape[1],
        output_s8_nhwc.shape[2],
        output_s8_nhwc.shape[3],
    );

    const buffer_size = c.arm_convolve_wrapper_s8_get_buffer_size(&conv_params, &input_dims, &filter_dims, &output_dims);
    if (buffer_size < 0) return error.CmsisBufferSizeFailed;

    var scratch: ?[]u8 = null;
    if (buffer_size > 0) {
        const scratch_buffer = try pkg_allocator.alloc(u8, @as(usize, @intCast(buffer_size)));
        scratch = scratch_buffer;
        context.buf = @ptrCast(scratch_buffer.ptr);
        context.size = buffer_size;
    }
    defer if (scratch) |scratch_buffer| pkg_allocator.free(scratch_buffer);

    const status = c.arm_convolve_wrapper_s8(
        &context,
        &conv_params,
        &quant_params,
        &input_dims,
        input_s8.tensor.data.ptr,
        &filter_dims,
        filters_s8.data.ptr,
        &bias_dims,
        bias_i32.data.ptr,
        &output_dims,
        output_s8_nhwc.data.ptr,
    );
    if (status != c.ARM_CMSIS_NN_SUCCESS) return error.CmsisConvolutionFailed;
}

/// Builds a CMSIS dimension record from logical NHWC-style tensor dimensions.
fn dims(n: usize, h: usize, w: usize, channels: usize) c.cmsis_nn_dims {
    return .{
        .n = @intCast(n),
        .h = @intCast(h),
        .w = @intCast(w),
        .c = @intCast(channels),
    };
}

/// Reads an optional two-element convolution attribute pair such as stride,
/// padding, or dilation, returning a caller-provided default when absent.
fn readDimPair(value: ?[]const usize, index: usize, default: usize) usize {
    if (value) |items| {
        if (index < items.len) return items[index];
    }

    return default;
}

/// Returns whether the activation type can be represented by the current
/// CMSIS-NN signed `s8` bridge.
fn isCmsisActivation(comptime T: type) bool {
    return T == i8 or T == u8;
}

/// Returns whether the weight type can be packed into the current CMSIS-NN
/// signed `s8` filter buffer.
fn isCmsisWeight(comptime T: type) bool {
    return T == i8 or T == u8;
}
