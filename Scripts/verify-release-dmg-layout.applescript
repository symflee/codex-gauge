on run arguments
    if (count of arguments) is not 1 then
        error "Usage: verify-release-dmg-layout.applescript <mount-path>"
    end if

    set mountPath to item 1 of arguments
    set mountedVolume to (POSIX file mountPath) as alias
    set layoutVerified to false

    tell application "Finder"
        set targetDisk to item mountedVolume
        tell targetDisk
            open
            delay 1
            set targetWindow to container window
            set viewOptions to icon view options of targetWindow
            set guideItem to first item whose name contains "Installation"
            set expectedBounds to {100, 100, 740, 520}
            set actualBounds to bounds of targetWindow
            set actualView to current view of targetWindow
            set toolbarIsVisible to toolbar visible of targetWindow
            set statusBarIsVisible to statusbar visible of targetWindow
            set pathBarIsVisible to pathbar visible of targetWindow
            set actualIconSize to icon size of viewOptions
            set appPosition to position of item "Codex Gauge.app"
            set applicationsPosition to position of item "Applications"
            set guidePosition to position of guideItem

            if (actualBounds is expectedBounds) and ¬
                (actualView is icon view) and ¬
                (toolbarIsVisible is false) and ¬
                (statusBarIsVisible is false) and ¬
                (pathBarIsVisible is false) and ¬
                (actualIconSize is 96) and ¬
                (appPosition is {145, 180}) and ¬
                (applicationsPosition is {495, 180}) and ¬
                (guidePosition is {320, 300}) then
                set layoutVerified to true
            end if

            close targetWindow
        end tell
    end tell

    if layoutVerified is false then
        error "Mounted DMG does not contain the expected Finder layout"
    end if
end run
