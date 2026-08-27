const std = @import("std");
const IR_zant = @import("IR_zant");

const Tensor = IR_zant.core.tensor.Tensor;
const tensor_utils = IR_zant.core.tensor.utils;

/// Converts a 4D activation tensor from Z-Ant's `[N, C, H, W]` layout to
/// CMSIS-NN's `[N, H, W, C]` activation layout.
///
/// This is a thin CMSIS-named wrapper around the generic tensor utility so
/// operator backends do not need to import the core layout helper directly.
pub fn nchwToNhwc(comptime T: type, allocator: *const std.mem.Allocator, input_nchw: *Tensor(T)) !*Tensor(T) {
    return tensor_utils.from_NCHW_to_NHWC(T, allocator, input_nchw);
}

/// Copies a CMSIS-NN `[N, H, W, C]` output tensor into an already allocated
/// Z-Ant `[N, C, H, W]` output tensor.
///
/// The destination tensor is caller-owned. This keeps accelerator backends
/// compatible with dispatch functions that receive their output tensor from
/// generated model code.
pub fn nhwcToNchwInto(comptime T: type, output_nhwc: *const Tensor(T), output_nchw: *Tensor(T)) !void {
    try validateNhwcToNchwShapes(T, output_nhwc, output_nchw);

    const n_count = output_nchw.shape[0];
    const channels = output_nchw.shape[1];
    const height = output_nchw.shape[2];
    const width = output_nchw.shape[3];

    for (0..n_count) |n| {
        for (0..channels) |c| {
            for (0..height) |h| {
                for (0..width) |w| {
                    const nhwc_index = ((n * height + h) * width + w) * channels + c;
                    const nchw_index = ((n * channels + c) * height + h) * width + w;
                    output_nchw.data[nchw_index] = output_nhwc.data[nhwc_index];
                }
            }
        }
    }
}

/// Reorders convolution filters from ONNX/Z-Ant `[O, I/group, H, W]` layout
/// into the standard CMSIS-NN convolution filter layout `[O, H, W, I/group]`.
///
/// This helper only changes element order. Signed-domain conversion,
/// zero-point subtraction, and clamping are handled in `quant.zig`.
pub fn oihwToCmsisFilterLayout(
    comptime T: type,
    allocator: *const std.mem.Allocator,
    weights_oihw: *const Tensor(T),
    group: usize,
) !Tensor(T) {
    if (weights_oihw.shape.len != 4) return error.InvalidShape;
    if (group == 0) return error.InvalidGroupParameter;

    const out_channels = weights_oihw.shape[0];
    const in_channels_per_group = weights_oihw.shape[1];
    const kernel_height = weights_oihw.shape[2];
    const kernel_width = weights_oihw.shape[3];

    if (out_channels == 0 or in_channels_per_group == 0 or kernel_height == 0 or kernel_width == 0) {
        return error.InvalidShape;
    }
    if (out_channels % group != 0) return error.InvalidGroupParameter;

    var cmsis_shape = [_]usize{ out_channels, kernel_height, kernel_width, in_channels_per_group };
    var filters = try Tensor(T).fromShape(allocator, &cmsis_shape);
    errdefer filters.deinit();

    for (0..out_channels) |oc| {
        for (0..kernel_height) |kh| {
            for (0..kernel_width) |kw| {
                for (0..in_channels_per_group) |ic| {
                    const old_index = ((oc * in_channels_per_group + ic) * kernel_height + kh) * kernel_width + kw;
                    const new_index = ((oc * kernel_height + kh) * kernel_width + kw) * in_channels_per_group + ic;
                    filters.data[new_index] = weights_oihw.data[old_index];
                }
            }
        }
    }

    return filters;
}

/// Reorders a signed depthwise filter from ONNX `[C_out, 1, H, W]` layout to
/// CMSIS-NN `[1, H, W, C_out]` layout.
///
/// Signed-domain conversion must happen before this transformation because the
/// generic filter preparation helper identifies output channels along axis 0.
pub fn oihwToCmsisDepthwiseLayout(
    comptime T: type,
    allocator: *const std.mem.Allocator,
    weights_oihw: *const Tensor(T),
    ch_mult: usize,
) !Tensor(T) {
    if (weights_oihw.shape.len != 4) return error.InvalidShape;
    if (ch_mult == 0) return error.InvalidGroupParameter;

    const out_channels = weights_oihw.shape[0];
    const in_channels_per_group = weights_oihw.shape[1];
    const kernel_height = weights_oihw.shape[2];
    const kernel_width = weights_oihw.shape[3];

    if (out_channels == 0 or kernel_height == 0 or kernel_width == 0) return error.InvalidShape;
    if (in_channels_per_group != 1) return error.InvalidShape;
    if (out_channels % ch_mult != 0) return error.InvalidGroupParameter;

    var cmsis_shape = [_]usize{ 1, kernel_height, kernel_width, out_channels };
    var filters = try Tensor(T).fromShape(allocator, &cmsis_shape);
    errdefer filters.deinit();

    for (0..kernel_height) |kh| {
        for (0..kernel_width) |kw| {
            for (0..out_channels) |oc| {
                const old_index = (oc * kernel_height + kh) * kernel_width + kw;
                const new_index = (kh * kernel_width + kw) * out_channels + oc;
                filters.data[new_index] = weights_oihw.data[old_index];
            }
        }
    }

    return filters;
}

/// Validates that an NHWC source tensor and an NCHW destination tensor describe
/// the same logical 4D output before copying data between layouts.
fn validateNhwcToNchwShapes(comptime T: type, output_nhwc: *const Tensor(T), output_nchw: *const Tensor(T)) !void {
    if (output_nhwc.shape.len != 4 or output_nchw.shape.len != 4) return error.InvalidShape;

    const nhwc_n = output_nhwc.shape[0];
    const nhwc_h = output_nhwc.shape[1];
    const nhwc_w = output_nhwc.shape[2];
    const nhwc_c = output_nhwc.shape[3];

    const nchw_n = output_nchw.shape[0];
    const nchw_c = output_nchw.shape[1];
    const nchw_h = output_nchw.shape[2];
    const nchw_w = output_nchw.shape[3];

    if (nhwc_n != nchw_n or nhwc_h != nchw_h or nhwc_w != nchw_w or nhwc_c != nchw_c) {
        return error.ShapeMismatch;
    }
    if (output_nhwc.data.len != output_nchw.data.len) return error.ShapeMismatch;
}
