on run arguments
    if (count of arguments) is not 1 then
        error "Usage: set-invalid-dmg-layout.applescript <folder-path>"
    end if

    set folderPath to item 1 of arguments
    set folderAlias to (POSIX file folderPath) as alias

    tell application "Finder"
        set targetFolder to item folderAlias
        tell targetFolder
            open
            set current view of container window to icon view
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set position of item "Codex Gauge.app" to {80, 80}
            update without registering applications
            delay 1
            close container window
        end tell
    end tell
end run
