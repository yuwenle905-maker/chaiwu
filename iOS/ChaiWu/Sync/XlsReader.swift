import Foundation
import CoreFoundation

// Minimal OLE2 Compound Document + BIFF8 reader for .xls files
// Supports: SST, LABELSST, NUMBER, RK, MULRK, LABEL records

enum XlsCell {
    case str(String)
    case num(Double)
    case empty

    var stringValue: String? {
        if case .str(let s) = self { return s }
        return nil
    }
    var numberValue: Double? {
        if case .num(let n) = self { return n }
        return nil
    }
}

enum XlsReaderError: Error {
    case notXLS
    case corrupted(String)
}

final class XlsReader {

    // MARK: - Public

    static func parse(data: Data) throws -> [[XlsCell]] {
        appLog("XlsReader.parse 开始, dataSize=\(data.count)")
        let magic: [UInt8] = [0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1]
        guard data.count >= 512, (0..<8).allSatisfy({ data[$0] == magic[$0] }) else {
            appLog("OLE2 magic 校验失败，非 XLS 格式", level: .warn)
            throw XlsReaderError.notXLS
        }
        appLog("OLE2 magic OK，提取 Workbook stream...")
        let reader = XlsReader(data: data)
        let stream = try reader.extractWorkbookStream()
        appLog("Workbook stream size=\(stream.count)，开始解析 BIFF8...")
        let rows = reader.parseBIFF8(stream: stream)
        appLog("BIFF8 解析完成，rows=\(rows.count)")
        return rows
    }

    // MARK: - Private

    private let data: Data

    private init(data: Data) { self.data = data }

    private func u8(_ off: Int) -> Int { off < data.count ? Int(data[off]) : 0 }
    private func u16(_ off: Int) -> Int { u8(off) | (u8(off+1) << 8) }
    private func u32(_ off: Int) -> Int { u16(off) | (u16(off+2) << 16) }

    // MARK: - OLE2

    private func extractWorkbookStream() throws -> Data {
        let sectorSize     = 1 << u16(30)
        let miniSectorSize = 1 << u16(32)
        let miniCutoff     = u32(56)
        let numFatSectors  = u32(44)
        let firstDirSec    = u32(48)
        let firstMiniFAT   = u32(60)

        func sectorSlice(_ idx: Int) -> Data {
            let off = 512 + idx * sectorSize
            guard off < data.count else { return Data() }
            // Data(slice) 复制字节，重置 startIndex 为 0，避免切片偏移导致越界崩溃
            return Data(data[off..<min(off+sectorSize, data.count)])
        }

        // Build FAT from DIFAT array in header (up to 109 entries at offsets 76…)
        var fat = [Int]()
        for i in 0..<min(numFatSectors, 109) {
            let fi = u32(76 + i*4)
            guard fi < 0xFFFFFF00 else { break }
            let sd = sectorSlice(fi)
            for j in stride(from: 0, to: sd.count-3, by: 4) {
                let v = Int(sd[j]) | (Int(sd[j+1])<<8) | (Int(sd[j+2])<<16) | (Int(sd[j+3])<<24)
                fat.append(v)
            }
        }

        func isEOC(_ v: Int) -> Bool { v < 0 || v >= 0xFFFFFF00 }

        func chain(_ start: Int) -> Data {
            var result = Data(); var sec = start; var visited = Set<Int>()
            while sec >= 0 && sec < fat.count && !visited.contains(sec) {
                visited.insert(sec); result.append(sectorSlice(sec))
                let nxt = fat[sec]; sec = isEOC(nxt) ? -1 : nxt
            }
            return result
        }

        // Directory entries (128 bytes each)
        let dirData = chain(firstDirSec)
        struct Entry { let name: String; let type: UInt8; let start: Int; let size: Int }
        var entries = [Entry]()
        var i = 0
        while i + 128 <= dirData.count {
            let nlen = Int(dirData[i+64]) | (Int(dirData[i+65])<<8)
            var name = ""
            if nlen > 2 {
                var chars = [UInt16]()
                for k in stride(from: i, to: i+nlen-2, by: 2) {
                    chars.append(UInt16(dirData[k]) | (UInt16(dirData[k+1])<<8))
                }
                name = String(String.UnicodeScalarView(chars.compactMap { UnicodeScalar($0) }))
            }
            let tp  = dirData[i+66]
            let st  = Int(Int32(bitPattern: UInt32(dirData[i+116]) | (UInt32(dirData[i+117])<<8) | (UInt32(dirData[i+118])<<16) | (UInt32(dirData[i+119])<<24)))
            let sz  = Int(dirData[i+120]) | (Int(dirData[i+121])<<8) | (Int(dirData[i+122])<<16) | (Int(dirData[i+123])<<24)
            entries.append(Entry(name: name, type: tp, start: max(0, st), size: max(0, sz)))
            i += 128
        }

        // Mini stream (inside root entry chain)
        let rootEntry = entries.first
        let miniStreamData: Data = {
            guard let re = rootEntry, re.start < 0xFFFFFF00 else { return Data() }
            return chain(re.start).prefix(re.size)
        }()

        // Mini FAT
        var miniFAT = [Int]()
        if firstMiniFAT < 0xFFFFFF00 {
            var sec = firstMiniFAT; var vis = Set<Int>()
            while sec >= 0 && sec < fat.count && !vis.contains(sec) {
                vis.insert(sec)
                let sd = sectorSlice(sec)
                for j in stride(from: 0, to: sd.count-3, by: 4) {
                    let v = Int(sd[j]) | (Int(sd[j+1])<<8) | (Int(sd[j+2])<<16) | (Int(sd[j+3])<<24)
                    miniFAT.append(v)
                }
                let nxt = fat[sec]; sec = isEOC(nxt) ? -1 : nxt
            }
        }

        func miniChain(_ start: Int) -> Data {
            var result = Data(); var sec = start; var vis = Set<Int>()
            while sec >= 0 && sec < miniFAT.count && !vis.contains(sec) {
                vis.insert(sec)
                let off = sec * miniSectorSize
                let end = min(off + miniSectorSize, miniStreamData.count)
                if off < miniStreamData.count { result.append(miniStreamData[off..<end]) }
                let nxt = miniFAT[sec]; sec = (nxt >= 0 && nxt < 0xFFFFFF00) ? nxt : -1
            }
            return result
        }

        // Find "Workbook" or "Book" stream
        for entry in entries where entry.type == 2 && (entry.name == "Workbook" || entry.name == "Book") {
            if entry.size < miniCutoff && !miniFAT.isEmpty {
                return Data(miniChain(entry.start).prefix(entry.size))
            } else {
                return Data(chain(entry.start).prefix(entry.size))
            }
        }
        throw XlsReaderError.corrupted("No Workbook stream found")
    }

    // MARK: - BIFF8

    private func parseBIFF8(stream: Data) -> [[XlsCell]] {
        func b(_ off: Int) -> Int { off < stream.count ? Int(stream[off]) : 0 }
        func w(_ off: Int) -> Int { b(off) | (b(off+1)<<8) }
        func dw(_ off: Int) -> Int { w(off) | (w(off+2)<<16) }
        func f64(_ off: Int) -> Double {
            guard off+8 <= stream.count else { return 0 }
            var v: Double = 0
            withUnsafeMutableBytes(of: &v) { p in (0..<8).forEach { p[$0] = stream[off+$0] } }
            return v
        }
        func rkVal(_ rk: Int) -> Double {
            let v: Double
            if rk & 2 != 0 {
                v = Double(rk >> 2)
            } else {
                var bits: UInt64 = UInt64(UInt32(truncatingIfNeeded: rk & ~3)) << 32
                var tmp: Double = 0
                withUnsafeMutableBytes(of: &tmp) { p in withUnsafeBytes(of: &bits) { s in (0..<8).forEach { p[$0] = s[$0] } } }
                v = tmp
            }
            return rk & 1 != 0 ? v / 100 : v
        }

        // Read BIFF8 Unicode string from buf starting at pos (buf must have startIndex==0)
        func biffStr(buf: Data, at pos: Int, cch: Int, highByte: Bool) -> String {
            if highByte {
                var chars = [UInt16]()
                for i in 0..<cch {
                    let p = pos + i*2
                    if p+1 < buf.count { chars.append(UInt16(buf[p]) | (UInt16(buf[p+1])<<8)) }
                }
                return String(String.UnicodeScalarView(chars.compactMap { UnicodeScalar($0) }))
            } else {
                let bytes = (0..<cch).compactMap { pos+$0 < buf.count ? buf[pos+$0] : nil }
                // 优先尝试 GBK/GB18030（中文 XLS 常用编码），再回退 Latin-1
                let gbkEnc = String.Encoding(rawValue:
                    CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                return String(bytes: bytes, encoding: gbkEnc)
                    ?? String(bytes: bytes, encoding: .isoLatin1)
                    ?? ""
            }
        }

        // Collect all records first (handle CONTINUE merging for SST)
        appLog("BIFF8: 开始收集 records, stream=\(stream.count)")
        var records = [(type: Int, data: Data)]()
        var pos = 0
        while pos + 4 <= stream.count {
            let rt = w(pos); let rs = w(pos+2)
            let start = pos+4; let end = start+rs
            guard end <= stream.count else { break }
            records.append((rt, Data(stream[start..<end])))
            pos = end
        }
        appLog("BIFF8: records=\(records.count)")

        // Merge CONTINUE records into SST
        var merged = [(type: Int, data: Data)]()
        var idx = 0
        while idx < records.count {
            let rec = records[idx]
            if rec.type == 0x00FC { // SST: merge following CONTINUE
                var combined = rec.data
                idx += 1
                while idx < records.count && records[idx].type == 0x003C {
                    combined.append(records[idx].data)
                    idx += 1
                }
                merged.append((0x00FC, combined))
            } else {
                merged.append(rec)
                idx += 1
            }
        }
        appLog("BIFF8: merged=\(merged.count)")

        // Parse SST
        var sst = [String]()
        if let sstRec = merged.first(where: { $0.type == 0x00FC }), sstRec.data.count >= 8 {
            let sd = sstRec.data
            // 安全字节读取，越界返回 0，避免 fatal error
            func sb(_ i: Int) -> Int { i >= 0 && i < sd.count ? Int(sd[i]) : 0 }
            let total = sb(4) | (sb(5)<<8) | (sb(6)<<16) | (sb(7)<<24)
            var p = 8
            for _ in 0..<total {
                guard p < sd.count else { break }
                let cch   = sb(p) | (sb(p+1)<<8); p += 2
                guard p < sd.count else { break }
                let flags = sb(p); p += 1
                let hi    = (flags & 1) != 0
                let rich  = (flags & 8) != 0
                let ext   = (flags & 4) != 0
                let rt2: Int
                if rich {
                    guard p+1 < sd.count else { break }
                    rt2 = sb(p) | (sb(p+1)<<8); p += 2
                } else { rt2 = 0 }
                let esz: Int
                if ext {
                    guard p+3 < sd.count else { break }
                    esz = sb(p) | (sb(p+1)<<8) | (sb(p+2)<<16) | (sb(p+3)<<24); p += 4
                } else { esz = 0 }
                let bytes = hi ? cch*2 : cch
                guard p+bytes <= sd.count else { break }
                sst.append(biffStr(buf: sd, at: p, cch: cch, highByte: hi))
                p += bytes
                if rich { p += rt2*4 }
                if ext  { p += esz }
            }
        }

        appLog("BIFF8: SST=\(sst.count) strings")
        // Parse worksheet records
        var rows = [[XlsCell]]()
        var rowBuf = [Int: XlsCell]()
        var curRow = -1
        var inSheet = false

        func flush() {
            guard curRow >= 0, !rowBuf.isEmpty else { return }
            let maxC = rowBuf.keys.max() ?? 0
            guard maxC < 1024 else {
                appLog("BIFF8: flush 跳过异常列号 maxC=\(maxC) row=\(curRow)", level: .warn)
                rowBuf.removeAll(); return
            }
            let cells = (0...maxC).map { rowBuf[$0] ?? .empty }
            while rows.count <= curRow { rows.append([]) }
            rows[curRow] = cells
            rowBuf.removeAll()
        }
        func setCell(row: Int, col: Int, val: XlsCell) {
            if row != curRow { flush(); curRow = row }
            rowBuf[col] = val
        }

        appLog("BIFF8: 开始遍历 worksheet records")
        var recIdx = 0
        for rec in merged {
            recIdx += 1
            let rd = rec.data
            func rb(_ i: Int) -> Int { i < rd.count ? Int(rd[i]) : 0 }
            func rw(_ i: Int) -> Int { rb(i) | (rb(i+1)<<8) }
            func rdw(_ i: Int) -> Int { rw(i) | (rw(i+2)<<16) }
            func rf64(_ i: Int) -> Double {
                guard i+8 <= rd.count else { return 0 }
                var v: Double = 0
                withUnsafeMutableBytes(of: &v) { p in (0..<8).forEach { p[$0] = rd[i+$0] } }
                return v
            }

            if recIdx % 10 == 0 { appLog("BIFF8: rec#\(recIdx) type=0x\(String(rec.type, radix:16)) len=\(rd.count)") }
            switch rec.type {
            case 0x0809: // BOF
                let dt = rd.count >= 4 ? rw(2) : 0
                inSheet = (dt == 0x0010)

            case 0x000A: // EOF
                if inSheet { flush() }

            case 0x00FD where inSheet: // LABELSST
                guard rd.count >= 10 else { break }
                let row = rw(0); let col = rw(2)
                let si  = rdw(6)
                setCell(row: row, col: col, val: si < sst.count ? .str(sst[si]) : .empty)

            case 0x0203 where inSheet: // NUMBER
                guard rd.count >= 14 else { break }
                setCell(row: rw(0), col: rw(2), val: .num(rf64(6)))

            case 0x027E where inSheet: // RK
                guard rd.count >= 10 else { break }
                setCell(row: rw(0), col: rw(2), val: .num(rkVal(rdw(6))))

            case 0x00BD where inSheet: // MULRK
                guard rd.count >= 6 else { break }
                let row = rw(0); let fc = rw(2)
                let n = (rd.count - 6) / 6
                for i in 0..<n {
                    let rkv = rdw(4 + i*6 + 2)
                    setCell(row: row, col: fc+i, val: .num(rkVal(rkv)))
                }

            case 0x0204 where inSheet: // LABEL (old-style inline string)
                guard rd.count >= 8 else { break }
                let row = rw(0); let col = rw(2); let cch = rw(6)
                let s = String(bytes: (0..<cch).compactMap { 8+$0 < rd.count ? rd[8+$0] : nil },
                               encoding: .isoLatin1) ?? ""
                setCell(row: row, col: col, val: .str(s))

            case 0x0201 where inSheet: // BLANK
                guard rd.count >= 4 else { break }
                setCell(row: rw(0), col: rw(2), val: .empty)

            default: break
            }
        }

        return rows.filter { !$0.allSatisfy { if case .empty = $0 { return true }; return false } }
    }
}

// MARK: - Convert XLS rows → Transactions

extension XlsReader {

    /// Auto-detect column layout and convert rows to Transactions
    static func rowsToTransactions(_ rows: [[XlsCell]]) -> [Transaction] {
        guard rows.count >= 2 else { return [] }

        // Check if it's the app's own 9-column format
        let header = rows[0].compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
        if header.contains("UUID") && header.contains("类型") && header.contains("金额") {
            return parseAppFormat(rows: rows)
        }

        // Auto-detect: look for date-like col 0, amount col 1 (汇昱账单 style)
        return parseAutoFormat(rows: rows)
    }

    private static func parseAppFormat(rows: [[XlsCell]]) -> [Transaction] {
        // Same column order as OOXMLReader: Date,Type,Amount,Category,Note,UUID,ModifiedAt,Device,Conflict
        var results = [Transaction]()
        let iso = ISO8601DateFormatter()
        for row in rows.dropFirst() {
            guard row.count >= 9 else { continue }
            let vals = row.map { cell -> String in
                switch cell {
                case .str(let s): return s
                case .num(let n): return String(n)
                case .empty: return ""
                }
            }
            guard
                let date     = iso.date(from: vals[0]),
                let type     = TransactionType(rawValue: vals[1]),
                let amount   = Decimal(string: vals[2]),
                let category = TransactionCategory(rawValue: vals[3]),
                let id       = UUID(uuidString: vals[5]),
                let modified = iso.date(from: vals[6])
            else { continue }
            results.append(Transaction(id: id, date: date, type: type, amount: amount,
                                       category: category, note: vals[4],
                                       modifiedAt: modified, sourceDevice: vals[7],
                                       isConflict: vals[8] == "true"))
        }
        return results
    }

    private static func excelSerialToDate(_ serial: Double) -> Date? {
        guard serial >= 1 else { return nil }
        var days = Int(serial)
        if days >= 60 { days -= 1 } // Excel 1900 虚假闰年补偿
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard let base = cal.date(from: DateComponents(year: 1899, month: 12, day: 31)) else { return nil }
        return cal.date(byAdding: .day, value: days, to: base)
    }

    private static func parseAutoFormat(rows: [[XlsCell]]) -> [Transaction] {
        // 跳过表头：首格是字符串且不像日期
        var dataRows = rows
        if let first = rows.first, let s = first.first?.stringValue,
           !s.contains("月") && !s.contains("-") && !s.contains("/") {
            dataRows = Array(rows.dropFirst())
        }

        var results = [Transaction]()
        let now = Date()
        for row in dataRows {
            guard !row.isEmpty else { continue }
            // Col 0: 日期（字符串或 Excel 序列数字）
            var date = now
            if let s = row[safe: 0]?.stringValue {
                date = parseChineseDate(s) ?? now
            } else if let n = row[safe: 0]?.numberValue, n > 1 {
                date = excelSerialToDate(n) ?? now
            }
            // Col 1: 金额
            guard let amtCell = row[safe: 1], let amtVal = amtCell.numberValue ?? {
                if case .str(let s) = amtCell, let d = Double(s) { return d }
                return nil
            }() else { continue }

            let note   = row[safe: 3]?.stringValue ?? (row[safe: 2]?.stringValue ?? "")
            let type: TransactionType = amtVal >= 0 ? .income : .expense
            guard let amount = Decimal(string: String(format: "%.2f", abs(amtVal))) else { continue }
            let category = guessCategory(note: note, isIncome: amtVal >= 0)
            results.append(Transaction(date: date, type: type, amount: amount,
                                       category: category, note: note,
                                       sourceDevice: "汇昱账单导入"))
        }
        return results
    }

    private static func parseChineseDate(_ s: String) -> Date? {
        // "3月18日" → 2026-03-18
        let pat = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
        let ns = s as NSString
        if let m = pat?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let mo = ns.substring(with: m.range(at: 1))
            let dy = ns.substring(with: m.range(at: 2))
            var c = Calendar.current
            c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var comps = DateComponents()
            comps.year = 2026; comps.month = Int(mo); comps.day = Int(dy)
            return c.date(from: comps)
        }
        // ISO / yyyy-MM-dd
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    private static func guessCategory(note: String, isIncome: Bool) -> TransactionCategory {
        if isIncome {
            if note.contains("快递") { return .expressRefund }
            if note.contains("尾款") { return .clientBalance }
            return .clientDeposit
        } else {
            if note.contains("底薪") { return .baseSalary }
            if note.contains("绩效") { return .performance }
            if note.contains("物业") || note.contains("电费") || note.contains("房") { return .rent }
            if note.contains("广告") { return .advertising }
            let isLogistics = note.contains("物流") ||
                (note.range(of: "资料\\*?\\d+", options: .regularExpression) != nil)
            if isLogistics { return .logistics }
            return .custom
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

