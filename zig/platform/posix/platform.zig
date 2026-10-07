const std = @import("std");

var original_stderr: ?std.posix.fd_t = null;

fn duplicateToStderr(source: std.posix.fd_t) !void {
    try std.Io.Threaded.dup2(source, std.posix.STDERR_FILENO);
}

pub fn redirectStdErrToFile(io: std.Io, absolute_file_path: []const u8) !std.Io.File {
    const file = try std.Io.Dir.createFileAbsolute(io, absolute_file_path, .{});
    errdefer file.close(io);
    if (original_stderr == null) {
        const result = std.posix.system.dup(std.posix.STDERR_FILENO);
        const err = std.posix.errno(result);
        if (err != .SUCCESS) return std.posix.unexpectedErrno(err);
        original_stderr = @intCast(result);
    }
    try duplicateToStderr(file.handle);
    return file;
}

pub fn restoreStdErr(io: std.Io) !void {
    const saved = original_stderr orelse return;
    try duplicateToStderr(saved);
    original_stderr = null;
    const file: std.Io.File = .{ .handle = saved, .flags = .{ .nonblocking = false } };
    file.close(io);
}
