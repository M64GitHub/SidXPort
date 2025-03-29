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

const usage_string = "Usage: sidxport <SID file> <output dump> <frames> [--debug] [--csv-dec] [--csv-hex] [--wav <wavfile>] [--wav-mono] [--wav-stereo]\n";

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const gpa = std.heap.page_allocator;

    // parse commandline
    const args = try parseCommandLine(gpa);

    // allocate output dump
    const dump_size = args.max_frames * 25; // 25 registers per frame
    var sid_dump = try gpa.alloc(u8, dump_size);

    // init sidfile
    var sid_file = SidFile.init();
    defer sid_file.deinit(gpa);

    // load .sid file
    try stdout.print("[SidXPort] loading Sid file '{s}'\n", .{args.sid_filename});
    if (sid_file.load(gpa, args.sid_filename)) {
        std.debug.print("[SidXPort] Loaded SID file successfully!\n", .{});
    } else |err| {
        std.debug.print("[ERROR] Failed to load SID file: {}\n", .{err});
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
            std.debug.print(
                "[SidXPort] SID binary dump saved to {s}!\n",
                .{args.output_filename},
            );
        }
    }

    // convert to wave file, and save
    if (args.wav_output) {
        std.debug.print(
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
}

fn exportWav(
    allocator: std.mem.Allocator,
    output_filename: ?[]const u8,
    sid_dump: []u8,
    max_frames: u32,
    wav_format: WavFormat,
) !void {
    var stdout = std.io.getStdOut().writer();
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

    if (args.len < 4) {
        std.debug.print(usage_string, .{});
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
            std.debug.print("Error: Unknown option {s}\n", .{args[i]});
            std.debug.print(usage_string, .{});
            return error.InvalidArguments;
        }
    }

    return parsed;
}

fn hexDumpRegisters(frame: usize, registers: []const u8) void {
    var stdout = std.io.getStdOut().writer();

    stdout.print("[{X:06}] ", .{frame}) catch return;
    for (registers) |reg| {
        stdout.print("{X:02} ", .{reg}) catch return;
    }

    stdout.print("\n", .{}) catch return;
}

fn writeCsvDump(output_filename: []const u8, sid_dump: []const u8, max_frames: usize, format: CsvFormat) !void {
    var file = try std.fs.cwd().createFile(output_filename, .{});
    defer file.close();

    // Write CSV header
    try file.writeAll("Frame, R00, R01, R02, ..., R24\n");

    // Write each frame’s registers in CSV format
    for (0..max_frames) |frame| {
        try file.writer().print("{d}, ", .{frame});
        for (0..25) |r| {
            switch (format) {
                .hex => try file.writer().print("{X:02}", .{sid_dump[frame * 25 + r]}),
                .decimal => try file.writer().print("{d}", .{sid_dump[frame * 25 + r]}),
            }
            if (r < 24) try file.writer().writeAll(", ");
        }
        try file.writer().writeAll("\n");
    }

    std.debug.print("[SidXPort] CSV dump saved to {s}!\n", .{output_filename});
}
