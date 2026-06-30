using ChaiWu.Windows.Models;
using ClosedXML.Excel;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace ChaiWu.Windows.Services;

public class XlsxService
{
    public static readonly XlsxService Instance = new();

    // OneDrive 路径（用户可在设置中修改）
    public string XlsxPath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        "OneDrive", "ChaiWu", "chaiwu_data.xlsx");

    private string BackupDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ChaiWu", "backups");

    public void Export(IEnumerable<Transaction> transactions)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(XlsxPath)!);
        MakeBackup();

        // 写入临时文件，然后原子替换
        var tempPath = Path.Combine(Path.GetDirectoryName(XlsxPath)!, $"temp_{Guid.NewGuid()}.xlsx");

        using (var wb = new XLWorkbook())
        {
            var ws = wb.Worksheets.Add("记账明细");

            // 表头
            string[] headers = ["日期", "类型", "金额", "分类", "备注", "UUID", "修改时间", "来源设备", "冲突标记"];
            for (int i = 0; i < headers.Length; i++)
            {
                var cell = ws.Cell(1, i + 1);
                cell.Value = headers[i];
                cell.Style.Font.Bold = true;
                cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#4F81BD");
                cell.Style.Font.FontColor = XLColor.White;
            }

            // 数据行
            int row = 2;
            foreach (var t in transactions.OrderByDescending(x => x.Date))
            {
                ws.Cell(row, 1).Value = t.Date.ToString("yyyy-MM-dd HH:mm:ss");
                ws.Cell(row, 2).Value = t.Type.ToString();
                ws.Cell(row, 3).Value = t.Amount;
                ws.Cell(row, 3).Style.NumberFormat.Format = "#,##0.00";
                ws.Cell(row, 4).Value = t.Category.ToString();
                ws.Cell(row, 5).Value = t.Note;
                ws.Cell(row, 6).Value = t.Id.ToString();
                ws.Cell(row, 7).Value = t.ModifiedAt.ToString("O");
                ws.Cell(row, 8).Value = t.SourceDevice;
                ws.Cell(row, 9).Value = t.IsConflict ? "true" : "false";

                // 冲突行标红
                if (t.IsConflict)
                    ws.Row(row).Style.Fill.BackgroundColor = XLColor.LightSalmon;

                row++;
            }

            ws.Columns().AdjustToContents();
            wb.SaveAs(tempPath);
        }

        // Atomic replace
        File.Replace(tempPath, XlsxPath, null);
    }

    public List<Transaction> Import()
    {
        if (!File.Exists(XlsxPath)) return [];

        using var wb = new XLWorkbook(XlsxPath);
        var ws = wb.Worksheet(1);
        var results = new List<Transaction>();

        foreach (var row in ws.RowsUsed().Skip(1)) // 跳过表头
        {
            try
            {
                if (!Guid.TryParse(row.Cell(6).GetString(), out var id)) continue;
                if (!DateTime.TryParse(row.Cell(1).GetString(), out var date)) continue;
                if (!Enum.TryParse<TransactionType>(row.Cell(2).GetString(), out var type)) continue;
                if (!decimal.TryParse(row.Cell(3).GetString(), out var amount)) continue;
                if (!Enum.TryParse<TransactionCategory>(row.Cell(4).GetString(), out var category)) continue;
                if (!DateTime.TryParse(row.Cell(7).GetString(), out var modifiedAt)) continue;

                results.Add(new Transaction
                {
                    Id = id, Date = date, Type = type, Amount = amount, Category = category,
                    Note = row.Cell(5).GetString(), ModifiedAt = modifiedAt,
                    SourceDevice = row.Cell(8).GetString(),
                    IsConflict = row.Cell(9).GetString() == "true"
                });
            }
            catch { /* 跳过无法解析的行 */ }
        }
        return results;
    }

    private void MakeBackup()
    {
        if (!File.Exists(XlsxPath)) return;
        Directory.CreateDirectory(BackupDir);
        var name = $"{DateTime.Now:yyyyMMdd_HHmm}.xlsx";
        File.Copy(XlsxPath, Path.Combine(BackupDir, name), overwrite: true);
        PruneBackups();
    }

    private void PruneBackups()
    {
        var files = Directory.GetFiles(BackupDir, "*.xlsx")
                             .OrderByDescending(f => File.GetCreationTime(f))
                             .Skip(30);
        foreach (var f in files) File.Delete(f);
    }
}
