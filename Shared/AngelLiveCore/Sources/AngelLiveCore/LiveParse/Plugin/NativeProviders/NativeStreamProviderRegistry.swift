import Foundation

/// Provider 是无状态的解析器,注册表全局共享一份,故要求 `Sendable`。
/// 这样 `providers` / `providersById` 两个 `static let` 才不再被判为非并发安全的全局状态。
protocol NativeStreamProvider: Sendable {
    var providerIds: [String] { get }

    func resolve(options: [String: Any]) async throws -> [String: Any]
}

enum NativeStreamProviderRegistry {
    private static let providers: [NativeStreamProvider] = []

    private static let providersById: [String: NativeStreamProvider] = {
        var result: [String: NativeStreamProvider] = [:]
        for provider in providers {
            for providerId in provider.providerIds {
                let normalizedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalizedId.isEmpty else { continue }
                result[normalizedId] = provider
            }
        }
        return result
    }()

    static func provider(for providerId: String) -> NativeStreamProvider? {
        let normalizedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providersById[normalizedId]
    }
}
