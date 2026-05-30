//
//  MiliariumWidgetBundle.swift
//  MiliariumWidget
//
//  Created by Gilbert Hong on 5/27/26.
//

import WidgetKit
import SwiftUI

/// `@main` entry for the widget extension. Each `Widget` listed in `body`
/// becomes a separately-installable home-screen widget. Add new widgets
/// here as the extension grows.
@main
struct MiliariumWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpcomingActivitiesWidget()
    }
}
