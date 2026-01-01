# SidXPort

Command-line tool for converting Commodore 64 SID music files to WAV audio or register dumps.

## Building

Requires Zig 0.15+.

```bash
zig build
```

## Usage

```
sidxport <SID file> <output file> <frames> [options]

Required arguments:
  <SID file>      Path to input .sid file
  <output file>   Path for output file (.wav, .dmp, or .csv)
  <frames>        Number of frames to render (50 frames = 1 second)

Output format options (default: binary register dump):
  --wav-stereo    Export as stereo WAV
  --wav-mono      Export as mono WAV
  --csv-dec       Output as CSV with decimal values
  --csv-hex       Output as CSV with hexadecimal values

Other options:
  --debug         Print register values for each frame
  --help, -h      Show this help message
```

By default, sidxport creates a binary register dump. Use `--wav-*` or `--csv-*` options to select a different output format.

## Example

```bash
$ ./zig-out/bin/sidxport Cybernoid_II.sid cybernoid.wav 10000 --wav-stereo
[SidXPort] loading Sid file 'Cybernoid_II.sid'
[SidXPort] Loaded SID file successfully!
[sidfile] Loaded Sid tune: Cybernoid II
[sidfile] Author         : Maniacs of Noise
[sidfile] Release Info   : 1988 Hewson
[SidXPort] calling sid init()
[SidXPort] looping sid play()
[SidXPort] converting SID to WAV: cybernoid.wav
[SidXPort] Audio Length 200s
[SidXPort] Steps rendered 9999
```
