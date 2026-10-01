import Foundation

/// 官网、源码与更新订阅的公开入口；版本附件由 GitHub Releases 分发。
public enum ArcKitDistribution {
    public static let websiteURL = URL(string: "https://arc-kit.com")!
    public static let repositoryURL = URL(string: "https://github.com/huixiangyang/arc-kit")!
    public static let releasesURL = repositoryURL.appendingPathComponent("releases")
    public static let appcastURL = websiteURL.appendingPathComponent("updates/appcast.xml")
}
