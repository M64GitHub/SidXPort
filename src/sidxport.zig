const std = @import("std");
const ReSid = @import("resid");

const Sid = ReSid.Sid;
const SidFile = ReSid.SidFile;
const SidPlayer = ReSid.SidPlayer;
const DumpPlayer = ReSid.DumpPlayer;
const WavWriter = ReSid.WavWriter;

pub const CsvFormat = enum { hex, decimal };
pub const WavFormat = enum { mono, stereo };

pub const ParsedArgs = struct {
    sid_filename: []const u8,
    output_filename: []const u8,
    max_frames: u32,
    dbg_enabled: bool,
    csv_enabled: bool,
    csv_format: CsvFormat,
    wav_format: WavFormat,
    wav_output: bool,
};

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

fn printUsage() void {
    stdout.print(
        \\sidxport - Convert SID music files to WAV audio or register dumps
        \\
        \\Usage: sidxport <SID file> <output file> <frames> [options]
        \\
        \\Required arguments:
        \\  <SID file>      Path to input .sid file
        \\  <output file>   Path for output file (.wav, .dmp, or .csv)
        \\  <frames>        Number of frames to render (50 frames = 1 second)
        \\
        \\Output format options (default: binary register dump):
        \\  --wav-stereo    Export as stereo WAV
        \\  --wav-mono      Export as mono WAV
        \\  --csv-dec       Output as CSV with decimal values
        \\  --csv-hex       Output as CSV with hexadecimal values
        \\
        \\Other options:
        \\  --debug         Print register values for each frame
        \\  --help, -h      Show this help message
        \\
        \\Examples:
        \\  sidxport song.sid song.wav 3000 --wav-stereo
        \\  sidxport song.sid registers.csv 1500 --csv-hex
        \\  sidxport song.sid dump.dmp 6000 --debug
        \\
    , .{}) catch {};
    stdout.flush() catch {};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    // parse commandline
    const args = parseCommandLine(gpa) catch {
        return;
    };

    // allocate output dump
    const dump_size = args.max_frames * 25; // 25 registers per frame
    var sid_dump = try gpa.alloc(u8, dump_size);

    // init sidfile
    var sid_file = SidFile.init();
    defer sid_file.deinit(gpa);

    // load .sid file
    try stdout.print("[SidXPort] loading Sid file '{s}'\n", .{args.sid_filename});
    if (sid_file.load(gpa, args.sid_filename)) {
        try stdout.print("[SidXPort] Loaded SID file successfully!\n", .{});
    } else |err| {
        try stdout.print("[ERROR] Failed to load SID file: {}\n", .{err});
        return err;
    }

    // print file info
    try sid_file.printHeader();

    // init sidplayer
    var player = try SidPlayer.init(gpa, sid_file);

    // call sid init
    // player.c64.dbg_enabled = true;
    // player.c64.cpu_dbg_enabled = true;
    try stdout.print("[SidXPort] calling sid init()\n", .{});
    try player.sidInit(sid_file.header.start_song - 1);

    // -- loop call sid play, fill the dump

    // player.c64.sid_dbg_enabled = true;
    try stdout.print("[SidXPort] looping sid play()\n", .{});
    for (0..args.max_frames) |frame| {
        try player.sidPlay();
        const sid_registers = player.c64.sid.getRegisters();
        @memcpy(sid_dump[frame * 25 .. frame * 25 + 25], sid_registers[0..]);
        if (args.dbg_enabled)
            hexDumpRegisters(frame, &sid_registers);
    }

    // --

    // generate output
    if (args.wav_output == false) {
        if (args.csv_enabled) {
            // convert to csv file, and save
            try writeCsvDump(
                args.output_filename,
                sid_dump,
                args.max_frames,
                args.csv_format,
            );
        } else {
            // write raw dump to output file
            var file = try std.fs.cwd().createFile(args.output_filename, .{});
            defer file.close();
            try file.writeAll(sid_dump);
            try stdout.print(
                "[SidXPort] SID binary dump saved to {s}!\n",
                .{args.output_filename},
            );
        }
    }

    // convert to wave file, and save
    if (args.wav_output) {
        try stdout.print(
            "[SidXPort] converting SID to WAV: {s}\n",
            .{args.output_filename},
        );
        try exportWav(
            gpa,
            args.output_filename,
            sid_dump,
            args.max_frames,
            args.wav_format,
        );
    }
    try stdout.flush();
}

fn exportWav(
    allocator: std.mem.Allocator,
    output_filename: ?[]const u8,
    sid_dump: []u8,
    max_frames: u32,
    wav_format: WavFormat,
) !void {
    var sid = try Sid.init("zigsid#1");
    defer sid.deinit();

    _ = sid.setChipModel("MOS8580");
    var player = try DumpPlayer.init(allocator, sid);
    defer player.deinit();
    player.setDmp(sid_dump);

    const sampling_rate = 44100;
    const audio_len_float: f32 = @as(f32, @floatFromInt(sid_dump.len)) /
        25.0 / 50;
    const audio_len: usize = @intFromFloat(audio_len_float);
    try stdout.print("[SidXPort] Audio Length {d}s\n", .{audio_len});
    const pcm_buffer = try allocator.alloc(i16, sampling_rate * audio_len);
    defer allocator.free(pcm_buffer);

    const steps_rendered = player.renderAudio(0, max_frames, pcm_buffer);
    try stdout.print("[SidXPort] Steps rendered {d}\n", .{steps_rendered});

    var mywav = WavWriter.init(
        allocator,
        output_filename orelse "sidxport-out.wav",
    );
    mywav.setMonoBuffer(pcm_buffer);
    if (wav_format == .mono) {
        try mywav.writeMono();
    } else {
        try mywav.writeStereo();
    }
}

fn parseCommandLine(allocator: std.mem.Allocator) !ParsedArgs {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for --help or -h flag first
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }
    }

    if (args.len < 4) {
        printUsage();
        return error.InvalidArguments;
    }

    var parsed = ParsedArgs{
        .sid_filename = try allocator.dupe(u8, args[1]),
        .output_filename = try allocator.dupe(u8, args[2]),
        .max_frames = try std.fmt.parseInt(u32, args[3], 10),
        .dbg_enabled = false,
        .csv_enabled = false,
        .wav_output = false,
        .wav_format = .stereo,
        .csv_format = .decimal,
    };

    var i: usize = 4; // Start checking optional args
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            parsed.dbg_enabled = true;
        } else if (std.mem.eql(u8, args[i], "--csv-hex")) {
            parsed.csv_enabled = true;
            parsed.csv_format = .hex;
        } else if (std.mem.eql(u8, args[i], "--csv-dec")) {
            parsed.csv_enabled = true;
            parsed.csv_format = .decimal;
        } else if (std.mem.eql(u8, args[i], "--wav-mono")) {
            parsed.wav_format = .mono;
            parsed.wav_output = true;
        } else if (std.mem.eql(u8, args[i], "--wav-stereo")) {
            parsed.wav_format = .stereo;
            parsed.wav_output = true;
        } else {
            stdout.print("Error: Unknown option '{s}'\n\n", .{args[i]}) catch {};
            printUsage();
            return error.InvalidArguments;
        }
    }

    return parsed;
}

fn hexDumpRegisters(frame: usize, registers: []const u8) void {
    stdout.print("[{X:06}] ", .{frame}) catch return;
    for (registers) |reg| {
        stdout.print("{X:02} ", .{reg}) catch return;
    }
    stdout.print("\n", .{}) catch return;
}

fn writeCsvDump(output_filename: []const u8, sid_dump: []const u8, max_frames: usize, format: CsvFormat) !void {
    var file = try std.fs.cwd().createFile(output_filename, .{});
    defer file.close();

    // Create writer with buffer
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    const writer: *std.io.Writer = &file_writer.interface;

    // Write CSV header
    try writer.writeAll("Frame, R00, R01, R02, ..., R24\n");

    // Write each frame's registers in CSV format
    for (0..max_frames) |frame| {
        try writer.print("{d}, ", .{frame});
        for (0..25) |r| {
            switch (format) {
                .hex => try writer.print("{X:02}", .{sid_dump[frame * 25 + r]}),
                .decimal => try writer.print("{d}", .{sid_dump[frame * 25 + r]}),
            }
            if (r < 24) try writer.writeAll(", ");
        }
        try writer.writeAll("\n");
    }
    try writer.flush();

    try stdout.print("[SidXPort] CSV dump saved to {s}!\n", .{output_filename});
}
