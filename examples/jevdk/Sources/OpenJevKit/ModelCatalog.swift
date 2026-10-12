import Foundation

/// What's in the local Hugging Face cache, by repo id. The SDK only counts a model it downloaded
/// and verified itself (`MLXModelProvider.installed`); this lists the rest, so JevDK can offer to
/// verify a copy fetched by another tool instead of downloading it again.
public enum ModelCatalog {
    /// `~/.cache/huggingface/hub`, or `HF_HUB_CACHE` / `HF_HOME/hub` when set.
    public static var cacheRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"] { return URL(fileURLWithPath: hub) }
        if let home = env["HF_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Repo ids with at least one snapshot holding a `config.json` and safetensors weights.
    public static func cachedRepoIDs() -> [String] {
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(atPath: cacheRoot.path) else { return [] }
        return repos.filter { $0.hasPrefix("models--") }.compactMap { repo in
            let snapshots = cacheRoot.appendingPathComponent(repo).appendingPathComponent("snapshots")
            let hasWeights = ((try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []).contains { rev in
                let files = (try? fm.contentsOfDirectory(atPath: snapshots.appendingPathComponent(rev).path)) ?? []
                return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
            }
            return hasWeights ? String(repo.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/") : nil
        }.sorted()
    }
}
