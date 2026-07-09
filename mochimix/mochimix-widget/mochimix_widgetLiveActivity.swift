//
//  mochimix_widgetLiveActivity.swift
//  mochimix-widget
//
//  Created by Chrissy Chien on 7/8/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct mochimix_widgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct mochimix_widgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: mochimix_widgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension mochimix_widgetAttributes {
    fileprivate static var preview: mochimix_widgetAttributes {
        mochimix_widgetAttributes(name: "World")
    }
}

extension mochimix_widgetAttributes.ContentState {
    fileprivate static var smiley: mochimix_widgetAttributes.ContentState {
        mochimix_widgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: mochimix_widgetAttributes.ContentState {
         mochimix_widgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: mochimix_widgetAttributes.preview) {
   mochimix_widgetLiveActivity()
} contentStates: {
    mochimix_widgetAttributes.ContentState.smiley
    mochimix_widgetAttributes.ContentState.starEyes
}
