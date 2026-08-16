import AppKit
import CodexGaugeAppKit

let application = NSApplication.shared
let applicationDelegate = CodexGaugeApplicationDelegate()

application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()

withExtendedLifetime(applicationDelegate) {}
