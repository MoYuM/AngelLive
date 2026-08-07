
import Foundation

extension UserDefaults {
    // App Group 未在 entitlements 里声明时 UserDefaults(suiteName:) 返回 nil；
    // 换 Team/Bundle ID 但还没重新申请 App Group 的构建下会命中这条路径，
    // 降级用 .standard（跟 TopShelf 扩展的数据同步会失效，但不至于崩溃）。
    static let shared = UserDefaults(suiteName: "group.dev.idog.angellivetvos") ?? .standard

    func synchronized() -> UserDefaults {
        return UserDefaults(suiteName: "group.dev.idog.angellivetvos") ?? .standard
    }

    // UserDefaults 自身即线程安全(Apple 文档明示),此前的私有串行队列包装
    // 没有额外收益,反而让 Any? 跨 @Sendable 闭包传递制造并发警告,故改为直调。
    func set(_ value: Any?, forKey key: String, synchronize: Bool) {
        set(value, forKey: key)
        if synchronize {
            self.synchronize()
        }
    }

    func value(forKey key: String, synchronize: Bool) -> Any? {
        return value(forKey: key)
    }
}
