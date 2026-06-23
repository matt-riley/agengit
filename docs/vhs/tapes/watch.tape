Output "./docs/vhs/images/watch.gif"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 65ms

Type "source ./docs/vhs/runtime.env"
Enter
Sleep 800ms
Type "cd $AGIT_REPO_PATH"
Enter
Sleep 700ms
Type "HOME=$AGIT_HOME $AGIT_BIN watch --since $AGIT_WATCH_SINCE --interval 250ms"
Sleep 500ms
Enter
Sleep 3s
Ctrl+C
Sleep 1s
