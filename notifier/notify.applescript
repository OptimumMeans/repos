-- Posts a macOS notification using THIS app's icon (the GitHub mark).
-- Args: <title> <subtitle> <message>
on run argv
	if (count of argv) < 3 then return
	display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
end run
