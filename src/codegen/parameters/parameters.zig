const std = @import("std");
const IR_zant = @import("IR_zant");
const codegen_options = @import("codegen").codegen_options;

// --- allocator
const allocator = @import("codegen").pkg_allocator.allocator;

// --- zant IR
const IR_utils = IR_zant.utils;
const GraphZant = IR_zant.GraphZant;
const TensorZant = IR_zant.TensorZant;
const TensorCategory = IR_zant.TensorCategory;
const NodeZant = IR_zant.NodeZant;

const tensorZantMap: *std.StringHashMap(TensorZant) = &IR_zant.tensorZant_lib.tensorMap;

/// XIP Configuration for weight storage
pub const XIPConfig = struct {
    enabled: bool = true,
    section_name: []const u8 = ".flash_weights",
    validate_pointers: bool = true,

    /// Get the linksection attribute for weight arrays with platform-specific formatting
    pub fn getLinkSection(self: *const XIPConfig) []const u8 {
        if (!self.enabled) {
            // macOS uses mach-o format which requires "segment,section" (e.g. "__DATA,__data").
            // ELF targets (Linux, embedded like Arduino Nicla) use single-name sections (e.g. ".rodata").
            if (comptime @import("builtin").target.os.tag == .macos) {
                return "__DATA,__data";
            } else {
                return ".rodata";
            }
        }
        // For other platforms, use the original format
        return self.section_name;
    }
};

/// Global XIP configuration - initialized from codegen options
var global_xip_config = XIPConfig{
    .enabled = codegen_options.xip,
};

/// Set XIP configuration
pub fn setXIPConfig(config: XIPConfig) void {
    global_xip_config = config;
}

/// Writes the Zig code required to initialize all tensor initializers in the ONNX model.
/// This function generates declarations and definitions for each tensor.
///
/// - `writer`: The file writer to output generated code.
pub inline fn write_parameters(writer: *std.Io.Writer, linearizedGraph: []const *NodeZant) !void {

    //importing the libraries
    try write_libraries_parameters(writer);

    // On CMSIS builds, QLinearConv nodes we prepare replace their original filter
    // and bias with folded-in `cmsis_` constants, so those originals must not be
    // emitted here. `excluded` holds their sanitized names (empty otherwise).
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    if (comptime IR_zant.cmsis.cmsisUsed()) {
        try buildExcludedInitializers(&excluded, linearizedGraph);
    }

    try writer.print(
        \\
        \\
        \\ // ---------------------------------------------------
        \\ // +         Initializing Weights and Biases         +
        \\ // ---------------------------------------------------
    , .{});

    try write_initilizers(writer, &excluded);

    try writer.print(
        \\
        \\
        \\ // -----------------------------------------
        \\ // +         Initializing constants        +
        \\ // -----------------------------------------
    , .{});

    try write_constantTensors(writer);

    if (comptime IR_zant.cmsis.cmsisUsed()) {
        try writer.print(
            \\
            \\
            \\ // -----------------------------------------------------
            \\ // +   CMSIS-NN prepared constants (codegen-time)       +
            \\ // -----------------------------------------------------
        , .{});
        try write_cmsis_prepared(writer, linearizedGraph);
    }
}

/// Collects the sanitized names of the original filter/bias initializers that
/// belong to preparable QLinearConv nodes and are safe to drop, i.e. not
/// referenced by any non-prepared node. On CMSIS builds these originals are
/// replaced by the folded-in `cmsis_` constants.
fn buildExcludedInitializers(excluded: *std.StringHashMap(void), nodes: []const *NodeZant) !void {
    var candidates = std.StringHashMap(void).init(allocator);
    defer candidates.deinit();
    var protected = std.StringHashMap(void).init(allocator);
    defer protected.deinit();

    for (nodes) |node| {
        if (IR_zant.cmsis.isCmsisSupported(node.*)) {
            switch (node.op) {
                .qlinearconv => |*q| {
                    try candidates.put(try q.input_w.getNameSanitized(), {});
                    if (q.input_B) |bias| {
                        if (bias.name.len != 0) try candidates.put(try bias.getNameSanitized(), {});
                    }
                },
                else => {},
            }
        } else {
            // Anything a non-prepared node consumes must stay in flash.
            // (Returned slice is owned by the op's own allocator; not freed here
            // because this is a short-lived host codegen pass.)
            const inputs = node.get_input_tensors() catch continue;
            for (inputs) |tensor| {
                try protected.put(try tensor.getNameSanitized(), {});
            }
        }
    }

    var it = candidates.keyIterator();
    while (it.next()) |key| {
        if (!protected.contains(key.*)) try excluded.put(key.*, {});
    }
}

fn write_initilizers(writer: *std.Io.Writer, excluded: *const std.StringHashMap(void)) !void {
    const initializers: []TensorZant = try IR_utils.getInitializers(tensorZantMap);

    // Iterate over all initializers in the ONNX model and generate code
    for (initializers) |*initializer| {
        const name: []const u8 = try initializer.getNameSanitized();

        // Skip originals folded into CMSIS-NN prepared constants (CMSIS builds).
        if (excluded.contains(name)) continue;

        try writer.print(
            \\
            \\
            \\ // ----------- Initializing tensor_{s};
        , .{name});

        // Generate the shape array for the tensor
        try writeTensorShape(writer, initializer);

        // Generate the data array for the tensor
        try writeArray(writer, initializer);

        // Create the tensor instance
        // Force u8 type for input zero_point tensors, but i8 for weight zero_point tensors
        const is_zero_point = std.mem.indexOf(u8, name, "zero_point") != null;
        const is_weight_zero_point = is_zero_point and std.mem.indexOf(u8, name, "const_fold_opt") != null;
        const tensor_type = if (is_weight_zero_point) "i8" else if (is_zero_point) "u8" else initializer.ty.toString();
        try writer.print(
            \\
            \\pub const tensor_{s} = Tensor({s}).fromConstBuffer(&allocator, &array_{s}, &shape_tensor_{s});
        , .{ name, tensor_type, name, name });
    }
}

/// Generate missing zero_point tensors for quantized operations
fn write_constantTensors(writer: *std.Io.Writer) !void {
    const constants: []TensorZant = try IR_utils.getConstants(tensorZantMap);

    if (constants.len == 0) {
        try writer.print(
            \\
            \\
            \\ // no Constant Tensors are present;
        , .{});

        return;
    }
    // Iterate over all initializers in the ONNX model and generate code
    for (constants) |*constant_tensors| {
        const name: []const u8 = try constant_tensors.getNameSanitized();

        try writer.print(
            \\
            \\
            \\ // ----------- Initializing Constant tensor_{s};
        , .{name});

        // Generate the shape array for the tensor
        try writeTensorShape(writer, constant_tensors);

        // Generate the data array for the tensor
        try writeArray(writer, constant_tensors);

        // Create the tensor instance
        try writer.print(
            \\
            \\pub const tensor_{s} = Tensor({s}).fromConstBuffer(&allocator, &array_{s}, &shape_tensor_{s});
        , .{ name, constant_tensors.ty.toString(), name, name });
    }
}

/// Emits the codegen-time CMSIS-NN constants for every preparable QLinearConv
/// node into `static_parameters.zig`. Names follow the hybrid scheme:
/// filter/filter_shape are weight-keyed (`cmsis_tensor_<w>` /
/// `cmsis_tensor_<w>_filter_shape`); bias is bias-keyed (`cmsis_tensor_<b>`) or
/// output-keyed when the node has no bias; the per-node requant arrays are
/// output-keyed (`cmsis_tensor_<out>_multiplier` / `_shift`). Emission is deduped
/// by symbol name so a weight shared by two prepared nodes is written once.
fn write_cmsis_prepared(writer: *std.Io.Writer, nodes: []const *NodeZant) !void {
    const section = global_xip_config.getLinkSection();

    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();

    for (nodes) |node| {
        switch (node.op) {
            .qlinearconv => |*q| {
                if (!IR_zant.cmsis.prepare.qlinearconv_isSupported(q)) continue;

                var prepared = try IR_zant.cmsis.prepare.qlinearconv_prepare(&allocator, q);
                defer prepared.deinit(&allocator);

                const w_name = try q.input_w.getNameSanitized();
                const out_name = try q.output_y.getNameSanitized();

                const filter_symbol = try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}", .{w_name});
                const shape_symbol = try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}_filter_shape", .{w_name});
                const bias_symbol = if (q.input_B) |bias| blk: {
                    if (bias.name.len != 0) break :blk try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}", .{try bias.getNameSanitized()});
                    break :blk try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}_bias", .{out_name});
                } else try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}_bias", .{out_name});
                const mult_symbol = try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}_multiplier", .{out_name});
                const shift_symbol = try std.fmt.allocPrint(allocator, "cmsis_tensor_{s}_shift", .{out_name});

                // filter_shape is weight-keyed, tiny, and needs no flash section.
                if (!emitted.contains(shape_symbol)) {
                    try emitted.put(shape_symbol, {});
                    try writer.print(
                        \\
                        \\pub const {s} : [4]usize = [_]usize{{ {d}, {d}, {d}, {d} }};
                    , .{ shape_symbol, prepared.filter_shape[0], prepared.filter_shape[1], prepared.filter_shape[2], prepared.filter_shape[3] });
                }

                try emitCmsisArray(writer, &emitted, filter_symbol, i8, "i8", section, prepared.filter_s8);
                try emitCmsisArray(writer, &emitted, bias_symbol, i32, "i32", section, prepared.bias_i32);
                try emitCmsisArray(writer, &emitted, mult_symbol, i32, "i32", section, prepared.multipliers);
                try emitCmsisArray(writer, &emitted, shift_symbol, i32, "i32", section, prepared.shifts);
            },
            else => {},
        }
    }
}

/// Emits one `pub const <symbol> : [N]T linksection(...) = [_]T{...};` array,
/// skipping it if a constant with that name was already written this pass.
fn emitCmsisArray(
    writer: *std.Io.Writer,
    emitted: *std.StringHashMap(void),
    symbol: []const u8,
    comptime T: type,
    type_name: []const u8,
    section: []const u8,
    data: []const T,
) !void {
    if (emitted.contains(symbol)) return;
    try emitted.put(symbol, {});

    try writer.print(
        \\
        \\pub const {s} : [{d}]{s} linksection("{s}") = [_]{s}{{
    , .{ symbol, data.len, type_name, section, type_name });
    try writeArrayData(writer, T, data);
    try writer.print(
        \\}} ;
    , .{});
}

/// Writes the required library imports to the generated Zig file for input tensor.
///
/// This function ensures that the necessary standard and package libraries are
/// imported into the generated Zig source file.
///
/// # Parameters
/// - `writer`: A file writer used to write the import statements.
///
/// # Errors
/// This function may return an error if writing to the file fails.
fn write_libraries_parameters(writer: *std.Io.Writer) !void {
    _ = try writer.print(
        \\
        \\ const std = @import("std");
        \\ const IR_zant = @import("IR_zant");
        \\ const Tensor = IR_zant.core.tensor.Tensor;
        \\ const pkgAllocator = IR_zant.pkg_allocator;
        \\ const allocator = pkgAllocator.allocator;
        \\
    , .{});
}

/// Writes the shape array for a tensor initializer.
///
/// - `writer`: The file writer to output generated code.
/// - `t`: The tensor initializer.
/// - `name`: The sanitized name of the tensor.
pub inline fn writeTensorShape(writer: *std.Io.Writer, tz: *TensorZant) !void {
    try writer.print(
        \\
        \\
        \\const shape_tensor_{s} : [{}]usize = [_]usize{{
    , .{ try tz.getNameSanitized(), tz.getShape().len });

    const shape = tz.getShape();
    for (shape, 0..) |dim, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print(" {}", .{dim});
    }

    try writer.print(
        \\}} ;
    , .{});
}

/// Writes the array for a tensor initializer based on its data type.
///
/// - `writer`: The file writer to output generated code.
/// - `tz`: The tensor initializer.
pub inline fn writeArray(writer: *std.Io.Writer, tz: *TensorZant) !void {
    // std.log.info("\n[writeArray] Processing tensor: {s}, DataType: {any}", .{ name, t.data_type });

    const name = try tz.getNameSanitized();
    const section = global_xip_config.getLinkSection();

    // Force u8 type for input zero_point tensors, but i8 for weight zero_point tensors
    const is_zero_point = std.mem.indexOf(u8, name, "zero_point") != null;
    const is_weight_zero_point = is_zero_point and std.mem.indexOf(u8, name, "const_fold_opt") != null;
    const array_type = if (is_weight_zero_point) "i8" else if (is_zero_point) "u8" else tz.ty.toString();

    try writer.print(
        \\
        \\const array_{s} : [{d}]{s} linksection("{s}") = [_]{s}{{
    , .{ name, tz.getSize(), array_type, section, array_type });

    if (is_zero_point) {
        if (is_weight_zero_point) {
            // For weight zero_point tensors, convert data to i8
            switch (tz.ty) {
                .i32 => {
                    const i32_data = tz.ptr.?.get_data_as(i32);
                    var i8_data = try allocator.alloc(i8, i32_data.len);
                    defer allocator.free(i8_data);
                    for (i32_data, 0..) |val, i| {
                        i8_data[i] = @intCast(@max(-128, @min(127, val))); // Clamp to i8 range
                    }
                    try writeArrayData(writer, i8, i8_data);
                },
                .i8 => try writeArrayData(writer, i8, tz.ptr.?.get_data_as(i8)),
                else => {
                    std.debug.print("Unsupported weight zero_point type: {any}\n", .{tz.ty});
                    return error.UnsupportedWeightZeroPointType;
                },
            }
        } else {
            // For input zero_point tensors, convert data to u8 (existing logic)
            switch (tz.ty) {
                .i32 => {
                    const i32_data = tz.ptr.?.get_data_as(i32);
                    var u8_data = try allocator.alloc(u8, i32_data.len);
                    defer allocator.free(u8_data);
                    for (i32_data, 0..) |val, i| {
                        u8_data[i] = @intCast(@max(0, @min(255, val))); // Clamp to u8 range
                    }
                    try writeArrayData(writer, u8, u8_data);
                },
                .i8 => {
                    const i8_data = tz.ptr.?.get_data_as(i8);
                    var u8_data = try allocator.alloc(u8, i8_data.len);
                    defer allocator.free(u8_data);
                    for (i8_data, 0..) |val, i| {
                        u8_data[i] = @intCast(@max(0, @min(255, @as(i32, val) + 128))); // Convert i8 to u8 range
                    }
                    try writeArrayData(writer, u8, u8_data);
                },
                .u8 => try writeArrayData(writer, u8, tz.ptr.?.get_data_as(u8)),
                else => {
                    std.debug.print("Unsupported input zero_point type: {any}\n", .{tz.ty});
                    return error.UnsupportedInputZeroPointType;
                },
            }
        }
    } else {
        switch (tz.ty) {
            .f16 => writeArrayData(writer, f16, tz.ptr.?.get_data_as(f16)) catch return error.f14DataUnavailable,
            .f32 => writeArrayData(writer, f32, tz.ptr.?.get_data_as(f32)) catch return error.f32DataUnavailable,
            .f64 => writeArrayData(writer, f64, tz.ptr.?.get_data_as(f64)) catch return error.f64DataUnavailable,
            .i4 => writeArrayData(writer, i4, tz.ptr.?.get_data_as(i4)) catch return error.i4DataUnavailable,
            .i8 => writeArrayData(writer, i8, tz.ptr.?.get_data_as(i8)) catch return error.i8DataUnavailable,
            .i16 => writeArrayData(writer, i16, tz.ptr.?.get_data_as(i16)) catch return error.i16DataUnavailable,
            .i32 => writeArrayData(writer, i32, tz.ptr.?.get_data_as(i32)) catch return error.i32DataUnavailable,
            .i64 => writeArrayData(writer, i64, tz.ptr.?.get_data_as(i64)) catch return error.i64DataUnavailable,
            .u4 => writeArrayData(writer, u4, tz.ptr.?.get_data_as(u4)) catch return error.u4DataUnavailable,
            .u8 => writeArrayData(writer, u8, tz.ptr.?.get_data_as(u8)) catch return error.u8DataUnavailable,
            .u16 => writeArrayData(writer, u16, tz.ptr.?.get_data_as(u16)) catch return error.u16DataUnavailable,
            .u32 => writeArrayData(writer, u32, tz.ptr.?.get_data_as(u32)) catch return error.u32DataUnavailable,
            .u64 => writeArrayData(writer, u64, tz.ptr.?.get_data_as(u64)) catch return error.u64DataUnavailable,
            .bool => writeArrayData(writer, bool, tz.ptr.?.get_data_as(bool)) catch return error.boolDataUnavailable,
            .undefined => return error.UndefinedTensorType,
        }
    }

    try writer.print(
        \\}} ;
    , .{});
}

/// Writes the array data for a given type and data slice.
///
/// - `writer`: The file writer to output generated code.
/// - `T`: The data type of the array elements.
/// - `data`: The slice of data to write.
pub inline fn writeArrayData(writer: *std.Io.Writer, comptime T: type, data: []const T) !void {
    for (data, 0..) |value, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print(" {}", .{value});
    }
}
