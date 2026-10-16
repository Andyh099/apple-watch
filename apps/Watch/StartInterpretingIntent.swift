import AppIntents
import Foundation

struct StartInterpretingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始中英口译"
    static var description = IntentDescription("在手表前台打开连续中英口译，不播放应用开场白。")
    static var openAppWhenRun = true
    @available(watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Schedule without awaiting the network or recording permission dialog in Siri.
        // The active view performs a normal launch; this flag handles an already open app.
        NotificationCenter.default.post(name: .startInterpreter, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let startInterpreter = Notification.Name("startInterpreter")
}

struct InterpreterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartInterpretingIntent(), phrases: [
            "用\(.applicationName)开始口译",
            "Start interpreting with \(.applicationName)"
        ], shortTitle: "开始中英口译", systemImageName: "waveform")
    }
}
