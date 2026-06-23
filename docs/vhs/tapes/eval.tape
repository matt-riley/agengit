Output "/Users/mattriley/Documents/projects/personal/agengit/docs/vhs/images/eval.gif"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 0ms

Type "source ./docs/vhs/runtime.env"
Enter
Type "cd $AGIT_REPO_PATH"
Enter
Type "HOME=$AGIT_HOME $AGIT_BIN eval | sed -n '1,30p'"
Enter
Sleep 2s
