//! Generic CMSIS-NN parameter-codegen capabilities.
//!
//! Operators opt into CMSIS parameter preparation by declaring three methods:
//! `cmsis_is_supported`, `cmsis_collect_replaced_initializers`, and
//! `cmsis_write_prepared_parameters`. The union dispatch below discovers those
//! methods at compile time, so adding another CMSIS-enabled operator does not
//! require another branch in the global parameter writer.

const std = @import("std");

pub const ReplacementCollector = struct {
    names: *std.StringHashMap(void),

    pub fn addTensor(self: *ReplacementCollector, tensor: anytype) !void {
        try self.names.put(try tensor.getNameSanitized(), {});
    }
};

pub const ParameterEmitter = struct {
    writer: *std.Io.Writer,
    allocator: *const std.mem.Allocator,
    section: []const u8,
    emitted: std.StringHashMap(void),

    pub fn init(
        writer: *std.Io.Writer,
        allocator: *const std.mem.Allocator,
        section: []const u8,
    ) ParameterEmitter {
        return .{
            .writer = writer,
            .allocator = allocator,
            .section = section,
            .emitted = std.StringHashMap(void).init(allocator.*),
        };
    }

    pub fn deinit(self: *ParameterEmitter) void {
        var key_it = self.emitted.keyIterator();
        while (key_it.next()) |key| self.allocator.free(key.*);
        self.emitted.deinit();
    }

    pub fn emitShape4(self: *ParameterEmitter, symbol: []const u8, shape: [4]usize) !void {
        if (self.emitted.contains(symbol)) return;
        const owned_symbol = try self.allocator.dupe(u8, symbol);
        errdefer self.allocator.free(owned_symbol);
        try self.emitted.put(owned_symbol, {});

        try self.writer.print(
            \\
            \\pub const {s} : [4]usize = [_]usize{{ {d}, {d}, {d}, {d} }};
        , .{ symbol, shape[0], shape[1], shape[2], shape[3] });
    }

    pub fn emitArray(
        self: *ParameterEmitter,
        symbol: []const u8,
        comptime T: type,
        data: []const T,
    ) !void {
        if (self.emitted.contains(symbol)) return;
        const owned_symbol = try self.allocator.dupe(u8, symbol);
        errdefer self.allocator.free(owned_symbol);
        try self.emitted.put(owned_symbol, {});

        const type_name = @typeName(T);
        try self.writer.print(
            \\
            \\pub const {s} : [{d}]{s} linksection("{s}") = [_]{s}{{
        , .{ symbol, data.len, type_name, self.section, type_name });

        for (data, 0..) |value, index| {
            if (index > 0) try self.writer.print(",", .{});
            try self.writer.print(" {}", .{value});
        }

        try self.writer.print(
            \\}} ;
        , .{});
    }
};

/// Returns whether an operator payload exposes and accepts the CMSIS parameter
/// preparation capability.
pub fn isSupported(node: anytype) bool {
    return switch (node.op) {
        inline else => |op| blk: {
            const Op = @TypeOf(op);
            if (comptime @hasDecl(Op, "cmsis_is_supported")) {
                break :blk op.cmsis_is_supported();
            }
            break :blk false;
        },
    };
}

/// Builds the set of original initializers that can safely be omitted because
/// all of their graph uses are replaced by prepared CMSIS constants.
pub fn collectExcludedInitializers(
    excluded: *std.StringHashMap(void),
    nodes: anytype,
    allocator: *const std.mem.Allocator,
) !void {
    var candidates = std.StringHashMap(void).init(allocator.*);
    defer candidates.deinit();
    var protected = std.StringHashMap(void).init(allocator.*);
    defer protected.deinit();

    for (nodes) |node| {
        var replaced = std.StringHashMap(void).init(allocator.*);
        defer replaced.deinit();

        if (isSupported(node.*)) {
            var collector = ReplacementCollector{ .names = &replaced };
            try collectReplacedForNode(node.*, &collector);

            var replaced_it = replaced.keyIterator();
            while (replaced_it.next()) |name| try candidates.put(name.*, {});
        }

        const inputs = node.get_input_tensors() catch continue;
        for (inputs) |tensor| {
            const name = try tensor.getNameSanitized();
            if (!replaced.contains(name)) try protected.put(name, {});
        }
    }

    var candidate_it = candidates.keyIterator();
    while (candidate_it.next()) |name| {
        if (!protected.contains(name.*)) try excluded.put(name.*, {});
    }
}

/// Emits prepared constants for every node that exposes the optional CMSIS
/// parameter hook.
pub fn emitPreparedParameters(
    writer: *std.Io.Writer,
    nodes: anytype,
    allocator: *const std.mem.Allocator,
    section: []const u8,
) !void {
    var emitter = ParameterEmitter.init(writer, allocator, section);
    defer emitter.deinit();

    for (nodes) |node| {
        if (!isSupported(node.*)) continue;
        try emitPreparedForNode(node.*, &emitter);
    }
}

fn collectReplacedForNode(node: anytype, collector: *ReplacementCollector) !void {
    switch (node.op) {
        inline else => |op| {
            const Op = @TypeOf(op);
            if (comptime @hasDecl(Op, "cmsis_collect_replaced_initializers")) {
                try op.cmsis_collect_replaced_initializers(collector);
            }
        },
    }
}

fn emitPreparedForNode(node: anytype, emitter: *ParameterEmitter) !void {
    switch (node.op) {
        inline else => |op| {
            const Op = @TypeOf(op);
            if (comptime @hasDecl(Op, "cmsis_write_prepared_parameters")) {
                try op.cmsis_write_prepared_parameters(emitter);
            }
        },
    }
}

const TestTensor = struct {
    name: []const u8,

    fn getNameSanitized(self: *TestTensor) ![]const u8 {
        return self.name;
    }
};

const TestSupportedOp = struct {
    enabled: bool,
    replaced: *TestTensor,

    pub fn cmsis_is_supported(self: TestSupportedOp) bool {
        return self.enabled;
    }

    pub fn cmsis_collect_replaced_initializers(self: TestSupportedOp, collector: anytype) !void {
        try collector.addTensor(self.replaced);
    }
};

const TestUnsupportedOp = struct {};

const TestOp = union(enum) {
    supported: TestSupportedOp,
    unsupported: TestUnsupportedOp,
};

const TestNode = struct {
    op: TestOp,
    inputs: []*TestTensor,

    fn get_input_tensors(self: *TestNode) ![]*TestTensor {
        return self.inputs;
    }
};

test "CMSIS parameter capabilities discover hooks and skip unsupported operators" {
    var tensor = TestTensor{ .name = "weight" };
    const supported = TestNode{
        .op = .{ .supported = .{ .enabled = true, .replaced = &tensor } },
        .inputs = &.{&tensor},
    };
    const disabled = TestNode{
        .op = .{ .supported = .{ .enabled = false, .replaced = &tensor } },
        .inputs = &.{&tensor},
    };
    const unsupported = TestNode{
        .op = .{ .unsupported = .{} },
        .inputs = &.{&tensor},
    };

    try std.testing.expect(isSupported(supported));
    try std.testing.expect(!isSupported(disabled));
    try std.testing.expect(!isSupported(unsupported));
}

test "CMSIS replacement collection protects initializers with unreplaced uses" {
    const allocator = std.testing.allocator;
    var shared = TestTensor{ .name = "shared_weight" };
    var private = TestTensor{ .name = "private_weight" };

    var first_inputs = [_]*TestTensor{&shared};
    var second_inputs = [_]*TestTensor{ &shared, &private };
    var first = TestNode{
        .op = .{ .supported = .{ .enabled = true, .replaced = &shared } },
        .inputs = &first_inputs,
    };
    var second = TestNode{
        .op = .{ .supported = .{ .enabled = true, .replaced = &private } },
        .inputs = &second_inputs,
    };
    var nodes = [_]*TestNode{ &first, &second };

    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    try collectExcludedInitializers(&excluded, &nodes, &allocator);

    try std.testing.expect(!excluded.contains("shared_weight"));
    try std.testing.expect(excluded.contains("private_weight"));
}

test "CMSIS parameter emitter isolates output-keyed symbols and deduplicates exact symbols" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var emitter = ParameterEmitter.init(&output.writer, &allocator, ".rodata");
    defer emitter.deinit();

    try emitter.emitArray("cmsis_output_a_filter", i8, &.{ 1, 2 });
    try emitter.emitArray("cmsis_output_b_filter", i8, &.{ 3, 4 });
    try emitter.emitArray("cmsis_output_a_filter", i8, &.{ 9, 9 });

    const written = output.written();
    try std.testing.expect(std.mem.count(u8, written, "pub const cmsis_output_a_filter") == 1);
    try std.testing.expect(std.mem.count(u8, written, "pub const cmsis_output_b_filter") == 1);
    try std.testing.expect(std.mem.indexOf(u8, written, " 9") == null);
}
