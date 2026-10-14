import ArgumentParser
import Foundation
import JPEGLS

/// Validation error for CLI argument validation
struct ValidationError: Error, CustomStringConvertible {
    let message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    var description: String {
        message
    }
}

/// Command-line tool for JPEG-LS encoding and decoding
struct JPEGLSCLITool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jpegls",
        abstract: "JPEG-LS command-line tool for encoding and decoding",
        discussion: """
        Quick-reference cheat sheet:

          Encode a PNG to lossless JPEG-LS:
            jpegls encode input.png output.jls

          Encode raw pixels (greyscale, 8-bit, 512×512):
            jpegls encode input.raw output.jls --width 512 --height 512

          Encode with near-lossless tolerance NEAR=3:
            jpegls encode input.png output.jls --near 3

          Encode with line-interleaved RGB and HP1 colour transform:
            jpegls encode input.ppm output.jls --interleave line --colour-transform hp1

          Decode a JPEG-LS file to PNG:
            jpegls decode input.jls output.png --format png

          Decode to PGM or PPM:
            jpegls decode input.jls output.pgm --format pgm

          Display file metadata:
            jpegls info input.jls

          Verify file integrity:
            jpegls verify input.jls

          Compare two images (pixel-exact):
            jpegls compare reference.jls candidate.jls

          Compare with near-lossless tolerance:
            jpegls compare reference.pgm decoded.jls --near 3

          Convert PNG to TIFF:
            jpegls convert input.png output.tiff

          Convert PNG to JPEG-LS with near-lossless encoding:
            jpegls convert input.png output.jls --near 2

          Batch-encode all raw files in a directory:
            jpegls batch encode '*.raw' --width 256 --height 256 --output-dir encoded/

          Run a performance benchmark:
            jpegls benchmark --size 1024 --iterations 20

        Use 'jpegls <command> --help' for detailed help on any command.
        """,
        version: JPEGLS.version,
        subcommands: [Encode.self, Decode.self, Info.self, Verify.self, Batch.self, Compare.self, Convert.self, Benchmark.self, BenchDICOM.self, Completion.self],
        defaultSubcommand: nil
    )
}

JPEGLSCLITool.main()
