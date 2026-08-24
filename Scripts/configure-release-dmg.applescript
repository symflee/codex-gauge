on run arguments
    if (count of arguments) is not 2 then
        error "Usage: configure-release-dmg.applescript <volume-name> <mount-path>"
    end if

    set volumeName to item 1 of arguments
    set mountPath to item 2 of arguments
    set layoutVerified to false
    set mountedVolume to (POSIX file mountPath) as alias
    set backgroundImage to (POSIX file (mountPath & "/.background/background.png")) as alias

    tell application "Finder"
        set targetDisk to item mountedVolume
        tell targetDisk
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set bounds of container window to {100, 100, 740, 520}

            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set background picture of viewOptions to backgroundImage

            update without registering applications
            set guideItem to first item whose name contains "Installation"
            set position of item "Codex Gauge.app" to {145, 180}
            set position of item "Applications" to {495, 180}
            set position of guideItem to {320, 300}

            repeat with attemptNumber from 1 to 30
                update without registering applications
                set appPosition to position of item "Codex Gauge.app"
                set applicationsPosition to position of item "Applications"
                set guidePosition to position of guideItem
                set expectedBounds to {100, 100, 740, 520}
                set actualBounds to bounds of container window
                set actualView to current view of container window
                set toolbarIsVisible to toolbar visible of container window
                set statusBarIsVisible to statusbar visible of container window
                set pathBarIsVisible to pathbar visible of container window
                set actualIconSize to icon size of viewOptions
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
                    exit repeat
                end if
                if attemptNumber is less than 30 then
                    delay 1
                end if
            end repeat

            close container window
        end tell
    end tell

    if layoutVerified is false then
        error "Finder did not persist the expected DMG layout within 30 seconds"
    end if
end run
