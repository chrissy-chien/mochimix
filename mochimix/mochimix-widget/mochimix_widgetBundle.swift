//
//  mochimix_widgetBundle.swift
//  mochimix-widget
//
//  Created by Chrissy Chien on 7/8/26.
//

import WidgetKit
import SwiftUI

// WidgetBundle is the entry point for the widget extension process.
// It lists every widget kind this extension provides. We only have one:
// the recent-items widget. (The template's Control Widget and Live Activity
// were removed since this app doesn't need them.)
@main
struct mochimix_widgetBundle: WidgetBundle {
    var body: some Widget {
        mochimix_widget()
    }
}
