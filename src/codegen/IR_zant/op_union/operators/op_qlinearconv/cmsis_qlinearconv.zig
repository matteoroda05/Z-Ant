const std = @import("std");
const IR_zant = @import("IR_zant");

const Tensor = IR_zant.core.tensor.Tensor;
const pkg_allocator = IR_zant.pkg_allocator.allocator;
const cmsis_layout = IR_zant.cmsis.layout;
const cmsis_quant = IR_zant.cmsis.quant;

const c = @cImport({
    @cInclude("arm_nnfunctions.h");
});

/// Executes a codegen-prepared QLinearConv whose activations are stored NCHW.
///
/// The filter (OHWI `i8`), bias (`i32`), and per-channel requant multiplier/shift
/// arrays are precomputed at code-generation time (see `prepare.zig`) and passed
/// in as (typically flash-resident) `const` slices. This function therefore does
/// only the input-dependent work: the NCHW->NHWC input transpose, the `u8`->`i8`
/// activation shift, the CMSIS call, and the NHWC->NCHW output writeback. It has
/// no embedded fallback — the generator only emits calls to it for nodes
/// `isCmsisSupported` already accepted.
pub fn qlinearconvNchw(
    comptime InputType: anytype,
    x: *const Tensor(InputType),
    x_zero_point: anytype,
    output: *Tensor(InputType),
    y_zero_point: anytype,
    filter_data: []const i8,
    filter_shape: [4]usize,
    bias: []const i32,
    multipliers: []const i32,
    shifts: []const i32,
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    group: ?usize,
    auto_pad: []const u8,
) !void {
    if (comptime !isCmsisActivation(InputType)) return error.UnsupportedCmsisQLinearConv;
    if (auto_pad.len != 0 and !std.mem.eql(u8, auto_pad, "NOTSET")) return error.UnsupportedCmsisQLinearConv;
    if (x.shape.len != 4 or output.shape.len != 4) return error.InvalidDimensions;

    const actual_group = group orelse 1;
    if (actual_group != 1) return error.UnsupportedCmsisQLinearConv;

    const out_channels = output.shape[1];
    if (filter_shape[0] != out_channels) return error.InvalidDimensions;
    if (bias.len < out_channels or multipliers.len < out_channels or shifts.len < out_channels) {
        return error.InvalidDimensions;
    }

    var input_nhwc = try cmsis_layout.nchwToNhwc(InputType, &pkg_allocator, @constCast(x));
    defer {
        input_nhwc.deinit();
        pkg_allocator.destroy(input_nhwc);
    }

    var input_s8 = try cmsis_quant.prepareActivationS8(InputType, &pkg_allocator, input_nhwc);
    defer input_s8.deinit();

    var output_nhwc_shape = [_]usize{
        output.shape[0],
        output.shape[2],
        output.shape[3],
        output.shape[1],
    };
    var output_s8_nhwc = try Tensor(i8).fromShape(&pkg_allocator, &output_nhwc_shape);
    defer output_s8_nhwc.deinit();

    const offsets = cmsis_quant.makeActivationOffsets(InputType, x_zero_point, y_zero_point);

    try runCmsisConvolve(
        &input_s8.tensor,
        filter_data,
        filter_shape,
        bias,
        multipliers,
        shifts,
        offsets,
        stride,
        pads,
        dilations,
        &output_s8_nhwc,
    );

    try cmsis_quant.writeS8NhwcOutputToNchw(InputType, &output_s8_nhwc, output);
}

/// Executes a codegen-prepared QLinearConv whose activations are already NHWC.
///
/// Identical to `qlinearconvNchw` except the input and output tensors already use
/// CMSIS's `[N, H, W, C]` layout, so no NCHW<->NHWC transpose is performed. The
/// only runtime work is the `u8`->`i8` activation shift, the CMSIS call, and the
/// signed-domain output writeback. The filter/bias/requant slices are precomputed
/// at code-generation time. Not currently emitted by the generator (Z-Ant stores
/// activations NCHW); provided for a future NHWC-native path.
pub fn qlinearconvNhwc(
    comptime InputType: anytype,
    x: *const Tensor(InputType),
    x_zero_point: anytype,
    output: *Tensor(InputType),
    y_zero_point: anytype,
    filter_data: []const i8,
    filter_shape: [4]usize,
    bias: []const i32,
    multipliers: []const i32,
    shifts: []const i32,
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    group: ?usize,
    auto_pad: []const u8,
) !void {
    if (comptime !isCmsisActivation(InputType)) return error.UnsupportedCmsisQLinearConv;
    if (auto_pad.len != 0 and !std.mem.eql(u8, auto_pad, "NOTSET")) return error.UnsupportedCmsisQLinearConv;
    if (x.shape.len != 4 or output.shape.len != 4) return error.InvalidDimensions;

    const actual_group = group orelse 1;
    if (actual_group != 1) return error.UnsupportedCmsisQLinearConv;

    const out_channels = output.shape[3];
    if (filter_shape[0] != out_channels) return error.InvalidDimensions;
    if (bias.len < out_channels or multipliers.len < out_channels or shifts.len < out_channels) {
        return error.InvalidDimensions;
    }

    var input_s8 = try cmsis_quant.prepareActivationS8(InputType, &pkg_allocator, x);
    defer input_s8.deinit();

    var output_s8_nhwc = try Tensor(i8).fromShape(&pkg_allocator, output.shape);
    defer output_s8_nhwc.deinit();

    const offsets = cmsis_quant.makeActivationOffsets(InputType, x_zero_point, y_zero_point);

    try runCmsisConvolve(
        &input_s8.tensor,
        filter_data,
        filter_shape,
        bias,
        multipliers,
        shifts,
        offsets,
        stride,
        pads,
        dilations,
        &output_s8_nhwc,
    );

    try cmsis_quant.writeS8NhwcOutputToNhwc(InputType, &output_s8_nhwc, output);
}

/// Runs the shared CMSIS-NN convolution call once all buffers are prepared.
///
/// This is the single place the CMSIS kernel is invoked. It builds the
/// params/dims records, sizes the scratch buffer, and calls
/// `arm_convolve_wrapper_s8`. `filter_data` / `bias_data` / `multipliers` /
/// `shifts` may be flash-resident `const` slices, hence the `@constCast`s.
fn runCmsisConvolve(
    input_s8: *const Tensor(i8),
    filter_data: []const i8,
    filter_shape: [4]usize,
    bias_data: []const i32,
    multipliers: []const i32,
    shifts: []const i32,
    offsets: cmsis_quant.ActivationOffsets,
    stride: ?[]const usize,
    pads: ?[]const usize,
    dilations: ?[]const usize,
    output_s8_nhwc: *Tensor(i8),
) !void {
    const out_channels = output_s8_nhwc.shape[3];

    var context = c.cmsis_nn_context{
        .buf = null,
        .size = 0,
    };

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
        .multiplier = @constCast(multipliers.ptr),
        .shift = @constCast(shifts.ptr),
    };
    var input_dims = dims(
        input_s8.shape[0],
        input_s8.shape[1],
        input_s8.shape[2],
        input_s8.shape[3],
    );
    var filter_dims = dims(
        filter_shape[0],
        filter_shape[1],
        filter_shape[2],
        filter_shape[3],
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
        input_s8.data.ptr,
        &filter_dims,
        @constCast(filter_data.ptr),
        &bias_dims,
        @constCast(bias_data.ptr),
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
