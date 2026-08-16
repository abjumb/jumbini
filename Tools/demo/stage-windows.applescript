-- Stage two neutral windows for the climb shot and put them at known
-- positions, so the crop and the dog's climb target are both predictable.
-- Bounds are {left, top, right, bottom} in top-left-origin screen points.

on run argv
	set theAction to item 1 of argv

	if theAction is "open" then
		tell application "TextEdit"
			activate
			if (count of documents) is 0 then make new document
			set bounds of window 1 to {320, 260, 1180, 760}
		end tell
		tell application "Finder"
			activate
			-- A freshly logged-in capture account has no Finder window open,
			-- and `set bounds of Finder window 1` on nothing is an error that
			-- takes capture.sh down with it before the first take. Same guard
			-- the TextEdit branch above already has.
			if (count of Finder windows) is 0 then make new Finder window
			set bounds of Finder window 1 to {1240, 420, 1900, 860}
		end tell

	else if theAction is "move" then
		-- A gentle ride: small steps, well under the ~180pt-per-poll
		-- threshold that shakes him off.
		tell application "TextEdit"
			repeat with stepNum from 1 to 12
				set bounds of window 1 to {320 + (stepNum * 14), 260, 1180 + (stepNum * 14), 760}
				delay 0.12
			end repeat
		end tell

	else if theAction is "yank" then
		-- Past the threshold in one poll. This is the shot.
		tell application "TextEdit"
			set bounds of window 1 to {900, 260, 1760, 760}
		end tell

	else if theAction is "close" then
		-- capture.sh runs this from an exit trap as well as at the end of each
		-- take, so it has to be a no-op when there is nothing to close. The
		-- `is running` guards are what stop cleanup from LAUNCHING TextEdit
		-- just to tell it there are no documents.
		if application "TextEdit" is running then
			tell application "TextEdit" to close every document saving no
		end if
		if application "Finder" is running then
			tell application "Finder" to close every window
		end if
	end if
end run
