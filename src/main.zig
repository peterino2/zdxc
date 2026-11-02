//! The dxc-compatible command line: `compile` from the library, with the
//! outputs written to the files the options name.

const std = @import("std");
const Io = std.Io;
const zdxc = @import("zdxc");
const job = @import("job.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    // Streaming, not positional: `2>> log` must append.
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    defer stderr_writer.interface.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const code = if (job.find(args)) |at|
        try job.run(io, arena, args, at, runCommandLine, &stdout_writer.interface, &stderr_writer.interface)
    else
        runCommandLine(io, arena, args, &stdout_writer.interface, &stderr_writer.interface);
    try stdout_writer.interface.flush();
    return code;
}

/// Runs one command line (argv[0] first) and returns its exit code, which
/// follows dxc: 1 for command-line and I/O errors, 5 when the compilation
/// reports errors.
fn runCommandLine(io: Io, arena: std.mem.Allocator, argv: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) u8 {
    return runOrFail(io, arena, argv, stdout, stderr) catch |err| {
        stderr.print("zdxc: error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        return 1;
    };
}

fn runOrFail(io: Io, arena: std.mem.Allocator, argv: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const args = try arena.alloc([]const u8, argv.len -| 1);
    for (args, argv[1..]) |*a, v| a.* = v;
    const r = try zdxc.compile.compile(arena, .{
        .args = args,
        .io = io,
        .color = Io.File.stderr().supportsAnsiEscapeCodes(io) catch false,
        .require_output = true,
    });
    try stdout.writeAll(r.text);
    try stderr.writeAll(r.diagnostics);
    try stderr.flush();
    if (r.status != .ok) return @intFromEnum(r.status);
    if (r.object) |bytes| try write(io, stderr, r.object_name.?, bytes) orelse return 1;
    if (r.root_signature) |bytes| try write(io, stderr, r.root_signature_name.?, bytes) orelse return 1;
    if (r.preprocessed) |text| {
        if (r.preprocessed_name) |path| try write(io, stderr, path, text) orelse return 1 else try stdout.writeAll(text);
    }
    return 0;
}

/// Writes an output file; null (after an error message) if it cannot.
fn write(io: Io, stderr: *Io.Writer, path: []const u8, bytes: []const u8) !?void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        try stderr.print("zdxc: error: cannot write '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return null;
    };
}
