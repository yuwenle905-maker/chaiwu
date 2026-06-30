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

    // MARK: - 导入（读取 xlsx）

    func importFromXlsx() throws -> [Transaction] {
        guard FileManager.default.fileExists(atPath: xlsxURL.path) else { return [] }
        let data = try Data(contentsOf: xlsxURL)
        return try OOXMLReader.parse(data: data)
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
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    static func generate(transactions: [Transaction]) throws -> Data {
        let rows = transactions.map { t -> String in
            let date = dateFormatter.string(from: t.date)
            let modified = dateFormatter.string(from: t.modifiedAt)
            return """
            <row>
              <c t="inlineStr"><is><t>\(date)</t></is></c>
              <c t="inlineStr"><is><t>\(t.type.rawValue.xmlEscaped)</t></is></c>
              <c><v>\(t.amount)</v></c>
              <c t="inlineStr"><is><t>\(t.category.rawValue.xmlEscaped)</t></is></c>
              <c t="inlineStr"><is><t>\(t.note.xmlEscaped)</t></is></c>
              <c t="inlineStr"><is><t>\(t.id.uuidString)</t></is></c>
              <c t="inlineStr"><is><t>\(modified)</t></is></c>
              <c t="inlineStr"><is><t>\(t.sourceDevice.xmlEscaped)</t></is></c>
              <c t="inlineStr"><is><t>\(t.isConflict ? "true" : "false")</t></is></c>
            </row>
            """
        }.joined(separator: "\n")

        let header = """
        <row>
          <c t="inlineStr"><is><t>日期</t></is></c>
          <c t="inlineStr"><is><t>类型</t></is></c>
          <c t="inlineStr"><is><t>金额</t></is></c>
          <c t="inlineStr"><is><t>分类</t></is></c>
          <c t="inlineStr"><is><t>备注</t></is></c>
          <c t="inlineStr"><is><t>UUID</t></is></c>
          <c t="inlineStr"><is><t>修改时间</t></is></c>
          <c t="inlineStr"><is><t>来源设备</t></is></c>
          <c t="inlineStr"><is><t>冲突标记</t></is></c>
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
        // 使用 CoreXLSX 解析，fallback 到基础 XML 解析
        // 实际项目中集成 CoreXLSX SPM 包替换此实现
        guard let zip = try? ZipArchiveReader.read(data: data),
              let sheetData = zip["xl/worksheets/sheet1.xml"] else {
            throw SyncError.parseError("无法读取 xlsx 文件内容")
        }

        let xml = String(data: sheetData, encoding: .utf8) ?? ""
        return parseSheetXML(xml)
    }

    private static func parseSheetXML(_ xml: String) -> [Transaction] {
        // 提取所有 <row> 的内联字符串值
        var transactions: [Transaction] = []
        let rowPattern = try? NSRegularExpression(pattern: "<row>(.*?)</row>", options: .dotMatchesLineSeparators)
        let cellPattern = try? NSRegularExpression(pattern: "<t>(.*?)</t>|<v>(.*?)</v>")

        let fullRange = NSRange(xml.startIndex..., in: xml)
        let rows = rowPattern?.matches(in: xml, range: fullRange) ?? []

        for (i, rowMatch) in rows.enumerated() {
            guard i > 0 else { continue } // 跳过表头
            guard let rowRange = Range(rowMatch.range(at: 1), in: xml) else { continue }
            let rowXML = String(xml[rowRange])
            let cellRange = NSRange(rowXML.startIndex..., in: rowXML)
            let cells = cellPattern?.matches(in: rowXML, range: cellRange) ?? []

            var values: [String] = []
            for cell in cells {
                for g in 1...2 {
                    if let r = Range(cell.range(at: g), in: rowXML) {
                        values.append(String(rowXML[r]).xmlUnescaped)
                        break
                    }
                }
            }

            guard values.count >= 9 else { continue }
            guard
                let date = ISO8601DateFormatter().date(from: values[0]),
                let type = TransactionType(rawValue: values[1]),
                let amount = Decimal(string: values[2]),
                let category = TransactionCategory(rawValue: values[3]),
                let id = UUID(uuidString: values[5]),
                let modifiedAt = ISO8601DateFormatter().date(from: values[6])
            else { continue }

            transactions.append(Transaction(
                id: id, date: date, type: type, amount: amount, category: category,
                note: values[4], modifiedAt: modifiedAt, sourceDevice: values[7],
                isConflict: values[8] == "true"
            ))
        }
        return transactions
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
