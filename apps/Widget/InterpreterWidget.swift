import SwiftUI
import WidgetKit

/// 表盘小组件：点一下打开腕译并直接开始翻译。
/// 通过 widgetURL 把 wristinterpreter://start 递给主 App，
/// 主 App 的 onOpenURL 走和 Siri 意图同一条自启路径。
struct InterpreterWidgetProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // 静态图标式小组件：内容不变，不需要定时刷新。
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

struct InterpreterWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Image(systemName: "translate")
        case .accessoryRectangular:
            HStack(spacing: 4) {
                Image(systemName: "translate")
                Text("开始翻译")
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "translate").font(.title3)
                    Text("翻译").font(.caption2)
                }
            }
        }
    }
}

struct InterpreterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.wristinterpreter.prototype.widget",
            provider: InterpreterWidgetProvider()
        ) { _ in
            InterpreterWidgetView()
                .widgetURL(URL(string: "wristinterpreter://start"))
        }
        .configurationDisplayName("腕译")
        .description("点一下打开腕译并直接开始翻译。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct InterpreterWidgetBundle: WidgetBundle {
    var body: some Widget { InterpreterWidget() }
}
