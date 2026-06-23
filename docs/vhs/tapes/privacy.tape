Output "/Users/mattriley/Documents/projects/personal/agengit/docs/vhs/images/privacy.gif"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 65ms

Type "source /Users/mattriley/Documents/projects/personal/agengit/docs/vhs/runtime.env"
Enter
Sleep 800ms
Type "cd $AGIT_REPO_PATH"
Enter
Sleep 700ms
Type "HOME=$AGIT_HOME $AGIT_BIN privacy scan"
Sleep 500ms
Enter
Sleep 3s
