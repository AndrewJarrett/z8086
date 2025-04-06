const std = @import("std");
const fs = std.fs;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;
const BufferedWriter = std.io.BufferedWriter;
const File = fs.File;
const OpenError = fs.File.OpenError;
const Self = @This();

allocator: Allocator,
src: []u8 = undefined,
file: ?File = undefined,

const regTable = [2][8][]const u8{
    // 8 bits
    [8][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh" },
    // Wide / 16 bits
    [8][]const u8{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di" },
};

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
    //return .{ .allocator = allocator, .writer = writer };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.src);
}

pub fn disassemble(self: *Self, filename: []const u8) !?[]u8 {
    if (try self.open(filename)) |file| {
        defer file.close();
        return self.parse(filename, file) catch |err| {
            switch (err) {
                Allocator.Error.OutOfMemory => std.debug.print("you can't remember me?\n", .{}),
                else => |e| return e,
            }
            return null;
        };
    }
    return null;
}

fn open(self: Self, file: []const u8) !?File {
    _ = self;
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    var writer = bw.writer();

    return fs.cwd().openFile(file, .{}) catch |err| {
        switch (err) {
            OpenError.FileNotFound => {
                writer.print("File was not found.\n\n", .{}) catch unreachable;
                bw.flush() catch unreachable;
            },
            else => |e| return e,
        }
        return null;
    };
}

fn parse(self: *Self, filename: []const u8, file: File) ![]u8 {
    var src = ArrayList(u8).init(self.allocator);
    try src.appendSlice("; ");
    try src.appendSlice(filename);
    try src.appendSlice("\nbits 16\n");

    var br = std.io.bufferedReader(file.reader());
    var reader = std.io.bitReader(.big, br.reader());

    var bits: u16 = undefined;
    var opcode = try reader.readBits(u6, 6, &bits);
    std.log.debug("opcode: {b}, bits: {d}\n", .{ opcode, bits });

    while (bits > 0) : (opcode = try reader.readBits(u6, 6, &bits)) {
        switch (opcode) {
            // MOV
            0b100010 => {
                const d = try reader.readBits(u1, 1, &bits);
                const w = try reader.readBits(u1, 1, &bits);
                const mod = try reader.readBits(u2, 2, &bits);
                const reg = try reader.readBits(u3, 3, &bits);
                const rm = try reader.readBits(u3, 3, &bits);
                std.log.debug("opcode (mov): {b}, d: {b}, w: {b}, mod: {b}, reg: {b}, rm: {b}\n", .{
                    opcode,
                    d,
                    w,
                    mod,
                    reg,
                    rm,
                });

                switch (mod) {
                    0b11 => {
                        // Register to register mov
                        const destReg = if (d == 0b1) regTable[w][reg] else regTable[w][rm];
                        const srcReg = if (d == 0b1) regTable[w][rm] else regTable[w][reg];
                        try src.writer().print("mov {s}, {s}", .{ destReg, srcReg });
                    },
                    else => std.debug.print("Unhandled mode!\n", .{}),
                }
            },
            else => {
                std.debug.print("Unknown instruction!\n", .{});
            },
        }
        try src.appendSlice("\n");
    }

    self.src = try src.toOwnedSlice();
    return self.src;
}

test "listing_0037_single_register_mov" {
    const expected = @embedFile("listings/listing_0037_single_register_mov-expected.asm");

    const allocator = std.testing.allocator;
    var dasm = Self.init(allocator);
    defer dasm.deinit();

    // Disassemble the binary
    const src = try dasm.disassemble("src/listings/listing_0037_single_register_mov") orelse "";
    try std.testing.expectEqualStrings(expected, src);
}

test "listing_0038_many_register_mov" {
    const expected = @embedFile("listings/listing_0038_many_register_mov-expected.asm");

    const allocator = std.testing.allocator;
    var dasm = Self.init(allocator);
    defer dasm.deinit();

    // Disassemble the binary
    const src = try dasm.disassemble("src/listings/listing_0038_many_register_mov") orelse "";
    try std.testing.expectEqualStrings(expected, src);
}
