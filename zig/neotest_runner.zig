const std = @import("std");
const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows)
    @import("platform/windows/platform.zig")
else
    @import("platform/posix/platform.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runnerLogFn,
};

var log_level: std.log.Level = .err;
const log = std.log.scoped(.test_runner);

pub fn runnerLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .test_runner and @backingInt(level) > @backingInt(log_level)) return;
    std.debug.print("[" ++ comptime level.asText() ++ "] " ++ format ++ "\n", args);
}

const STATUS_FAILED = "failed";
const STATUS_PASSED = "passed";
const STATUS_SKIPPED = "skipped";

const NEOTEST_INPUT_PATH = "--neotest-input-path";
const NEOTEST_RESULTS_PATH = "--neotest-results-path";
const NEOTEST_SOURCE_PATH = "--neotest-source-path";
const TEST_RUNNER_LOGS_PATH = "--test-runner-logs-path";
const TEST_RUNNER_LOG_LEVEL = "--test-runner-log-level";

const TestInput = struct {
    test_name: []const u8,
    source_path: []const u8,
    output_path: []const u8,
};

const Error = struct {
    message: []const u8,
    line: ?usize,
};

const TestResult = struct {
    test_name: []const u8,
    source_path: []const u8,
    output: ?[]const u8,
    status: []const u8,
    short: ?[]const u8,
    errors: ?[]Error,
};

fn getSymbol(
    io: std.Io,
    allocator: std.mem.Allocator,
    address: usize,
) !std.debug.Symbol {
    const debug_info = try std.debug.getSelfDebugInfo();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try debug_info.getSymbols(io, allocator, allocator, address, false, &symbols);
    return if (symbols.items.len == 0) .unknown else symbols.items[0];
}

fn getTestInput(
    test_name: []const u8,
    source_path: []const u8,
    test_inputs: []TestInput,
) ?TestInput {
    log.debug("Got needle {s} -> {s}", .{ source_path, test_name });
    for (test_inputs) |test_input| {
        log.debug("Comparing to {s} -> {s}", .{ test_input.source_path, test_input.test_name });
        if (std.mem.eql(u8, test_input.test_name, test_name) and
            std.mem.eql(u8, test_input.source_path, source_path))
        {
            return test_input;
        }
    }
    return null;
}

fn getZigLogLevelFromVimLogLevel(vim_log_level: u8) std.log.Level {
    return switch (vim_log_level) {
        0, 1 => .debug,
        2 => .info,
        3 => .warn,
        4, 5 => .err,
        else => .debug,
    };
}

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    _ = &context;
    _ = testOne;
    _ = options;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn getFirstOutputLine(io: std.Io, allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return "Could not open output buffer.";
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return "Could not read output file.";
    return allocator.dupe(u8, line) catch "Could not copy output line.";
}

fn appendResult(
    allocator: std.mem.Allocator,
    results: *std.ArrayList(TestResult),
    result: TestResult,
) !void {
    try results.append(allocator, result);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var test_results: std.ArrayList(TestResult) = .empty;

    const args = try init.minimal.args.toSlice(allocator);
    var input_path: ?[]const u8 = null;
    var results_dir_path: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var logs_dir_path: ?[]const u8 = null;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, NEOTEST_INPUT_PATH) and args.len > i + 1) {
            input_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, NEOTEST_RESULTS_PATH) and args.len > i + 1) {
            results_dir_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, NEOTEST_SOURCE_PATH) and args.len > i + 1) {
            source_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, TEST_RUNNER_LOGS_PATH) and args.len > i + 1) {
            logs_dir_path = args[i + 1];
        } else if (std.mem.eql(u8, arg, TEST_RUNNER_LOG_LEVEL) and args.len > i + 1) {
            log_level = getZigLogLevelFromVimLogLevel(try std.fmt.parseInt(u8, args[i + 1], 0));
        }
    }

    const input_file_path = input_path orelse return error.MissingNeotestInputPath;
    const results_dir = results_dir_path orelse return error.MissingNeotestResultsPath;
    const logs_dir = logs_dir_path orelse return error.MissingTestRunnerLogsPath;
    const test_inputs = try std.json.parseFromSliceLeaky(
        []TestInput,
        allocator,
        try readFile(init.io, allocator, input_file_path),
        .{},
    );

    const executable_path = try std.process.executablePathAlloc(init.io, allocator);
    const logs_file_name = try std.fmt.allocPrint(allocator, "{d}", .{std.hash.Wyhash.hash(0, executable_path)});
    const logs_file_path = try std.fs.path.join(allocator, &.{ logs_dir, logs_file_name });
    const logs_file = try platform.redirectStdErrToFile(init.io, logs_file_path);
    defer logs_file.close(init.io);

    var hasher = std.hash.Wyhash.init(0);
    for (builtin.test_functions) |test_function| {
        const symbol = getSymbol(init.io, allocator, @intFromPtr(test_function.func)) catch continue;
        const symbol_name = symbol.name orelse continue;
        log.debug("Found test {s}", .{symbol_name});
        if (symbol.source_location) |location| {
            std.hash.autoHashStrat(&hasher, location.file_name, .Deep);
        }
        std.hash.autoHashStrat(&hasher, symbol_name, .Deep);
    }
    const results_file_path = try std.fs.path.join(
        allocator,
        &.{ results_dir, try std.fmt.allocPrint(allocator, "{d}", .{hasher.final()}) },
    );

    var processed_tests: usize = 0;
    for (builtin.test_functions) |test_function| {
        if (processed_tests == test_inputs.len) break;

        const symbol = getSymbol(init.io, allocator, @intFromPtr(test_function.func)) catch continue;
        const test_name = symbol.name orelse continue;
        const location = symbol.source_location orelse continue;
        const actual_source_path = source_path orelse location.file_name;
        const input = getTestInput(test_name, actual_source_path, test_inputs) orelse continue;
        processed_tests += 1;

        const output_file = try platform.redirectStdErrToFile(init.io, input.output_path);
        defer output_file.close(init.io);

        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });
        std.testing.environ = init.minimal.environ;

        const start = std.Io.Clock.awake.now(init.io);
        var result = TestResult{
            .test_name = input.test_name,
            .source_path = input.source_path,
            .output = input.output_path,
            .status = STATUS_PASSED,
            .short = null,
            .errors = null,
        };

        test_function.func() catch |err| {
            var error_line: ?usize = null;
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
                const trace_len = @min(trace.index, trace.instruction_addresses.len);
                if (trace_len > 0) {
                    const address = trace.instruction_addresses[trace_len - 1] - 1;
                    if (getSymbol(init.io, allocator, address)) |error_symbol| {
                        if (error_symbol.source_location) |error_location| {
                            error_line = error_location.line -| 1;
                        }
                    } else |_| {}
                }
            }

            result.status = if (err == error.SkipZigTest) STATUS_SKIPPED else STATUS_FAILED;
            const message = if (err == error.SkipZigTest) "Skipped" else @errorName(err);
            const short = if (err == error.SkipZigTest)
                "Skipped"
            else
                try std.fmt.allocPrint(allocator, "{s}: {s}", .{ message, getFirstOutputLine(init.io, allocator, input.output_path) });
            result.short = short;
            result.errors = try allocator.dupe(Error, &.{.{ .message = message, .line = error_line }});
        };

        std.testing.io_instance.deinit();
        const leaks = std.testing.allocator_instance.deinit();
        if (leaks != 0 and std.mem.eql(u8, result.status, STATUS_PASSED)) {
            result.status = STATUS_FAILED;
            result.short = "Memory leaked (see full output for more details)";
        }

        const duration = start.durationTo(std.Io.Clock.awake.now(init.io));
        if (std.mem.eql(u8, result.status, STATUS_PASSED)) {
            result.short = try std.fmt.allocPrint(allocator, "Test passed in {f}", .{duration});
        }
        try appendResult(allocator, &test_results, result);
    }

    try platform.restoreStdErr(init.io);
    const json = try std.json.Stringify.valueAlloc(allocator, test_results.items, .{});
    const results_file = try std.Io.Dir.createFileAbsolute(init.io, results_file_path, .{});
    defer results_file.close(init.io);
    try results_file.writeStreamingAll(init.io, json);
}
