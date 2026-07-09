//
//  mochimix_widgetBundle.swift
//  mochimix-widget
//
//  Created by Chrissy Chien on 7/8/26.
//

import WidgetKit
import SwiftUI

@main
struct mochimix_widgetBundle: WidgetBundle {
    var body: some Widget {
        mochimix_widget()
        mochimix_widgetControl()
        mochimix_widgetLiveActivity()
    }
}
