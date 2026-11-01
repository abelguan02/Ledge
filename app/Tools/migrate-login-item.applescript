-- Run only during the user-approved application switch, after both apps exit.
-- Transfers a manually added login item without creating one for new users.
on run argv
    if (count argv) is not 2 then error "Expected exact old and new application paths"
    set oldPath to item 1 of argv
    set newPath to item 2 of argv
    set newApp to POSIX file newPath as alias
    tell application "System Events"
        set oldItems to every login item whose path is oldPath
        if (count oldItems) is 0 then return "No legacy login item; no change"
        set wasHidden to hidden of item 1 of oldItems
        set newItems to every login item whose path is newPath
        if (count newItems) is 0 then
            make login item at end with properties {path:newPath, hidden:wasHidden}
        end if
        if (count (every login item whose path is newPath)) is 0 then error "New login item was not created; old entry retained"
        delete oldItems
        return "Login item now points to Ledge"
    end tell
end run
