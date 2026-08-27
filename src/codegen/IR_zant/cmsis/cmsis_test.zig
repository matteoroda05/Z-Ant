//! Tests for the reusable CMSIS-NN layout and quantization helpers.
//!
//! Individual `test` declarations cannot have `///` doc comments in Zig, so
//! the test cases below use normal comments for case-level intent.

const std = @import("std");
const IR_zant = @import("IR_zant");

const Tensor = IR_zant.core.tensor.Tensor;
const layout = IR_zant.cmsis.layout;
const quant = IR_zant.cmsis.quant;

// Verifies that a CMSIS NHWC output buffer can be copied into the caller-owned
// Z-Ant NCHW output tensor without changing allocation ownership.
test "CMSIS layout converts NHWC output into NCHW destination" {
    const allocator = std.testing.allocator;

    var nhwc_shape = [_]usize{ 1, 2, 2, 2 };
    var nhwc_data = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var output_nhwc = try Tensor(i8).fromArray(&allocator, &nhwc_data, &nhwc_shape);
    defer output_nhwc.deinit();

    var nchw_shape = [_]usize{ 1, 2, 2, 2 };
    var output_nchw = try Tensor(i8).fromShape(&allocator, &nchw_shape);
    defer output_nchw.deinit();

    try layout.nhwcToNchwInto(i8, &output_nhwc, &output_nchw);

    const expected = [_]i8{ 1, 3, 5, 7, 2, 4, 6, 8 };
    try std.testing.expectEqualSlices(i8, &expected, output_nchw.data);
}

// Verifies that standard convolution filters are reordered from OIHW to OHWI,
// which is the filter layout expected by CMSIS-NN convolution wrappers.
test "CMSIS layout packs OIHW filters into OHWI" {
    const allocator = std.testing.allocator;

    var oihw_shape = [_]usize{ 2, 2, 2, 2 };
    var oihw_data = [_]i8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };
    var weights = try Tensor(i8).fromArray(&allocator, &oihw_data, &oihw_shape);
    defer weights.deinit();

    var packed_filters = try layout.oihwToCmsisFilterLayout(i8, &allocator, &weights, 1);
    defer packed_filters.deinit();

    const expected = [_]i8{
        1, 5,  2,  6,  3,  7,  4,  8,
        9, 13, 10, 14, 11, 15, 12, 16,
    };
    try std.testing.expectEqualSlices(i8, &expected, packed_filters.data);
}

// Covers the three channel-multiplier classes that the CMSIS depthwise wrapper
// may route to different kernels while preserving one prepared filter format.
test "CMSIS layout packs depthwise filters for representative channel multipliers" {
    const allocator = std.testing.allocator;

    inline for (.{
        .{ .ch_mult = 1, .out_channels = 2 },
        .{ .ch_mult = 3, .out_channels = 6 },
        .{ .ch_mult = 4, .out_channels = 8 },
    }) |case| {
        var shape = [_]usize{ case.out_channels, 1, 2, 2 };
        var data: [case.out_channels * 4]i8 = undefined;
        for (&data, 0..) |*value, index| value.* = @intCast(index);

        var weights = try Tensor(i8).fromArray(&allocator, &data, &shape);
        defer weights.deinit();
        var packed_filters = try layout.oihwToCmsisDepthwiseLayout(i8, &allocator, &weights, case.ch_mult);
        defer packed_filters.deinit();

        const expected_shape = [_]usize{ 1, 2, 2, case.out_channels };
        try std.testing.expectEqualSlices(usize, &expected_shape, packed_filters.shape);
        for (0..2) |kh| {
            for (0..2) |kw| {
                for (0..case.out_channels) |oc| {
                    const packed_index = (kh * 2 + kw) * case.out_channels + oc;
                    const source_index = oc * 4 + kh * 2 + kw;
                    try std.testing.expectEqual(data[source_index], packed_filters.data[packed_index]);
                }
            }
        }
    }
}

// Verifies the core quantization preparation pieces used by the QLinearConv
// bridge: per-channel requant parameter allocation and signed filter packing.
test "CMSIS quant prepares per-channel requant params and packed filters" {
    const allocator = std.testing.allocator;

    var x_scale_shape = [_]usize{1};
    var x_scale_data = [_]f32{0.5};
    var x_scale = try Tensor(f32).fromArray(&allocator, &x_scale_data, &x_scale_shape);
    defer x_scale.deinit();

    var w_scale_shape = [_]usize{2};
    var w_scale_data = [_]f32{ 0.25, 0.125 };
    var w_scale = try Tensor(f32).fromArray(&allocator, &w_scale_data, &w_scale_shape);
    defer w_scale.deinit();

    var y_scale_shape = [_]usize{1};
    var y_scale_data = [_]f32{0.25};
    var y_scale = try Tensor(f32).fromArray(&allocator, &y_scale_data, &y_scale_shape);
    defer y_scale.deinit();

    var requant = try quant.makePerChannelRequantParams(&allocator, &x_scale, &w_scale, &y_scale, 2);
    defer requant.deinit();

    try std.testing.expectEqual(@as(usize, 2), requant.multipliers.len);
    try std.testing.expectEqual(@as(usize, 2), requant.shifts.len);

    var filter_shape = [_]usize{ 2, 1, 1, 2 };
    var filter_data = [_]u8{ 130, 131, 140, 141 };
    var filters = try Tensor(u8).fromArray(&allocator, &filter_data, &filter_shape);
    defer filters.deinit();

    var zero_point_shape = [_]usize{2};
    var zero_point_data = [_]u8{ 128, 130 };
    var zero_points = try Tensor(u8).fromArray(&allocator, &zero_point_data, &zero_point_shape);
    defer zero_points.deinit();

    var packed_filters = try quant.prepareFilterS8(u8, &allocator, &filters, &zero_points, 2);
    defer packed_filters.deinit();

    const expected = [_]i8{ 2, 3, 10, 11 };
    try std.testing.expectEqualSlices(i8, &expected, packed_filters.data);
}

// Verifies conversion between unsigned ONNX-style activation values and the
// signed `i8` domain used by CMSIS-NN.
test "CMSIS quant converts u8 activation and output domains" {
    const allocator = std.testing.allocator;

    var nhwc_shape = [_]usize{ 1, 1, 2, 2 };
    var input_data = [_]u8{ 0, 128, 129, 255 };
    var input = try Tensor(u8).fromArray(&allocator, &input_data, &nhwc_shape);
    defer input.deinit();

    var prepared = try quant.prepareActivationS8(u8, &allocator, &input);
    defer prepared.deinit();

    const expected_input = [_]i8{ -128, 0, 1, 127 };
    try std.testing.expectEqualSlices(i8, &expected_input, prepared.tensor.data);

    var output_nchw_shape = [_]usize{ 1, 2, 1, 2 };
    var output = try Tensor(u8).fromShape(&allocator, &output_nchw_shape);
    defer output.deinit();

    try quant.writeS8NhwcOutputToNchw(u8, &prepared.tensor, &output);

    const expected_output = [_]u8{ 0, 129, 128, 255 };
    try std.testing.expectEqualSlices(u8, &expected_output, output.data);

    var output_nhwc = try Tensor(u8).fromShape(&allocator, &nhwc_shape);
    defer output_nhwc.deinit();

    try quant.writeS8NhwcOutputToNhwc(u8, &prepared.tensor, &output_nhwc);

    const expected_nhwc_output = [_]u8{ 0, 128, 129, 255 };
    try std.testing.expectEqualSlices(u8, &expected_nhwc_output, output_nhwc.data);
}

test "CMSIS depthwise bridge matches deterministic signed convolution" {
    if (comptime !IR_zant.cmsis.cmsisUsed()) return error.SkipZigTest;
    const depthwise = IR_zant.core.math_standard.qlinear_conv_dispatch_cmsis_depthwise_prepared;
    const allocator = std.testing.allocator;

    var input_shape = [_]usize{ 1, 2, 1, 2 };
    var input_data = [_]i8{ 1, 2, 3, 4 };
    var input = try Tensor(i8).fromArray(&allocator, &input_data, &input_shape);
    defer input.deinit();
    var output = try Tensor(i8).fromShape(&allocator, &input_shape);
    defer output.deinit();

    const filter = [_]i8{ 1, 1 };
    const bias = [_]i32{ 0, 0 };
    const multipliers = [_]i32{ 1 << 30, 1 << 30 };
    const shifts = [_]i32{ 1, 1 };
    const stride = [_]usize{ 1, 1 };
    const pads = [_]usize{ 0, 0, 0, 0 };
    const dilations = [_]usize{ 1, 1 };

    try depthwise(
        i8,
        &input,
        @as(i8, 0),
        &output,
        @as(i8, 0),
        &filter,
        .{ 1, 1, 1, 2 },
        &bias,
        &multipliers,
        &shifts,
        1,
        &stride,
        &pads,
        &dilations,
        2,
        "NOTSET",
    );

    try std.testing.expectEqualSlices(i8, &input_data, output.data);
}

test "CMSIS depthwise bridge matches unsigned per-channel multiplier convolution" {
    if (comptime !IR_zant.cmsis.cmsisUsed()) return error.SkipZigTest;
    const depthwise = IR_zant.core.math_standard.qlinear_conv_dispatch_cmsis_depthwise_prepared;
    const allocator = std.testing.allocator;

    var input_shape = [_]usize{ 1, 2, 1, 1 };
    var input_data = [_]u8{ 130, 131 };
    var input = try Tensor(u8).fromArray(&allocator, &input_data, &input_shape);
    defer input.deinit();
    var output_shape = [_]usize{ 1, 4, 1, 1 };
    var output = try Tensor(u8).fromShape(&allocator, &output_shape);
    defer output.deinit();

    const filter = [_]i8{ 1, 2, 3, 4 };
    const bias = [_]i32{ 0, 0, 0, 0 };
    const multipliers = [_]i32{ 1 << 30, 1 << 30, 1 << 30, 1 << 30 };
    const shifts = [_]i32{ 1, 1, 1, 1 };
    const stride = [_]usize{ 1, 1 };
    const pads = [_]usize{ 0, 0, 0, 0 };
    const dilations = [_]usize{ 1, 1 };

    try depthwise(
        u8,
        &input,
        @as(u8, 128),
        &output,
        @as(u8, 128),
        &filter,
        .{ 1, 1, 1, 4 },
        &bias,
        &multipliers,
        &shifts,
        2,
        &stride,
        &pads,
        &dilations,
        2,
        "NOTSET",
    );

    const expected = [_]u8{ 130, 132, 137, 140 };
    try std.testing.expectEqualSlices(u8, &expected, output.data);
}

test "CMSIS depthwise bridge rejects unsupported batch and dilation" {
    if (comptime !IR_zant.cmsis.cmsisUsed()) return error.SkipZigTest;
    const depthwise = IR_zant.core.math_standard.qlinear_conv_dispatch_cmsis_depthwise_prepared;
    const allocator = std.testing.allocator;

    var batch_input_shape = [_]usize{ 2, 2, 1, 1 };
    var input_data = [_]i8{ 1, 2, 3, 4 };
    var batch_input = try Tensor(i8).fromArray(&allocator, &input_data, &batch_input_shape);
    defer batch_input.deinit();
    var batch_output = try Tensor(i8).fromShape(&allocator, &batch_input_shape);
    defer batch_output.deinit();

    const filter = [_]i8{ 1, 1 };
    const bias = [_]i32{ 0, 0 };
    const multipliers = [_]i32{ 1 << 30, 1 << 30 };
    const shifts = [_]i32{ 1, 1 };
    const stride = [_]usize{ 1, 1 };
    const pads = [_]usize{ 0, 0, 0, 0 };
    const unit_dilation = [_]usize{ 1, 1 };

    try std.testing.expectError(error.UnsupportedCmsisQLinearConv, depthwise(
        i8,
        &batch_input,
        @as(i8, 0),
        &batch_output,
        @as(i8, 0),
        &filter,
        .{ 1, 1, 1, 2 },
        &bias,
        &multipliers,
        &shifts,
        1,
        &stride,
        &pads,
        &unit_dilation,
        2,
        "NOTSET",
    ));

    var input_shape = [_]usize{ 1, 2, 1, 2 };
    var input = try Tensor(i8).fromArray(&allocator, &input_data, &input_shape);
    defer input.deinit();
    var output = try Tensor(i8).fromShape(&allocator, &input_shape);
    defer output.deinit();
    const unsupported_dilation = [_]usize{ 2, 1 };

    try std.testing.expectError(error.UnsupportedCmsisQLinearConv, depthwise(
        i8,
        &input,
        @as(i8, 0),
        &output,
        @as(i8, 0),
        &filter,
        .{ 1, 1, 1, 2 },
        &bias,
        &multipliers,
        &shifts,
        1,
        &stride,
        &pads,
        &unsupported_dilation,
        2,
        "NOTSET",
    ));
}
