[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-green?style=flat)](https://img.shields.io/badge/Swift_Package_Manager-compatible-green?style=flat)
[![Platforms](https://img.shields.io/badge/Platforms-macOS_iOS_tvOS-green?style=flat)](https://img.shields.io/badge/Platforms-macOS_iOS_tvOS-Green?style=flat)
[![License](https://img.shields.io/github/license/phisto/swift-lame.svg?style=flat)](https://github.com/Phisto/swift-lame)

# swift-lame

`swift-lame` provides a Swift-first encoder API (`import SwiftLame`) backed by vendored
[LAME](https://lame.sourceforge.io) C sources.

The currently vendored LAME version is `3.100.0` (derived from
`Sources/lame/libmp3lame/include/version.h`).

## Requirements

- Xcode 16.3+
- `swift-tools-version: 6.1+`

LAME library     | macOS  | iOS   | tvOS
-----------------|--------|-------|--------
3.100.0          | 10.13+ | 12.0+ | 12.0+

## Installation

### Swift Package Manager

SwiftPM compiles vendored C LAME sources and links them with `SwiftLame`.

```swift
dependencies: [
    .package(url: "https://github.com/sapharow/swift-lame.git", .upToNextMajor(from: "3.100.0"))
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftLame", package: "swift-lame")
        ]
    )
]
```

Compatibility note: this package also keeps the historical product name `lame`.

## Usage

Use `LameEncoder` with interleaved 16-bit PCM input and call `encode(pcmBuffer:into:)`
repeatedly, then flush by passing `nil`.

```swift
import Foundation
import SwiftLame

func encodePcmToMp3(_ pcm: [Int16], sampleRate: Int = 44_100, channels: Int = 2) throws -> Data {
    let inOptions = LameEncoder.InPcmOptions(sampleRate: sampleRate, channelCount: channels)
    let outOptions = LameEncoder.OutMp3Options(
        compression: .bitrateKbps(192),
        mode: channels == 1 ? .mono : .jointStereo,
        vbr: nil
    )

    let encoder = try LameEncoder(inOptions: inOptions, outOptions: outOptions)
    var mp3Data = Data()

    let pcmChunkSize = 1152 * channels
    var pcmIndex = 0

    while pcmIndex < pcm.count {
        let end = min(pcmIndex + pcmChunkSize, pcm.count)
        let chunk = Array(pcm[pcmIndex..<end])
        let sampleCount = chunk.count / channels
        let mp3Capacity = max(Int(1.25 * Double(sampleCount) + 7200), 7200)
        var mp3Buffer = [UInt8](repeating: 0, count: mp3Capacity)

        let written: Int = try chunk.withUnsafeBufferPointer { pcmPointer in
            try mp3Buffer.withUnsafeMutableBufferPointer { mp3Pointer in
                try encoder.encode(pcmBuffer: pcmPointer, into: mp3Pointer)
            }
        }
        mp3Data.append(contentsOf: mp3Buffer.prefix(written))
        pcmIndex = end
    }

    var flushBuffer = [UInt8](repeating: 0, count: 7200)
    let flushWritten: Int = try flushBuffer.withUnsafeMutableBufferPointer { mp3Pointer in
        try encoder.encode(pcmBuffer: nil, into: mp3Pointer)
    }
    mp3Data.append(contentsOf: flushBuffer.prefix(flushWritten))

    return mp3Data
}
```

## License

LAME is released under the [GNU Lesser General Public License v3.0](./LICENSE).
Commercial use and distribution requirements are your responsibility, including license notice
compliance and dynamic-linking/relinking obligations where applicable.
