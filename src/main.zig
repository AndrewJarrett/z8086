const std = @import("std");
const ArgIterator = std.process.ArgIterator;

const Args = enum {
    d,
    disassemble,
    a,
    assemble,
    h,
    help,
};

pub fn main() !void {
    // Get buffered writer
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    var writer = bw.writer();

    const helpText =
        \\Usage: z8086 [(-d|--disassemble) [input]] [(-a|--assemble) [input]] [-h|--help]
        \\Please specify one of the following commands:
        \\  -d [input], --disassemble [input]       Disassembles the given binary file into 8086 assembly code
        \\  -a [input], --assemble [input]          Assembles a given 8086 assembler file into a binary file according to the 8086 specification
        \\  -h, --help                              This help text
        \\
    ;

    const allocator = std.heap.page_allocator;
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();

    // The first argument for POSIX is the command name, skip it
    switch (@TypeOf(iter.inner)) {
        std.process.ArgIteratorPosix => _ = iter.next(),
        else => {},
    }

    // Parse arguments
    var isError = true;
    while (iter.next()) |arg| {
        var output: [1024]u8 = undefined;
        const size = std.mem.replace(u8, arg, "-", "", output[0..]);
        const argNoHyphens = output[0 .. arg.len - size];

        switch (std.meta.stringToEnum(Args, argNoHyphens) orelse break) {
            .d, .disassemble => {
                try writer.print("Disassemble what?\n", .{});
                isError = false;
            },
            .a, .assemble => {
                try writer.print("Assemble what?\n", .{});
                isError = false;
            },
            else => break,
        }
    }

    // Display help text if there was any error or no arguments provided
    if (isError) try writer.print(helpText, .{});

    try bw.flush();
}

test "listing_0037_single_register_mov" {
    const bin = @embedFile("listing/listing_0037_single_register_mov");
    const expected = @embedFile("listing/listing_0037_single_register_mov-expected.asm");

    const src = bin; // Disassemble the binary
    try std.testing.expectEqualStrings(src, expected);
}
