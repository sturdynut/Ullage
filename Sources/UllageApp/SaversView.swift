#if os(macOS)
import AppKit
import SwiftUI
import UllageCore

/// The exact commands, shown before anything runs. Returns true to go ahead.
enum InstallConfirmation {
    @MainActor
    static func confirm(_ plan: InstallPlan) -> Bool {
        let alert = NSAlert()
        let uninstalling = plan.action == .uninstall
        alert.messageText = "\(uninstalling ? "Uninstall" : "Install") \(plan.saver.displayName)?"
        var lines: [String] = []
        if !plan.missing.isEmpty {
            lines.append("Needs \(plan.missing.joined(separator: " and ")), which isn't on this Mac.")
        }
        for (index, step) in plan.steps.enumerated() {
            lines.append("\(index + 1). \(step.purpose)\n    \(step.command)")
        }
        if !plan.steps.isEmpty {
            lines.append("These are \(plan.saver.displayName)'s own commands. They run in Terminal, where you can watch them"
                         + (plan.needsPerson ? " and finish the sign-in." : "."))
        }
        lines += plan.notes
        alert.informativeText = lines.joined(separator: "\n\n")
        guard plan.isRunnable else {
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
        let run = alert.addButton(withTitle: uninstalling ? "Uninstall in Terminal" : "Install in Terminal")
        let cancel = alert.addButton(withTitle: "Cancel")
        if uninstalling {
            // Return must never remove anything: Cancel takes the default.
            alert.alertStyle = .warning
            run.hasDestructiveAction = true
            run.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

#endif
