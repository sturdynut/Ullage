# Menu bar service controls

Agreed behavior: left-click opens the existing dashboard. Right-click and
Control-click open a native menu with Restart Service, a separator, and Quit
Ullage. The dashboard's existing Quit action remains available. Neither action
asks for confirmation.

Restart stops and drains the app's collector, manual sweeps, and plan-limit
requests before starting fresh monitoring and polling. It preserves SQLite
history, user selections, and open windows. Concurrent restarts share one
transition; the action is disabled and shows Restarting… during that transition.
Failure leaves the app open with Monitoring stopped, an error, and a retry action.
Quit prevents new starts, drains app-owned work, and exits. The optional
Homebrew/CLI phone server and installers already launched in Terminal are
separate processes and remain independently managed.

## Platform basis

The package targets macOS 14+, Swift tools 5.9, with no external dependencies.
CI uses Xcode 16.4 / Swift 6.1; local validation uses Xcode 27 / Swift 6.4.

- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
  exposes a public status button. Using it avoids finding or modifying
  SwiftUI's private MenuBarExtra implementation.
- [Local event monitors](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))
  intercept this app's events. The handler filters to the owned button's window
  and bounds, consumes right/Control-clicks, and leaves normal left-click alone.
  The monitor is removed on shutdown.
- [NSMenu.popUpContextMenu](https://developer.apple.com/documentation/appkit/nsmenu/popupcontextmenu(_:with:for:))
  presents the native context menu for the button's event.
- [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller)
  retains the existing SwiftUI dashboard and window content in AppKit containers.
  [Preferred content sizing](https://developer.apple.com/documentation/swiftui/nshostingsizingoptions/preferredcontentsize)
  replaces the old MenuBarExtra window-sizing workaround.
- [applicationShouldTerminate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))
  can return terminateLater, then reply when cleanup finishes. This keeps the
  event loop responsive while active writers finish.
- [Task cancellation is cooperative](https://developer.apple.com/documentation/swift/task/cancel()).
  The current ingestion and network APIs block synchronously, so cancellation
  alone cannot stop them. Restart and Quit await their completion instead.
  An in-flight plan-limit request can delay either action until its timeout.
- [LLVM coverage supports additional objects](https://llvm.org/docs/CommandGuide/llvm-cov.html#llvm-cov-show).
  HTML and LCOV exports include every XCTest binary so either SwiftPM's combined
  test runner or separate app/core test bundles work.

## Verification

App-target regression tests cover click routing and action dispatch, restart
exclusion, startup failure and retry, catch-up without duplicate/deleted history,
and Quit during startup. Tests use temporary databases and ledger/config paths
with Claude network polling disabled. Existing core coverage keeps its 85% floor;
the new app tests run in the same CI test step.

Manual check on macOS: left-click and dismiss the dashboard; right-click and
Control-click the icon; restart twice quickly; confirm monitoring resumes and
history remains; open each full window; Quit and confirm the process exits.
