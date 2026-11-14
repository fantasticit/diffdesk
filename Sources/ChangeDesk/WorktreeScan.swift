import Foundation

enum WorktreeScan {
    static func inspect(
        _ paths: [URL], priority: URL?, bases: [String: String],
        onBatch: @escaping @Sendable ([Worktree]) async -> Void
    ) async {
        var queue = paths
        if let priority, let index = queue.firstIndex(of: priority), index != 0 {
            queue.remove(at: index)
            queue.insert(priority, at: 0)
        }
        let parallelism = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        await withTaskGroup(of: Worktree.self) { group in
            var next = 0
            for _ in 0..<min(parallelism, queue.count) {
                let url = queue[next]
                let base = bases[url.path]
                group.addTask { read(url, base: base) }
                next += 1
            }
            var batch: [Worktree] = []
            var lastDelivery = ContinuousClock.now
            var first = true
            while let repo = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                if next < queue.count {
                    let url = queue[next]
                    let base = bases[url.path]
                    group.addTask { read(url, base: base) }
                    next += 1
                }
                batch.append(repo)
                if first || repo.url == priority || batch.count == 8 || ContinuousClock.now - lastDelivery >= .milliseconds(100) {
                    await onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    lastDelivery = .now
                    first = false
                }
            }
            if !batch.isEmpty { await onBatch(batch) }
        }
    }

    private static func read(_ url: URL, base: String?) -> Worktree {
        do { return try autoreleasepool { try Git.inspect(url, preferredBase: base) } }
        catch { return Worktree(url: url, branch: "读取失败", head: nil, base: nil, ancestor: nil, changes: [], issue: error.localizedDescription) }
    }
}
