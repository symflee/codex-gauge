on run arguments
    if (count of arguments) is not 1 then
        error "Usage: resize-dmg-window.applescript <folder-path>"
    end if

    set folderPath to item 1 of arguments
    set folderAlias to (POSIX file folderPath) as alias

    tell application "Finder"
        set targetFolder to item folderAlias
        tell targetFolder
            open
            set bounds of container window to {180, 240, 800, 640}
            update without registering applications
            delay 1
            close container window
        end tell
    end tell
end run
