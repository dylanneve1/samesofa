// Developer helper: what VoiceOver finds in a running app's windows.
// Usage: swift scripts/dev/ax-dump.swift <pid>
//
// Reads the accessibility tree from outside, the way VoiceOver does (the
// terminal needs Accessibility permission; nothing is clicked or typed).
// Every control is listed with its role, name, value and help; a control
// without a name is marked. The last line counts them.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: ax-dump <pid>")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("This terminal has no Accessibility permission (System Settings > Privacy & Security > Accessibility).")
    exit(1)
}

let interactive: Set<String> = ["AXButton", "AXTextField", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXLink",
                                "AXMenuButton", "AXDisclosureTriangle", "AXIncrementor", "AXComboBox", "AXSwitch", "AXToggle"]
// The window's own buttons and the parts of a scroll bar are the system's.
let systemButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
                                  "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ value: AnyObject?) -> String {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

var controls = 0, unnamed = 0, withHelp = 0

func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 80 else { return }
    let role = text(attribute(element, kAXRoleAttribute)), subrole = text(attribute(element, kAXSubroleAttribute))
    var name = text(attribute(element, kAXDescriptionAttribute))
    if name.isEmpty { name = text(attribute(element, kAXTitleAttribute)) }
    if name.isEmpty, let title = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID() {
        name = text(attribute(title as! AXUIElement, kAXValueAttribute))
    }
    let value = text(attribute(element, kAXValueAttribute)), help = text(attribute(element, kAXHelpAttribute))
    let enabled = (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
    let isControl = interactive.contains(role) && !systemButtons.contains(subrole)
    let container = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXOutline", "AXRadioGroup", "AXPopover", "AXUnknown", ""].contains(role)
    if isControl || !container || !name.isEmpty {
        var line = String(repeating: "  ", count: min(depth, 6)) + "[\(role.replacingOccurrences(of: "AX", with: ""))\(subrole.isEmpty ? "" : "/" + subrole.replacingOccurrences(of: "AX", with: ""))]"
        if !name.isEmpty { line += " name=\"\(name.prefix(120))\"" }
        if !value.isEmpty, value != name { line += " value=\"\(value.prefix(120))\"" }
        if !help.isEmpty { line += " help=\"\(help.prefix(160))\"" }
        if !enabled { line += " (disabled)" }
        if isControl {
            controls += 1
            if !help.isEmpty { withHelp += 1 }
            if name.isEmpty { unnamed += 1; line += "   <-- NO NAME" }
        }
        print(line)
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
}

let app = AXUIElementCreateApplication(pid)
for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(window, depth: 0) }
print("SUMMARY \(controls) interactive controls, \(unnamed) without a name, \(withHelp) with help text")
