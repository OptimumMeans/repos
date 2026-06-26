// ReposApp — native SwiftUI menu-bar app (MenuBarExtra) that replaces the
// SwiftBar plugin: a Dropbox-style popover for toggling GitHub repos on/off and
// browsing on-disk repos. `repo` / `gh` are the backend engine.
import SwiftUI

@main
struct ReposApp: App {
    @StateObject private var model = ReposModel()
    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: "shippingbox.fill")
        }
        .menuBarExtraStyle(.window)   // popover window, not a plain menu
    }
}
