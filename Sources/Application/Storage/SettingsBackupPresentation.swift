import ArcKitPersistence
import ArcKitPlatform
import Foundation
import Combine

enum SettingsBackupPresentation {
    /// 备份摘要与导入确认共用应用语言和系统时区。
    static func localizedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjm")
        return formatter.string(from: date)
    }

    /// 文件名使用稳定 ASCII 时间戳，不受地区格式和特殊字符影响。
    static func fileTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}
