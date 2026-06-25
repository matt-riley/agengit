Output "./docs/vhs/images/between.mp4"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 65ms

Hide
Type "source ./docs/vhs/runtime.env"
Enter
Type "cd $AGIT_REPO_PATH"
Enter
Sleep 500ms
Show
Type "agit between $AGIT_COMMIT_FROM $AGIT_COMMIT_TO"
Sleep 500ms
Enter
Sleep 3s
