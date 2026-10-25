import Foundation

@MainActor
public final class ApprovalQueue<Value> {
    private struct Request {
        let continuation: CheckedContinuation<Value?, Never>
        let show: (@escaping (Value?) -> Void) -> Void
        let close: () -> Void
        let timeout: Task<Void, Never>
    }

    private let limit: Int
    private let timeout: Duration
    private var requests: [UUID: Request] = [:]
    private var order: [UUID] = []
    private var active: UUID?

    public init(limit: Int = 8, timeout: Duration = .seconds(60)) {
        self.limit = max(1, limit)
        self.timeout = timeout
    }

    public func ask(show: @escaping (@escaping (Value?) -> Void) -> Void, close: @escaping () -> Void) async -> Value? {
        guard !Task.isCancelled, requests.count < limit else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                let timeout = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, value: nil)
                }
                requests[id] = Request(continuation: continuation, show: show, close: close, timeout: timeout)
                order.append(id)
                showNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, value: nil) }
        }
    }

    public func cancelAll() {
        let pending = requests
        let current = active.flatMap { pending[$0] }
        requests = [:]
        order = []
        active = nil
        current?.close()
        for request in pending.values {
            request.timeout.cancel()
            request.continuation.resume(returning: nil)
        }
    }

    private func finish(_ id: UUID, value: Value?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        request.timeout.cancel()
        if active == id {
            active = nil
            request.close()
        }
        request.continuation.resume(returning: value)
        showNext()
    }

    private func showNext() {
        guard active == nil, let id = order.first, let request = requests[id] else { return }
        active = id
        request.show { [weak self] value in self?.finish(id, value: value) }
    }
}
