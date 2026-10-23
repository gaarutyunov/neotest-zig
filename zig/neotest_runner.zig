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
/// Run tests in child processes, so a crashing test does not take down the others.
const NEOTEST_ISOLATE = "--neotest-isolate";
/// Index into the matched tests to start running from. Used by the isolating parent process.
const NEOTEST_START = "--neotest-start";

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

const MatchedTest = struct {
    func: *const fn () anyerror!void,
    input: TestInput,
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
    var isolate = false;
    var start_index: usize = 0;
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
        } else if (std.mem.eql(u8, arg, NEOTEST_ISOLATE)) {
            isolate = true;
        } else if (std.mem.eql(u8, arg, NEOTEST_START) and args.len > i + 1) {
            start_index = try std.fmt.parseInt(usize, args[i + 1], 10);
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
    const executable_hash = std.hash.Wyhash.hash(0, executable_path);
    const logs_file_name = if (isolate)
        try std.fmt.allocPrint(allocator, "{d}-isolate", .{executable_hash})
    else
        try std.fmt.allocPrint(allocator, "{d}-{d}", .{ executable_hash, start_index });
    const logs_file_path = try std.fs.path.join(allocator, &.{ logs_dir, logs_file_name });
    const logs_file = try platform.redirectStdErrToFile(init.io, logs_file_path);
    defer logs_file.close(init.io);

    var hasher = std.hash.Wyhash.init(0);
    var matched_tests: std.ArrayList(MatchedTest) = .empty;
    for (builtin.test_functions) |test_function| {
        const symbol = getSymbol(init.io, allocator, @intFromPtr(test_function.func)) catch continue;
        const test_name = symbol.name orelse continue;
        log.debug("Found test {s}", .{test_name});
        if (symbol.source_location) |location| {
            std.hash.autoHashStrat(&hasher, location.file_name, .Deep);
        }
        std.hash.autoHashStrat(&hasher, test_name, .Deep);

        if (matched_tests.items.len == test_inputs.len) continue;
        const location = symbol.source_location orelse continue;
        const actual_source_path = source_path orelse location.file_name;
        const input = getTestInput(test_name, actual_source_path, test_inputs) orelse continue;
        try matched_tests.append(allocator, .{ .func = test_function.func, .input = input });
    }
    const results_file_prefix = try std.fmt.allocPrint(allocator, "{d}", .{hasher.final()});
    const progress_file_path = try std.fs.path.join(
        allocator,
        &.{ logs_dir, try std.fmt.allocPrint(allocator, "{s}.progress", .{results_file_prefix}) },
    );

    if (isolate) {
        try runIsolated(init.io, allocator, args, matched_tests.items, results_dir, results_file_prefix, progress_file_path);
        try platform.restoreStdErr(init.io);
        return;
    }

    const results_file_path = try std.fs.path.join(
        allocator,
        &.{ results_dir, try std.fmt.allocPrint(allocator, "{s}-{d}", .{ results_file_prefix, start_index }) },
    );

    const first_test = @min(start_index, matched_tests.items.len);
    for (matched_tests.items[first_test..], first_test..) |matched, test_index| {
        const input = matched.input;
        // Lets the isolating parent know which test was running if this process crashes.
        try writeProgress(init.io, allocator, progress_file_path, test_index);

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

        matched.func() catch |err| {
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
        // Written after every test, so results survive if a later test crashes the process.
        try writeResults(init.io, allocator, results_file_path, test_results.items);
    }

    try platform.restoreStdErr(init.io);
    try writeResults(init.io, allocator, results_file_path, test_results.items);
}

fn writeResults(io: std.Io, allocator: std.mem.Allocator, path: []const u8, results: []const TestResult) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, results, .{});
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, json);
}

fn writeProgress(io: std.Io, allocator: std.mem.Allocator, path: []const u8, test_index: usize) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "{d}", .{test_index}));
}

fn readProgress(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?usize {
    const contents = readFile(io, allocator, path) catch return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, contents, " \n"), 10) catch null;
}

/// Runs the tests in a child process of this same executable, so that a test which
/// crashes the process (e.g. a safety-checked panic) only fails itself, like `zig build test` does.
/// After a crash, the crashed test is reported as failed and a new child resumes from the next test.
fn runIsolated(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    matched_tests: []const MatchedTest,
    results_dir: []const u8,
    results_file_prefix: []const u8,
    progress_file_path: []const u8,
) !void {
    var child_argv: std.ArrayList([]const u8) = .empty;
    try child_argv.append(allocator, try std.process.executablePathAlloc(io, allocator));
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, NEOTEST_ISOLATE)) continue;
        try child_argv.append(allocator, arg);
    }
    try child_argv.append(allocator, NEOTEST_START);
    const start_arg = child_argv.items.len;
    try child_argv.append(allocator, "0");

    var start_index: usize = 0;
    while (start_index < matched_tests.len) {
        child_argv.items[start_arg] = try std.fmt.allocPrint(allocator, "{d}", .{start_index});
        std.Io.Dir.deleteFileAbsolute(io, progress_file_path) catch {};

        log.debug("Spawning test process starting at test {d}", .{start_index});
        var child = try std.process.spawn(io, .{ .argv = child_argv.items });
        const term = try child.wait(io);
        if (term.success()) return;

        const crashed_index = readProgress(io, allocator, progress_file_path) orelse return error.TestProcessFailed;
        if (crashed_index < start_index or crashed_index >= matched_tests.len) return error.TestProcessFailed;
        const crashed_input = matched_tests[crashed_index].input;
        log.debug("Test {s} crashed: {any}", .{ crashed_input.test_name, term });

        const crash_results_path = try std.fs.path.join(
            allocator,
            &.{ results_dir, try std.fmt.allocPrint(allocator, "{s}-crash-{d}", .{ results_file_prefix, crashed_index }) },
        );
        const result = try getCrashResult(io, allocator, crashed_input, term);
        try writeResults(io, allocator, crash_results_path, &.{result});
        start_index = crashed_index + 1;
    }
}

const StackFrame = struct {
    path: []const u8,
    line: usize,
    column: usize,
    function: []const u8,
};

/// Parses a stack trace line like `/src/vm.zig:187:63: 0x10fbf4152 in step (test)`.
fn parseStackFrame(line: []const u8) ?StackFrame {
    const address_start = std.mem.indexOf(u8, line, ": 0x") orelse return null;
    const location = line[0..address_start];
    const column_sep = std.mem.lastIndexOfScalar(u8, location, ':') orelse return null;
    const line_sep = std.mem.lastIndexOfScalar(u8, location[0..column_sep], ':') orelse return null;
    const function_start = (std.mem.indexOfPos(u8, line, address_start, " in ") orelse return null) + " in ".len;
    const function_end = std.mem.lastIndexOf(u8, line, " (") orelse line.len;
    if (function_end < function_start) return null;
    return .{
        .path = location[0..line_sep],
        .line = std.fmt.parseInt(usize, location[line_sep + 1 .. column_sep], 10) catch return null,
        .column = std.fmt.parseInt(usize, location[column_sep + 1 ..], 10) catch return null,
        .function = line[function_start..function_end],
    };
}

fn stripAnsiEscapes(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var stripped: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            // Skip a CSI sequence: ESC [ parameters final-byte.
            i += 2;
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        try stripped.append(allocator, text[i]);
        i += 1;
    }
    return stripped.items;
}

/// Builds a failed result for a test that crashed the process, from the panic message
/// and stack trace it left in its output file.
fn getCrashResult(io: std.Io, allocator: std.mem.Allocator, input: TestInput, term: std.process.Child.Term) !TestResult {
    const output = readFile(io, allocator, input.output_path) catch "";
    var panic_message: ?[]const u8 = null;
    var panic_location: ?StackFrame = null;
    var error_line: ?usize = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |colored_line| {
        // Stack traces are colored when stderr was a terminal.
        const line = try stripAnsiEscapes(allocator, colored_line);
        if (panic_message == null) {
            if (std.mem.indexOf(u8, line, "panic: ")) |i| panic_message = line[i + "panic: ".len ..];
            continue;
        }
        const frame = parseStackFrame(line) orelse continue;
        if (panic_location == null) panic_location = frame;
        // The frame inside the test itself is where the diagnostic goes.
        if (error_line == null and std.mem.eql(u8, frame.function, input.test_name) and
            std.mem.eql(u8, frame.path, input.source_path))
        {
            error_line = frame.line -| 1;
        }
    }

    const message = if (panic_message) |panic| if (panic_location) |frame|
        try std.fmt.allocPrint(allocator, "panic: {s} at {s}:{d}:{d}", .{ panic, std.fs.path.basename(frame.path), frame.line, frame.column })
    else
        try std.fmt.allocPrint(allocator, "panic: {s}", .{panic})
    else switch (term) {
        .exited => |code| try std.fmt.allocPrint(allocator, "Test crashed with exit code {d}", .{code}),
        else => try std.fmt.allocPrint(allocator, "Test crashed: {any}", .{term}),
    };

    return .{
        .test_name = input.test_name,
        .source_path = input.source_path,
        .output = input.output_path,
        .status = STATUS_FAILED,
        .short = message,
        .errors = try allocator.dupe(Error, &.{.{ .message = message, .line = error_line }}),
    };
}
