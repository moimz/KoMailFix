import SwiftUI

@main
struct KoMailFixApp: App {
    init() {
        _ = Updater.shared
    }

    var body: some Scene {
        Window("KoMailFix", id: "main") {
            ContentView()
                .frame(minWidth: 560, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { UpdateMenuButton() }
        }
    }
}

/// 메뉴 KoMailFix > 업데이트 확인… (확인 중에는 흐리게)
private struct UpdateMenuButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
