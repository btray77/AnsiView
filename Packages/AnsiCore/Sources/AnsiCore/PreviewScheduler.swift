import Foundation

/// Runs the latest of a stream of requests (image import ruling 10): waits `delay` after the
/// last request (debouncing slider drags), runs the work on a serial background queue, and
/// delivers only the newest result. Older work sees `isCancelled()` turn true so it can stop.
public final class PreviewScheduler<Result> {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let deliver: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval = 0.12,
                queue: DispatchQueue = DispatchQueue(label: "com.traynham.ansiview.preview", qos: .userInitiated),
                deliver: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
        self.deliver = deliver
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return g == generation
    }

    /// Replaces any pending request. `work` returns nil when it gave up (cancelled).
    public func request(_ work: @escaping (_ isCancelled: @escaping () -> Bool) -> Result?,
                        completion: @escaping (Result) -> Void) {
        lock.lock()
        generation += 1
        let g = generation
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(g) else { return }
            guard let result = work({ [weak self] in !(self?.isCurrent(g) ?? false) }), self.isCurrent(g) else { return }
            self.deliver.async { [weak self] in
                if self?.isCurrent(g) == true { completion(result) }
            }
        }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops pending and running requests; nothing more is delivered until the next request.
    public func cancel() {
        lock.lock()
        generation += 1
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
