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
