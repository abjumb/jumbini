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
		tell application "TextEdit" to close every document saving no
		tell application "Finder" to close every window
	end if
end run
