Output "/Users/mattriley/Documents/projects/personal/agengit/docs/vhs/images/restore.gif"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 0ms

Type "source ./docs/vhs/runtime.env"
Enter
Type "cd $AGIT_REPO_PATH"
Enter
Type "HOME=$AGIT_HOME $AGIT_BIN restore --dry-run --all $AGIT_STEP_HASH"
Enter
Sleep 2s
