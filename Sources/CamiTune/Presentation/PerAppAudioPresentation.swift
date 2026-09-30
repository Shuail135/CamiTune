import Combine
import Foundation

@MainActor
final class PerAppMeterState: ObservableObject {
    @Published private(set) var level: Double = 0

    func update(_ value: Double) {
        let value = value.isFinite ? min(1, max(0, value)) : 0
        if level != value { level = value }
    }
}

/// Only metadata/settings changes invalidate the list. Each visible meter
/// observes its own stable object, independent of sorting and row hosting.
@MainActor
final class PerAppAudioPresentation: ObservableObject {
    @Published private(set) var applications: [PerAppAudioApplication] = []
    @Published private(set) var persistenceError: String?
    private var meters: [String: PerAppMeterState] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init(controller: PerAppAudioController? = nil) {
        guard let controller else { return }
        update(controller.applications)
        persistenceError = controller.persistenceError
        controller.$applications.receive(on: RunLoop.main).sink { [weak self] in
            self?.update($0)
        }.store(in: &subscriptions)
        controller.$persistenceError.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] in
            self?.persistenceError = $0
        }.store(in: &subscriptions)
    }

    func meter(for id: String) -> PerAppMeterState {
        if let meter = meters[id] { return meter }
        let meter = PerAppMeterState()
        meters[id] = meter
        return meter
    }

    func update(_ snapshot: [PerAppAudioApplication]) {
        let ids = Set(snapshot.map(\.id))
        for (id, meter) in meters where !ids.contains(id) { meter.update(0) }
        meters = meters.filter { ids.contains($0.key) }
        let metadata = snapshot.map { app in
            meter(for: app.id).update(app.level)
            var app = app
            app.level = 0
            return app
        }
        if applications != metadata { applications = metadata }
    }
}
