
import Foundation

extension UserDefaults {
    static let shared = UserDefaults(suiteName: "group.dev.idog.angellivetvos")!

    func synchronized() -> UserDefaults {
        return UserDefaults(suiteName: "group.dev.idog.angellivetvos")!
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
