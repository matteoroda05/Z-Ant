//! QLinearConv-specific adapter for the generic CMSIS parameter emitter.

const std = @import("std");
const cmsis_prepare = @import("../../../cmsis/prepare.zig");

pub fn collectReplacedInitializers(op: anytype, collector: anytype) !void {
    if (!cmsis_prepare.qlinearconv_isSupported(op)) return;

    try collector.addTensor(op.input_w);
    if (op.input_B) |bias| {
        if (bias.name.len != 0) try collector.addTensor(bias);
    }
}

pub fn writePreparedParameters(op: anytype, emitter: anytype) !void {
    if (!cmsis_prepare.qlinearconv_isSupported(op)) return;

    var prepared = try cmsis_prepare.qlinearconv_prepare(emitter.allocator, op);
    defer prepared.deinit(emitter.allocator);

    const output_name = try op.output_y.getNameSanitized();
    const allocator = emitter.allocator.*;

    const filter_symbol = try std.fmt.allocPrint(allocator, "cmsis_{s}_filter", .{output_name});
    defer allocator.free(filter_symbol);
    const shape_symbol = try std.fmt.allocPrint(allocator, "cmsis_{s}_filter_shape", .{output_name});
    defer allocator.free(shape_symbol);
    const bias_symbol = try std.fmt.allocPrint(allocator, "cmsis_{s}_bias", .{output_name});
    defer allocator.free(bias_symbol);
    const multiplier_symbol = try std.fmt.allocPrint(allocator, "cmsis_{s}_multiplier", .{output_name});
    defer allocator.free(multiplier_symbol);
    const shift_symbol = try std.fmt.allocPrint(allocator, "cmsis_{s}_shift", .{output_name});
    defer allocator.free(shift_symbol);

    try emitter.emitShape4(shape_symbol, prepared.filter_shape);
    try emitter.emitArray(filter_symbol, i8, prepared.filter_s8);
    try emitter.emitArray(bias_symbol, i32, prepared.bias_i32);
    try emitter.emitArray(multiplier_symbol, i32, prepared.multipliers);
    try emitter.emitArray(shift_symbol, i32, prepared.shifts);
}
