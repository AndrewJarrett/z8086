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

const effAddrCalc = [8][]const u8{ "bx + si", "bx + di", "bp + si", "bp + di", "si", "di", "bp", "bx" };

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
    var opcode = try reader.readBits(u8, 3, &bits);
    std.log.debug("opcode: {b}, bits: {d}", .{ opcode, bits });

    // Start with first 3 bits of opcode
    while (bits > 0) : (opcode = try reader.readBits(u8, 3, &bits)) {
        var i: u3 = 0;
        // Check until the end of the byte until we match an opcode
        while (i <= 5) : (i += 1) {
            std.debug.print("\ni: {d}, opcode: {b}", .{ i, opcode });
            switch (i) {
                0 => {},
                1 => {
                    switch (opcode) {
                        // mov - immediate to register
                        0b1011 => {
                            const w = try reader.readBits(u1, 1, &bits);
                            const reg = try reader.readBits(u3, 3, &bits);
                            const data: i16 = data: {
                                const lowByte = try reader.readBits(i8, 8, &bits);
                                if (w == 0) {
                                    if (lowByte >= 0) {
                                        break :data lowByte;
                                    } else {
                                        // Do sign extension
                                        const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                        const highByte: u16 = 0xFF00;
                                        break :data @bitCast(highByte | lowByteUnsigned);
                                    }
                                } else {
                                    const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                    const highByte = try reader.readBits(u16, 8, &bits);
                                    break :data @bitCast(@shlExact(highByte, 8) | lowByteUnsigned);
                                }
                            };
                            std.debug.print("opcode (mov): {b}, w: {b}, reg: {b:0>3}, data: {b:0>16} / {d}", .{
                                opcode,
                                w,
                                reg,
                                data,
                                data,
                            });
                            const destReg = regTable[w][reg];
                            try src.writer().print("mov {s}, {d}\n", .{ destReg, data });
                            break;
                        },
                        else => {},
                    }
                },
                2 => {},
                3 => {
                    //std.debug.print("Testing i = 3; opcode: {b}; opcode == 0b100010?: {}", .{ opcode, (opcode == 0b100010) });
                    switch (opcode) {
                        0b100010 => {
                            const d = try reader.readBits(u1, 1, &bits);
                            const w = try reader.readBits(u1, 1, &bits);
                            const mod = try reader.readBits(u2, 2, &bits);
                            const reg = try reader.readBits(u3, 3, &bits);
                            const rm = try reader.readBits(u3, 3, &bits);
                            std.debug.print("opcode (mov): {b}, d: {b}, w: {b}, mod: {b:0>2}, reg: {b:0>3}, rm: {b:0>3}", .{
                                opcode,
                                d,
                                w,
                                mod,
                                reg,
                                rm,
                            });

                            switch (mod) {
                                0b00 => {
                                    // Memory mode, no displacement
                                    const destOrSource = regTable[w][reg];

                                    if (rm == 0b110) {
                                        // For rm = 110, then load direct address
                                        const direct: i16 = data: {
                                            const lowByte = try reader.readBits(u16, 8, &bits);
                                            const highByte = try reader.readBits(u16, 8, &bits);
                                            break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                        };
                                        if (d == 0b1) {
                                            try src.writer().print("mov {s}, [{d}]\n", .{ destOrSource, direct });

                                        } else {
                                            try src.writer().print("mov {d}, {s}\n", .{ direct, destOrSource });
                                        }
                                    } else {
                                        const effecAddrCalc = effAddrCalc[rm];

                                        if (d == 0b1) {

                                            try src.writer().print("mov {s}, [{s}]\n", .{ destOrSource, effecAddrCalc });
                                        } else {
                                            try src.writer().print("mov [{s}], {s}\n", .{ effecAddrCalc, destOrSource });
                                        }
                                    }

                                },
                                0b01 => {
                                    // Memory mode, 8 bit displacement
                                    const destOrSource = regTable[w][reg];
                                    const effecAddrCalc = effAddrCalc[rm];
                                    const disp = try reader.readBits(i8, 8, &bits);
                                    const sign = if (disp > 0) "+" else "-";
                                    if (disp != 0) {
                                        if (d == 0b1) {
                                            try src.writer().print("mov {s}, [{s} {s} {d}]\n", .{ destOrSource, effecAddrCalc, sign, @abs(disp) });
                                        } else {
                                            try src.writer().print("mov [{s} {s} {d}], {s}\n", .{ effecAddrCalc, sign, @abs(disp), destOrSource });
                                        }
                                    } else {
                                        if (d == 0b1) {
                                            try src.writer().print("mov {s}, [{s}]\n", .{ destOrSource, effecAddrCalc });
                                        } else {
                                            try src.writer().print("mov [{s}], {s}\n", .{ effecAddrCalc, destOrSource });
                                        }
                                    }
                                },
                                0b10 => {
                                    // Memory mode, 16-bit / word displacement
                                    const destOrSource = regTable[w][reg];
                                    const effecAddrCalc = effAddrCalc[rm];
                                    const disp: i16 = word: {
                                        const lowByte = try reader.readBits(u16, 8, &bits);
                                        const highByte = try reader.readBits(u16, 8, &bits);
                                        break :word @bitCast(@shlExact(highByte, 8) | lowByte);
                                    };
                                    const sign = if (disp > 0) "+" else "-";

                                    if (d == 0b1) {
                                        try src.writer().print("mov {s}, [{s} {s} {d}]\n", .{ destOrSource, effecAddrCalc, sign, @abs(disp) });
                                    } else {
                                        try src.writer().print("mov [{s} {s} {d}], {s}\n", .{ effecAddrCalc, sign, @abs(disp), destOrSource });
                                    }
                                },
                                0b11 => {
                                    // Register to register mov
                                    const destOrSource = if (d == 0b1) regTable[w][reg] else regTable[w][rm];
                                    const srcReg = if (d == 0b1) regTable[w][rm] else regTable[w][reg];
                                    try src.writer().print("mov {s}, {s}\n", .{ destOrSource, srcReg });
                                },
                            }
                            break;
                        },
                        else => {},
                    }
                },
                4 => {
                    switch(opcode) {
                        0b1010000 => {
                            // mov - memory to accumulator
                            const w = try reader.readBits(u1, 1, &bits);
                            const data: i16 = data: {
                                const lowByte = try reader.readBits(i8, 8, &bits);
                                if (w == 0) {
                                    if (lowByte >= 0) {
                                        break :data lowByte;
                                    } else {
                                        // Do sign extension
                                        const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                        const highByte: u16 = 0xFF00;
                                        break :data @bitCast(highByte | lowByteUnsigned);
                                    }
                                } else {
                                    const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                    const highByte = try reader.readBits(u16, 8, &bits);
                                    break :data @bitCast(@shlExact(highByte, 8) | lowByteUnsigned);
                                }
                            };
                            std.debug.print("opcode (mov): {b}, w: {b}, data: {d}", .{
                                opcode, w, data
                            });
                            try src.writer().print("mov ax, [{d}]\n", .{ data });
                            break;
                        },
                        0b1010001 => {
                            // mov - accumulator to memory
                            const w = try reader.readBits(u1, 1, &bits);
                            const data: i16 = data: {
                                const lowByte = try reader.readBits(i8, 8, &bits);
                                if (w == 0) {
                                    if (lowByte >= 0) {
                                        break :data lowByte;
                                    } else {
                                        // Do sign extension
                                        const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                        const highByte: u16 = 0xFF00;
                                        break :data @bitCast(highByte | lowByteUnsigned);
                                    }
                                } else {
                                    const lowByteUnsigned: u16 = @as(u8, @bitCast(lowByte));
                                    const highByte = try reader.readBits(u16, 8, &bits);
                                    break :data @bitCast(@shlExact(highByte, 8) | lowByteUnsigned);
                                }
                            };
                            std.debug.print("opcode (mov): {b}, w: {b}, data: {d}", .{
                                opcode, w, data
                            });
                            try src.writer().print("mov [{d}], ax\n", .{ data });
                            break;
                        },
                        0b1100011 => {
                            // mov - immediate to register/memory
                            const w = try reader.readBits(u1, 1, &bits);
                            const mod = try reader.readBits(u2, 2, &bits);
                            _ = try reader.readBits(u3, 3, &bits);
                            const rm = try reader.readBits(u3, 3, &bits);
                            const effecAddrCalc = effAddrCalc[rm];
                            const byteOrWord: []const u8 = if (w == 0) "byte" else "word";

                            std.debug.print("opcode (mov): {b}, w: {b}, mod: {b:0>2}, rm: {b:0>3}, effecAddrCalc: {s}, byteOrWord: {s}\n", .{
                                opcode, w, mod, rm, effecAddrCalc, byteOrWord,
                            });

                            switch (mod) {
                                0b00 => {
                                    // memory mode, no displacement
                                    if (rm == 0b110) {
                                        // For rm = 110, then load direct address
                                        const direct: i16 = data: {
                                            const lowByte = try reader.readBits(u16, 8, &bits);
                                            const highByte = try reader.readBits(u16, 8, &bits);
                                            break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                        };
                                        try src.writer().print("mov [{s}], [{d}]\n", .{ effecAddrCalc, direct });
                                    } else {
                                        const data: i16 = data: {
                                            const lowByte = try reader.readBits(u16, 8, &bits);
                                            const highByte = if (w == 0) 0 else try reader.readBits(u16, 8, &bits);
                                            break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                        };

                                        try src.writer().print("mov [{s}], {s} {d}\n", .{ effecAddrCalc, byteOrWord, data  });
                                    }
                                },
                                0b01 => {
                                    // memory mode, 8-bit displacement
                                    const disp: i16 = try reader.readBits(i8, 8, &bits);
                                    const sign = if (disp > 0) "+" else "-";
                                    const data: i16 = data: {
                                        const lowByte = try reader.readBits(u16, 8, &bits);
                                        const highByte = if (w == 0) 0 else try reader.readBits(u16, 8, &bits);
                                        break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                    };
                                    try src.writer().print("mov [{s} {s} {d}], {s} {d}\n", .{
                                        effecAddrCalc, sign, disp, byteOrWord, data
                                    });
                                },
                                0b10 => {
                                    // memory mode, 16-bit displacement
                                    const disp: i16 = disp: {
                                        const lowByte = try reader.readBits(u16, 8, &bits);
                                        const highByte = try reader.readBits(u16, 8, &bits);
                                        break :disp @bitCast(@shlExact(highByte, 8) | lowByte);
                                    };
                                    const sign = if (disp > 0) "+" else "-";
                                    const data: i16 = data: {
                                        const lowByte = try reader.readBits(u16, 8, &bits);
                                        const highByte = if (w == 0) 0 else try reader.readBits(u16, 8, &bits);
                                        break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                    };
                                    try src.writer().print("mov [{s} {s} {d}], {s} {d}\n", .{
                                        effecAddrCalc, sign, disp, byteOrWord, data
                                    });
                                },
                                0b11 => {
                                    // Register mode, no displacement
                                    const data: i16 = data: {
                                        const lowByte = try reader.readBits(u16, 8, &bits);
                                        const highByte = if (w == 0) 0 else try reader.readBits(u16, 8, &bits);
                                        break :data @bitCast(@shlExact(highByte, 8) | lowByte);
                                    };
                                    try src.writer().print("mov [{s}], {s} {d}\n", .{
                                        effecAddrCalc, byteOrWord, data
                                    });
                                }
                            }
                            break;
                        },
                        else => {},
                    }
                },
                5 => {},
                else => {
                    @panic("Should not have iterated past 8 bits");
                },
            }

            if (i >= 5) {
                std.debug.print("Unknown instruction!\n", .{});
                break;
            } else {
                // Update opcode
                opcode = (opcode << 1) + (try reader.readBits(u1, 1, &bits));
            }
        }
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

test "listing_0039_more_movs" {
    const expected = @embedFile("listings/listing_0039_more_movs-expected.asm");

    const allocator = std.testing.allocator;
    var dasm = Self.init(allocator);
    defer dasm.deinit();

    // Disassemble the binary
    const src = try dasm.disassemble("src/listings/listing_0039_more_movs") orelse "";
    try std.testing.expectEqualStrings(expected, src);
}

test "listing_0040_more_movs" {
    const expected = @embedFile("listings/listing_0040_challenge_movs-expected.asm");

    const allocator = std.testing.allocator;
    var dasm = Self.init(allocator);
    defer dasm.deinit();

    // Disassemble the binary
    const src = try dasm.disassemble("src/listings/listing_0040_challenge_movs") orelse "";
    try std.testing.expectEqualStrings(expected, src);
}
