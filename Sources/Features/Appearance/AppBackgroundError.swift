import Foundation

/// 外观校验与保存失败由外观功能定义，不借用壁纸库的错误类型。
enum AppBackgroundError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}
