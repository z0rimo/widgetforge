import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .atEnd))
    }
}

struct Entry: TimelineEntry { let date: Date }

@main
struct DemoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DemoWidget", provider: Provider()) { _ in Text("Hello") }
    }
}
