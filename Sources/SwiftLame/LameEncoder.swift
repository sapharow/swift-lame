//
//  LameEncoder.swift
//  swift-lame
//
//  Created by Iskandar Safarov on 4/5/2026.
//

import Foundation
@_implementationOnly import liblame
import os

/// Encodes interleaved 16-bit PCM to MP3 via liblame.
/// `Sendable` is justified because each call to `encode` takes an unfair lock around the native encoder.
final public class LameEncoder: @unchecked Sendable {

    /// Input-side description: PCM sample rate and channel layout for `encode(pcmBuffer:into:)`.
    public struct InPcmOptions: Sendable {
        /// Input PCM sample rate in Hz (for example 44100).
        public var sampleRate: Int

        /// Number of interleaved channels per sample (1 mono, 2 stereo).
        public var channelCount: Int

        /// Creates options describing the PCM stream that will be passed to the encoder.
        public init(sampleRate: Int, channelCount: Int) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    /// MP3 output settings: bitrate or ratio, channel mode, optional VBR, resampling, MPEG header bits, gapless metadata.
    public struct OutMp3Options: Sendable {

        /// MPEG channel mode stored in the bitstream (separate L/R, joint stereo, or single channel).
        public enum Mode: Sendable {
            /// Discrete left and right channels.
            case stereo

            /// Joint stereo (often smaller files; couples L/R where safe).
            case jointStereo

            /// Single-channel output.
            case mono
        }

        /// Variable-bitrate controls; paired with `compression` and LAME's global quality when enabled.
        public struct VBR: Sendable {

            /// Mean and min/max bitrates for ABR-style VBR (`VBR.mode.abr`).
            public struct ABRSettings: Sendable {
                /// Target average bitrate in kbps.
                public var meanBitrateKbps: Int

                /// Upper cap for instant bitrate in kbps.
                public var maxBitrateKbps: Int

                /// Lower floor for instant bitrate in kbps.
                public var minBitrateKbps: Int

                /// Builds ABR bitrate bounds for use with `.abr`.
                public init(meanBitrateKbps: Int, maxBitrateKbps: Int, minBitrateKbps: Int) {
                    self.meanBitrateKbps = meanBitrateKbps
                    self.maxBitrateKbps = maxBitrateKbps
                    self.minBitrateKbps = minBitrateKbps
                }
            }

            /// Selects which liblame VBR engine and optional ABR parameters to apply.
            public enum Mode: Sendable {
                /// Legacy Robert Hegemann VBR (`vbr_rh`); obsolete, kept for compatibility.
                case rh

                /// Average-bitrate VBR; optional `ABRSettings` sets mean/min/max kbps.
                case abr(ABRSettings?)

                /// Mark Taylor / Robert Hegemann VBR (`vbr_mtrh`); preferred default engine.
                case mtrh
            }

            /// Which VBR engine to use, and ABR parameters when the mode is `.abr`.
            public var mode: Mode

            /// VBR quality step: 0 = best, 9 = lowest; `nil` leaves LAME's default.
            public var quality: Float?

            /// If non-nil, passed to `lame_set_VBR_hard_min`: use 1 to strictly enforce VBR min bitrate, 0 to allow drops (e.g. silence).
            public var hardMinBitrateKbps: Int?

            /// Creates VBR settings; defaults pair with `OutMp3Options`'s default `.mtrh` usage.
            public init(mode: Mode, quality: Float? = nil, hardMinBitrateKbps: Int? = nil) {
                self.mode = mode
                self.quality = quality
                self.hardMinBitrateKbps = hardMinBitrateKbps
            }
        }

        /// Gapless MP3 album metadata: tells LAME how many tracks exist and which index this encode is.
        public struct Gapless: Sendable {
            /// Total number of gapless segments (maps to `lame_set_nogap_total`).
            public var count: Int

            /// Zero-based index of this segment (maps to `lame_set_nogap_currentindex`).
            public var index: Int

            /// Creates gapless counters for seamless multi-track encodes.
            public init(count: Int, index: Int) {
                self.count = count
                self.index = index
            }
        }

        /// How overall compression strength is chosen: explicit kbps or a PCM-to-MP3 size ratio.
        public enum Compression: Sendable {
            /// Target or constant bitrate in kilobits per second.
            case bitrateKbps(Int)

            /// Compression ratio (PCM size divided by MP3 size); alternative to a fixed kbps value.
            case ratio(Float)
        }

        /// Bitrate or ratio applied before `lame_init_params` (CBR-style target unless VBR overrides behavior).
        public var compression: Compression

        /// Stereo mode written into MPEG frames.
        public var mode: Mode

        /// VBR section; `nil` turns VBR off (`vbr_off`) after other options are applied.
        public var vbr: VBR?

        /// Output sample rate in Hz; `nil` means same as input (`lame_set_out_samplerate` uses input rate).
        public var sampleRate: Int?

        /// Psychoacoustic preset 0...9 (lower = slower, often better at same bitrate); `nil` is default. Bitrate still dominates perceived quality.
        public var quality: Int?

        /// Optional gapless album/track indices for players that honor LAME gapless tags.
        public var gapless: Gapless?

        /// MPEG Audio Layer 3 "copyright" header flag.
        public var copyright: Bool

        /// MPEG "original / copy" header flag.
        public var original: Bool

        /// Enables CRC error protection in the MPEG frame header when supported.
        public var errorProtection: Bool

        /// Sets the private-mode extension bit in the MPEG header.
        public var extensionBit: Bool

        /// Enforces stricter ISO sizing limits for frames (may increase bitrate).
        public var strictISO: Bool

        /// Builds output options; defaults match common 128 kbps joint-stereo with `mtrh` VBR unless you override.
        public init(
            compression: Compression = .bitrateKbps(128),
            mode: Mode = .jointStereo,
            vbr: VBR? = VBR(mode: .mtrh),
            sampleRate: Int? = nil,
            quality: Int? = nil,
            gapless: Gapless? = nil,
            copyright: Bool = false,
            original: Bool = false,
            errorProtection: Bool = false,
            extensionBit: Bool = false,
            strictISO: Bool = false
        ) {
            self.compression = compression
            self.mode = mode
            self.vbr = vbr
            self.sampleRate = sampleRate
            self.quality = quality
            self.gapless = gapless
            self.copyright = copyright
            self.original = original
            self.errorProtection = errorProtection
            self.extensionBit = extensionBit
            self.strictISO = strictISO
        }
    }

    /// Errors surfaced while constructing the encoder or when a liblame call returns non-success.
    public enum LameError: Swift.Error, Sendable, Equatable {
        /// `lame_init` returned no handle.
        case initializationFailed

        /// A setter or `lame_init_params` returned non-zero; `code` is the liblame status value.
        case callFailed(function: String, code: Int32)

        /// Swift-side validation failed (for example invalid channel count).
        case invalidInput(String)

        /// Reserved for callers when MP3 output cannot be written; not thrown by `LameEncoder` itself.
        case writingAborted
    }

    /// Copy of input PCM parameters used for `lame_encode_buffer_interleaved` frame sizing.
    private let inOptions: InPcmOptions

    /// Frozen MP3/lame configuration applied at init.
    private let outOptions: OutMp3Options

    /// Opaque LAME encoder handle from `lame_init`.
    private let lame: lame_t

    /// Serializes `encode` and native lame calls for this instance.
    private let lock: os_unfair_lock_t

    /// Allocates and configures liblame from `inOptions` / `outOptions`; closes the handle if setup fails.
    public init(inOptions: InPcmOptions, outOptions: OutMp3Options) throws(LameError) {
        guard inOptions.channelCount > 0 else {
            throw .invalidInput("PCM channel count must be positive")
        }

        self.inOptions = inOptions
        self.outOptions = outOptions
        self.lame = try Self.initializeLame(inOptions: inOptions, outOptions: outOptions)
        self.lock = os_unfair_lock_t.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    /// Releases the native encoder and lock memory.
    deinit {
        lame_close(lame)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Encodes one PCM chunk to MP3, or flushes trailing frames when `pcmBuffer` is `nil`.
    ///
    /// - Parameters:
    ///   - pcmBuffer: Interleaved signed 16-bit samples; length must be a multiple of `channelCount`. Pass `nil` to flush.
    ///   - mp3Buffer: Receives MP3 bytes; LAME suggests sizing at least `1.25 * sampleCount + 7200` bytes for the chunk.
    /// - Returns: Number of bytes written into `mp3Buffer`.
    public func encode(pcmBuffer: UnsafeBufferPointer<Int16>?, into mp3Buffer: UnsafeMutableBufferPointer<UInt8>) throws(LameError) -> Int {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }

        let code: Int32
        if let pcmBuffer {
            let sampleCount = pcmBuffer.count / inOptions.channelCount
            code = lame_encode_buffer_interleaved(lame, pcmBuffer.baseAddress, Int32(sampleCount), mp3Buffer.baseAddress, Int32(mp3Buffer.count))
            guard code >= 0 else {
                throw .callFailed(function: "lame_encode_buffer_interleaved", code: code)
            }
        } else {
            code = lame_encode_flush(lame, mp3Buffer.baseAddress, Int32(mp3Buffer.count))
            guard code >= 0 else {
                throw .callFailed(function: "lame_encode_flush", code: code)
            }
        }

        return Int(code)
    }

}

private extension LameEncoder {

    /// Maps Swift options onto `lame_t` setters, then calls `lame_init_params`; closes `lame` on any failure.
    static func initializeLame(inOptions: InPcmOptions, outOptions: OutMp3Options) throws(LameError) -> lame_t {
        guard let lame = lame_init() else {
            throw .initializationFailed
        }

        do {
            try validate(lame_set_in_samplerate(lame, Int32(inOptions.sampleRate)), "lame_set_in_samplerate")
            try validate(lame_set_num_channels(lame, Int32(inOptions.channelCount)), "lame_set_num_channels")
            try validate(lame_set_out_samplerate(lame, Int32(outOptions.sampleRate ?? inOptions.sampleRate)), "lame_set_out_samplerate")

            if let quality = outOptions.quality {
                try validate(lame_set_quality(lame, Int32(quality)), "lame_set_quality")
            }
            try validate(lame_set_mode(lame, outOptions.mode.lame), "lame_set_mode")

            if let gapless = outOptions.gapless {
                try validate(lame_set_nogap_total(lame, Int32(gapless.count)), "lame_set_nogap_total")
                try validate(lame_set_nogap_currentindex(lame, Int32(gapless.index)), "lame_set_nogap_currentindex")
            }

            switch outOptions.compression {
            case .bitrateKbps(let bitrate):
                try validate(lame_set_brate(lame, Int32(bitrate)), "lame_set_brate")
            case .ratio(let ratio):
                try validate(lame_set_compression_ratio(lame, ratio), "lame_set_compression_ratio")
            }

            try validate(lame_set_copyright(lame, outOptions.copyright ? 1 : 0), "lame_set_copyright")
            try validate(lame_set_original(lame, outOptions.original ? 1 : 0), "lame_set_original")
            try validate(lame_set_error_protection(lame, outOptions.errorProtection ? 1 : 0), "lame_set_error_protection")
            try validate(lame_set_extension(lame, outOptions.extensionBit ? 1 : 0), "lame_set_extension")
            try validate(lame_set_strict_ISO(lame, outOptions.strictISO ? 1 : 0), "lame_set_strict_ISO")

            // VBR settings

            if let vbr = outOptions.vbr {
                try validate(lame_set_VBR(lame, vbr.mode.lame), "lame_set_VBR")
                if let vbrQuality = vbr.quality {
                    try validate(lame_set_VBR_quality(lame, vbrQuality), "lame_set_VBR_quality")
                }
                if case .abr(let abrSettings) = vbr.mode, let abrSettings {
                    try validate(lame_set_VBR_mean_bitrate_kbps(lame, Int32(abrSettings.meanBitrateKbps)), "lame_set_VBR_mean_bitrate_kbps")
                    try validate(lame_set_VBR_max_bitrate_kbps(lame, Int32(abrSettings.maxBitrateKbps)), "lame_set_VBR_max_bitrate_kbps")
                    try validate(lame_set_VBR_min_bitrate_kbps(lame, Int32(abrSettings.minBitrateKbps)), "lame_set_VBR_min_bitrate_kbps")
                }
                if let hardMinBitrateKbps = vbr.hardMinBitrateKbps {
                    try validate(lame_set_VBR_hard_min(lame, Int32(hardMinBitrateKbps)), "lame_set_VBR_hard_min")
                }
            } else {
                try validate(lame_set_VBR(lame, vbr_off), "lame_set_VBR")
            }

            try validate(lame_init_params(lame), "lame_init_params")
        } catch {
            lame_close(lame)
            throw error
        }

        return lame
    }

    /// Converts liblame's `int` return convention: zero means success for these calls.
    static func validate(_ code: Int32, _ function: String) throws(LameError) {
        guard code == 0 else {
            throw .callFailed(function: function, code: code)
        }
    }

}

private extension LameEncoder.OutMp3Options.VBR.Mode {

    /// `vbr_mode` constant consumed by `lame_set_VBR`.
    var lame: vbr_mode {
        switch self {
        case .rh: vbr_rh
        case .abr: vbr_abr
        case .mtrh: vbr_mtrh
        }
    }
}

private extension LameEncoder.OutMp3Options.Mode {

    /// MPEG channel mode constant consumed by `lame_set_mode`.
    var lame: MPEG_mode {
        switch self {
        case .stereo: STEREO
        case .jointStereo: JOINT_STEREO
        case .mono: MONO
        }
    }
}

/// liblame's handle is safe to move across isolation domains when wrapped usage is externally synchronized.
extension lame_t: @retroactive @unchecked Sendable { }
