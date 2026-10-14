import Combine
import Sparkle
import SwiftUI

/// Sparkle wrapper. Only started inside a bundled, configured build: a `swift run` binary has no Info.plist feed.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        let configured = Platform.isBundled && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        cancellable = controller?.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("Güncellemeleri Denetle…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
