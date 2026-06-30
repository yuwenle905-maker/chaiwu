import Foundation

// 依赖: CoreXLSX (Swift Package: https://github.com/CoreOffice/CoreXLSX)
// 写入依赖: xlsxwriter via C bridge，或使用自研轻量 OOXML 生成器（见下方 OOXMLWriter）
// 为兼容 TrollStore 环境，此处使用纯 Swift OOXML 生成，无需额外 C 库

final class XlsxManager {
    static let shared = XlsxManager()

    var xlsxURL: URL {
        // 优先 iCloud Drive（TrollStore 直接访问）
        let icloud = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/ChaiWu")
        if (try? FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: icloud.path) {
            return icloud.appendingPathComponent("chaiwu_data.xlsx")
        }
        // fallback：沙盒 Documents
        let sandbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChaiWu", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox.appendingPathComponent("chaiwu_data.xlsx")
    }

    private var backupDir: URL {
        // 备份与 db 同级
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChaiWu/backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - 导出（写入 xlsx）

    func exportToXlsx(_ transactions: [Transaction]) throws {
        // 1. 写前备份
        makeBackup()

        // 2. 生成 xlsx 内容到临时文件（原子写入）
        let tempURL = xlsxURL.deletingLastPathComponent()
            .appendingPathComponent("temp_\(UUID().uuidString).xlsx")

        let data = try OOXMLWriter.generate(transactions: transactions)
        try data.write(to: tempURL, options: .atomic)

        // 3. Atomic Move：覆盖原文件
        let fm = FileManager.default
        if fm.fileExists(atPath: xlsxURL.path) {
            _ = try fm.replaceItemAt(xlsxURL, withItemAt: tempURL,
                                      backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: tempURL, to: xlsxURL)
        }
    }

    // MARK: - 导入（读取 xlsx / xls / csv）

    func importFromXlsx() throws -> [Transaction] {
        guard FileManager.default.fileExists(atPath: xlsxURL.path) else { return [] }
        let data = try Data(contentsOf: xlsxURL)
        return try OOXMLReader.parse(data: data)
    }

    func importAny(from url: URL, data: Data) throws -> [Transaction] {
        let ext = url.pathExtension.lowercased()
        appLog("importAny ext=\(ext) dataSize=\(data.count)")
        switch ext {
        case "xlsx":
            appLog("走 OOXML 解析路径")
            return try OOXMLReader.parse(data: data)
        case "xls":
            appLog("走 XLS 二进制解析路径")
            let rows = try XlsReader.parse(data: data)
            appLog("XLS rows=\(rows.count)")
            return XlsReader.rowsToTransactions(rows)
        case "csv":
            appLog("走 CSV 解析路径")
            return try CSVImporter.parse(data: data)
        default:
            appLog("未知扩展名，依次尝试 xlsx→xls→csv")
            if let ts = try? OOXMLReader.parse(data: data), !ts.isEmpty {
                appLog("OOXML 成功 \(ts.count) 条")
                return ts
            }
            if let rows = try? XlsReader.parse(data: data) {
                let ts = XlsReader.rowsToTransactions(rows)
                if !ts.isEmpty { appLog("XLS fallback 成功 \(ts.count) 条"); return ts }
            }
            appLog("最终走 CSV fallback")
            return try CSVImporter.parse(data: data)
        }
    }

    // MARK: - 备份（最多保留 30 份）

    private func makeBackup() {
        guard FileManager.default.fileExists(atPath: xlsxURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let name = "\(formatter.string(from: Date())).xlsx"
        let dest = backupDir.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: xlsxURL, to: dest)
        pruneBackups()
    }

    private func pruneBackups() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupDir,
                                                       includingPropertiesForKeys: [.creationDateKey],
                                                       options: .skipsHiddenFiles) else { return }
        let sorted = files.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return d1 > d2
        }
        // 删除超出 30 份的旧备份
        sorted.dropFirst(30).forEach { try? fm.removeItem(at: $0) }
    }
}

// MARK: - 轻量 OOXML 生成器

enum OOXMLWriter {
    static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    static func generate(transactions: [Transaction]) throws -> Data {
        var balance: Decimal = 0
        let rows = transactions.map { t -> String in
            balance += (t.type == .income ? t.amount : -t.amount)
            return """
            <row>
              <c t="inlineStr"><is><t>\(dateFmt.string(from: t.date))</t></is></c>
              <c t="inlineStr"><is><t>\(t.type.rawValue.xmlEscaped)</t></is></c>
              <c><v>\(t.amount)</v></c>
              <c><v>\(balance)</v></c>
              <c t="inlineStr"><is><t>\(t.category.rawValue.xmlEscaped)</t></is></c>
              <c t="inlineStr"><is><t>\(t.note.xmlEscaped)</t></is></c>
            </row>
            """
        }.joined(separator: "\n")

        let header = """
        <row>
          <c t="inlineStr"><is><t>日期</t></is></c>
          <c t="inlineStr"><is><t>类型</t></is></c>
          <c t="inlineStr"><is><t>金额</t></is></c>
          <c t="inlineStr"><is><t>余额</t></is></c>
          <c t="inlineStr"><is><t>分类</t></is></c>
          <c t="inlineStr"><is><t>备注</t></is></c>
        </row>
        """

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        \(header)
        \(rows)
          </sheetData>
        </worksheet>
        """

        return try buildXlsxArchive(sheetXML: sheetXML)
    }

    // 构建最小化的 .xlsx ZIP 包
    private static func buildXlsxArchive(sheetXML: String) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="记账明细" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """

        let files: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheetXML.utf8)),
        ]

        return ZipArchiveBuilder.build(files: files)
    }
}

// MARK: - 轻量 OOXML 解析器

enum OOXMLReader {
    static func parse(data: Data) throws -> [Transaction] {
        guard let zip = try? ZipArchiveReader.read(data: data),
              let sheetData = zip["xl/worksheets/sheet1.xml"] else {
            throw SyncError.parseError("无法读取 xlsx 文件内容")
        }
        // 读取共享字符串表（ExcelJS 等工具生成的 xlsx 使用此格式）
        let sharedStrings = parseSharedStrings(zip["xl/sharedStrings.xml"])
        let xml = String(data: sheetData, encoding: .utf8) ?? ""
        let rows = extractRows(xml: xml, sharedStrings: sharedStrings)

        // 先尝试 app 导出格式（有 UUID）
        let appFormat = parseAppFormat(rows: rows)
        if !appFormat.isEmpty { return appFormat }

        // 再尝试自定义格式（日期/金额/余额/备注）
        return parseAutoFormat(rows: rows)
    }

    // MARK: 共享字符串表
    private static func parseSharedStrings(_ data: Data?) -> [String] {
        guard let data = data,
              let xml = String(data: data, encoding: .utf8) else { return [] }
        var result: [String] = []
        let siPattern = try? NSRegularExpression(pattern: "<si>(.*?)</si>", options: .dotMatchesLineSeparators)
        let tPattern  = try? NSRegularExpression(pattern: "<t[^>]*>(.*?)</t>", options: .dotMatchesLineSeparators)
        let full = NSRange(xml.startIndex..., in: xml)
        for m in siPattern?.matches(in: xml, range: full) ?? [] {
            guard let r = Range(m.range(at: 1), in: xml) else { result.append(""); continue }
            let si = String(xml[r])
            let tFull = NSRange(si.startIndex..., in: si)
            var parts: [String] = []
            for t in tPattern?.matches(in: si, range: tFull) ?? [] {
                if let tr = Range(t.range(at: 1), in: si) { parts.append(String(si[tr]).xmlUnescaped) }
            }
            result.append(parts.joined())
        }
        return result
    }

    // MARK: 提取所有行的单元格值
    private static func extractRows(xml: String, sharedStrings: [String]) -> [[String]] {
        var result: [[String]] = []
        // 匹配每个 <row ...>...</row>
        let rowPat  = try? NSRegularExpression(pattern: #"<row\b[^>]*>(.*?)</row>"#, options: .dotMatchesLineSeparators)
        // 匹配单元格：<c r="A1" t="s"><v>0</v></c>  or  <c ...><is><t>text</t></is></c>
        let cellPat = try? NSRegularExpression(pattern: #"<c\b([^>]*)>(.*?)</c>"#, options: .dotMatchesLineSeparators)
        let tPat    = try? NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#, options: .dotMatchesLineSeparators)
        let vPat    = try? NSRegularExpression(pattern: #"<v>(.*?)</v>"#, options: .dotMatchesLineSeparators)

        let fullRange = NSRange(xml.startIndex..., in: xml)
        for rowMatch in rowPat?.matches(in: xml, range: fullRange) ?? [] {
            guard let rowRange = Range(rowMatch.range(at: 1), in: xml) else { continue }
            let rowXML = String(xml[rowRange])
            var cols: [(col: Int, value: String)] = []

            let rowNS = NSRange(rowXML.startIndex..., in: rowXML)
            for cellMatch in cellPat?.matches(in: rowXML, range: rowNS) ?? [] {
                guard let attrRange = Range(cellMatch.range(at: 1), in: rowXML),
                      let bodyRange = Range(cellMatch.range(at: 2), in: rowXML) else { continue }
                let attr = String(rowXML[attrRange])
                let body = String(rowXML[bodyRange])

                // 列号：从 r="B3" 提取列字母
                let colIdx = columnIndex(from: attr)

                let value: String
                if attr.contains("t=\"s\"") {
                    // shared string reference
                    let bodyNS = NSRange(body.startIndex..., in: body)
                    if let vm = vPat?.firstMatch(in: body, range: bodyNS),
                       let vr = Range(vm.range(at: 1), in: body),
                       let idx = Int(body[vr]), idx < sharedStrings.count {
                        value = sharedStrings[idx]
                    } else { value = "" }
                } else if attr.contains("t=\"inlineStr\"") || body.contains("<is>") {
                    // inline string
                    let bodyNS = NSRange(body.startIndex..., in: body)
                    var parts: [String] = []
                    for tm in tPat?.matches(in: body, range: bodyNS) ?? [] {
                        if let tr = Range(tm.range(at: 1), in: body) { parts.append(String(body[tr]).xmlUnescaped) }
                    }
                    value = parts.joined()
                } else {
                    // number or formula result
                    let bodyNS = NSRange(body.startIndex..., in: body)
                    if let vm = vPat?.firstMatch(in: body, range: bodyNS),
                       let vr = Range(vm.range(at: 1), in: body) {
                        value = String(body[vr]).xmlUnescaped
                    } else { value = "" }
                }
                cols.append((col: colIdx, value: value))
            }

            // 填充到数组（按列号对齐，允许稀疏）
            if cols.isEmpty { continue }
            let maxCol = (cols.map(\.col).max() ?? 0) + 1
            var row = Array(repeating: "", count: maxCol)
            for c in cols { if c.col < maxCol { row[c.col] = c.value } }
            result.append(row)
        }
        return result
    }

    // 从单元格属性字符串中提取列号（A=0, B=1, ...）
    private static func columnIndex(from attr: String) -> Int {
        // 找 r="XN" 中的列字母部分
        guard let rng = attr.range(of: #"r="([A-Z]+)\d+""#, options: .regularExpression) else { return 0 }
        let token = String(attr[rng]).replacingOccurrences(of: "r=\"", with: "").filter { $0.isLetter }
        return token.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    // MARK: App 标准格式（含 UUID）
    private static func parseAppFormat(rows: [[String]]) -> [Transaction] {
        var results: [Transaction] = []
        let iso = ISO8601DateFormatter()
        for (i, values) in rows.enumerated() {
            guard i > 0, values.count >= 9 else { continue }
            guard let date     = iso.date(from: values[0]),
                  let type     = TransactionType(rawValue: values[1]),
                  let amount   = Decimal(string: values[2]),
                  let category = TransactionCategory(rawValue: values[3]),
                  let id       = UUID(uuidString: values[5]),
                  let modified = iso.date(from: values[6]) else { continue }
            results.append(Transaction(id: id, date: date, type: type, amount: amount,
                category: category, note: values[4], modifiedAt: modified,
                sourceDevice: values[7], isConflict: values[8] == "true"))
        }
        return results
    }

    // MARK: 自定义格式（日期/金额/余额/备注）
    private static func parseAutoFormat(rows: [[String]]) -> [Transaction] {
        var results: [Transaction] = []
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        for (i, values) in rows.enumerated() {
            guard i > 0, values.count >= 2 else { continue }
            let dateStr = values[0]
            guard !dateStr.isEmpty else { continue }

            // 解析金额（B列）
            let amtStr = values[1].replacingOccurrences(of: ",", with: "")
            guard let amtDouble = Double(amtStr), amtDouble != 0 else { continue }
            guard let amount = Decimal(string: String(format: "%.2f", abs(amtDouble))) else { continue }

            // 解析日期：支持 "M月d日" / "yyyy-MM-dd" / ISO8601
            let date: Date
            if let d = parseChineseDateXlsx(dateStr, cal: cal) { date = d }
            else if let d = ISO8601DateFormatter().date(from: dateStr) { date = d }
            else { date = now }

            let type: TransactionType = amtDouble >= 0 ? .income : .expense
            let note = values.count >= 4 ? values[3] : ""
            let category = CSVImporter.guessCategory(note: note, isIncome: amtDouble >= 0)

            results.append(Transaction(date: date, type: type, amount: amount,
                category: category, note: note, sourceDevice: "xlsx导入"))
        }
        return results
    }

    private static func parseChineseDateXlsx(_ s: String, cal: Calendar) -> Date? {
        // 匹配 "4月2日" 或 "04月02日"
        let pat = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
        let ns = s as NSString
        if let m = pat?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let mo = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let dy = Int(ns.substring(with: m.range(at: 2))) ?? 0
            var comps = DateComponents(); comps.year = 2026; comps.month = mo; comps.day = dy
            return cal.date(from: comps)
        }
        return nil
    }
}

// MARK: - CSV 导入器

enum CSVImporter {
    static func parse(data: Data) throws -> [Transaction] {
        let encoding: String.Encoding = data.prefix(3) == Data([0xEF,0xBB,0xBF]) ? .utf8 : .utf8
        guard var text = String(data: data, encoding: encoding)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw SyncError.parseError("CSV 编码无法识别")
        }
        // Remove BOM
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        func splitCSV(_ line: String) -> [String] {
            var fields = [String](); var cur = ""; var inQ = false
            for ch in line {
                if ch == "\"" { inQ.toggle() }
                else if ch == "," && !inQ { fields.append(cur); cur = "" }
                else { cur.append(ch) }
            }
            fields.append(cur)
            return fields.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let header = splitCSV(lines[0]).map { $0.lowercased() }
        let hasAppFormat = header.contains("uuid") || header.contains("类型")

        if hasAppFormat {
            return parseAppCSV(lines: lines, splitCSV: splitCSV)
        } else {
            return parseAutoCSV(lines: lines, splitCSV: splitCSV)
        }
    }

    private static func parseAppCSV(lines: [String], splitCSV: (String) -> [String]) -> [Transaction] {
        let iso = ISO8601DateFormatter()
        var results = [Transaction]()
        for line in lines.dropFirst() {
            let f = splitCSV(line)
            guard f.count >= 9,
                  let date     = iso.date(from: f[0]),
                  let type     = TransactionType(rawValue: f[1]),
                  let amount   = Decimal(string: f[2]),
                  let category = TransactionCategory(rawValue: f[3]),
                  let id       = UUID(uuidString: f[5]),
                  let modified = iso.date(from: f[6]) else { continue }
            results.append(Transaction(id: id, date: date, type: type, amount: amount,
                                       category: category, note: f[4],
                                       modifiedAt: modified, sourceDevice: f[7],
                                       isConflict: f[8] == "true"))
        }
        return results
    }

    private static func parseAutoCSV(lines: [String], splitCSV: (String) -> [String]) -> [Transaction] {
        var dataLines = lines
        let first = splitCSV(lines[0])
        if let s = first.first, !s.contains("月") { dataLines = Array(lines.dropFirst()) }

        var results = [Transaction]()
        let now = Date()
        for line in dataLines {
            let f = splitCSV(line)
            guard f.count >= 2 else { continue }
            let dateStr = f[0]
            guard let amtVal = Double(f[1].replacingOccurrences(of: ",", with: "")) else { continue }
            let note = f.count >= 4 ? f[3] : (f.count >= 3 ? f[2] : "")
            let date = parseChineseDate(dateStr) ?? now
            let type: TransactionType = amtVal >= 0 ? .income : .expense
            guard let amount = Decimal(string: String(format: "%.2f", abs(amtVal))) else { continue }
            let category = guessCategory(note: note, isIncome: amtVal >= 0)
            results.append(Transaction(date: date, type: type, amount: amount,
                                       category: category, note: note,
                                       sourceDevice: "CSV导入"))
        }
        return results
    }

    private static func parseChineseDate(_ s: String) -> Date? {
        let pat = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
        let ns = s as NSString
        if let m = pat?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let mo = ns.substring(with: m.range(at: 1))
            let dy = ns.substring(with: m.range(at: 2))
            var c = Calendar.current; c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var comps = DateComponents(); comps.year = 2026; comps.month = Int(mo); comps.day = Int(dy)
            return c.date(from: comps)
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    static func guessCategory(note: String, isIncome: Bool) -> TransactionCategory {
        if isIncome {
            if note.contains("快递") { return .expressRefund }
            if note.contains("尾款") { return .clientBalance }
            return .clientDeposit
        } else {
            if note.contains("底薪") { return .baseSalary }
            if note.contains("绩效") { return .performance }
            if note.contains("物业") || note.contains("电费") || note.contains("房") { return .rent }
            if note.contains("资料") || note.contains("物流") { return .logistics }
            if note.contains("广告") { return .advertising }
            return .custom
        }
    }
}

enum SyncError: Error {
    case parseError(String)
    case writeError(String)
    case conflictDetected([ConflictPair])
}

extension String {
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    var xmlUnescaped: String {
        self.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
