import Foundation
import Compression

// 最小化 ZIP 构建器（用于生成 .xlsx OOXML 包）
// .xlsx 本质是 ZIP 格式，此处使用 DEFLATE 压缩
enum ZipArchiveBuilder {
    static func build(files: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var localFileOffsets: [UInt32] = []

        for file in files {
            let offset = UInt32(archive.count)
            localFileOffsets.append(offset)

            let nameData = Data(file.path.utf8)
            let compressedData = compress(file.data)
            let crc = crc32(file.data)

            // Local file header
            archive += uint32LE(0x04034b50) // signature
            archive += uint16LE(20)          // version needed
            archive += uint16LE(0)           // flags
            archive += uint16LE(8)           // compression: DEFLATE
            archive += uint16LE(0)           // mod time
            archive += uint16LE(0)           // mod date
            archive += uint32LE(crc)
            archive += uint32LE(UInt32(compressedData.count))
            archive += uint32LE(UInt32(file.data.count))
            archive += uint16LE(UInt16(nameData.count))
            archive += uint16LE(0)           // extra length
            archive += nameData
            archive += compressedData

            // Central directory entry
            var cd = Data()
            cd += uint32LE(0x02014b50)
            cd += uint16LE(20) // version made by
            cd += uint16LE(20) // version needed
            cd += uint16LE(0)  // flags
            cd += uint16LE(8)  // compression
            cd += uint16LE(0)  // mod time
            cd += uint16LE(0)  // mod date
            cd += uint32LE(crc)
            cd += uint32LE(UInt32(compressedData.count))
            cd += uint32LE(UInt32(file.data.count))
            cd += uint16LE(UInt16(nameData.count))
            cd += uint16LE(0)  // extra
            cd += uint16LE(0)  // comment
            cd += uint16LE(0)  // disk start
            cd += uint16LE(0)  // internal attr
            cd += uint32LE(0)  // external attr
            cd += uint32LE(offset)
            cd += nameData
            centralDirectory += cd
        }

        let cdOffset = UInt32(archive.count)
        archive += centralDirectory

        // End of central directory
        archive += uint32LE(0x06054b50)
        archive += uint16LE(0)                           // disk number
        archive += uint16LE(0)                           // start disk
        archive += uint16LE(UInt16(files.count))
        archive += uint16LE(UInt16(files.count))
        archive += uint32LE(UInt32(centralDirectory.count))
        archive += uint32LE(cdOffset)
        archive += uint16LE(0)                           // comment length

        return archive
    }

    private static func compress(_ data: Data) -> Data {
        // 使用 Apple Compression 框架的 ZLIB raw deflate
        let bufferSize = data.count + 1024
        var output = Data(count: bufferSize)
        let written = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                compression_encode_buffer(
                    outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), bufferSize,
                    inPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        // ZLIB 格式需剥离 2 字节头和 4 字节尾以得到 raw deflate
        let deflate = written > 6 ? output.subdata(in: 2..<(written - 4)) : output.prefix(written)
        return deflate
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1))
            }
        }
        return ~crc
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var val = v.littleEndian
        return Data(bytes: &val, count: 2)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var val = v.littleEndian
        return Data(bytes: &val, count: 4)
    }
}

enum ZipArchiveReader {
    static func read(data: Data) throws -> [String: Data]? {
        // 简单实现：查找 End of Central Directory，解析 Central Directory
        guard let eocdOffset = findEOCD(data) else { return nil }
        var result: [String: Data] = [:]

        let cdOffset = data.readUInt32LE(at: eocdOffset + 16)
        let cdSize   = data.readUInt32LE(at: eocdOffset + 12)
        var pos = Int(cdOffset)

        while pos < Int(cdOffset + cdSize) {
            guard data.readUInt32LE(at: pos) == 0x02014b50 else { break }
            let compMethod = data.readUInt16LE(at: pos + 10)
            let compSize   = Int(data.readUInt32LE(at: pos + 20))
            let uncompSize = Int(data.readUInt32LE(at: pos + 24))
            let nameLen    = Int(data.readUInt16LE(at: pos + 28))
            let extraLen   = Int(data.readUInt16LE(at: pos + 30))
            let commentLen = Int(data.readUInt16LE(at: pos + 32))
            let localOffset = Int(data.readUInt32LE(at: pos + 42))
            let name = String(data: data.subdata(in: (pos + 46)..<(pos + 46 + nameLen)), encoding: .utf8) ?? ""
            pos += 46 + nameLen + extraLen + commentLen

            // 读取本地文件数据
            let localNameLen  = Int(data.readUInt16LE(at: localOffset + 26))
            let localExtraLen = Int(data.readUInt16LE(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            let compData = data.subdata(in: dataStart..<(dataStart + compSize))

            if compMethod == 0 {
                result[name] = compData
            } else if compMethod == 8 {
                result[name] = inflateDeflate(compData, uncompressedSize: uncompSize)
            }
        }
        return result
    }

    private static func findEOCD(_ data: Data) -> Int? {
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let bytes = [UInt8](data)
        for i in stride(from: bytes.count - 22, through: 0, by: -1) {
            if bytes[i..<(i+4)].elementsEqual(sig) { return i }
        }
        return nil
    }

    private static func inflateDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                compression_decode_buffer(
                    outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), uncompressedSize,
                    inPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written > 0 ? output.prefix(written) : nil
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return subdata(in: offset..<(offset+2)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
