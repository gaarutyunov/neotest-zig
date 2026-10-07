const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

extern "kernel32" fn SetStdHandle(nStdHandle: windows.DWORD, hHandle: windows.HANDLE) callconv(windows.WINAPI) windows.BOOL;

fn setStdHandle(stdHandle: windows.DWORD, handle: windows.HANDLE) !void {
    const result = SetStdHandle(stdHandle, handle);
    if (result == 0) {
        switch (windows.kernel32.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
}

var original_std_err_handle: ?windows.HANDLE = null;

pub fn redirectStdErrToFile(io: std.Io, absolute_file_path: []const u8) !std.Io.File {
    const file = try std.Io.Dir.createFileAbsolute(io, absolute_file_path, .{});
    errdefer file.close(io);
    const handle: std.os.windows.HANDLE = @ptrCast(file.handle);

    if (original_std_err_handle == null) {
        original_std_err_handle = try windows.GetStdHandle(windows.STD_ERROR_HANDLE);
    }

    try setStdHandle(std.os.windows.STD_ERROR_HANDLE, handle);

    return file;
}

pub fn restoreStdErr(_: std.Io) !void {
    const handle = original_std_err_handle orelse return;
    try setStdHandle(std.os.windows.STD_ERROR_HANDLE, handle);
    original_std_err_handle = null;
}
