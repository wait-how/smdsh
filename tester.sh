#!/usr/bin/env bash

check() {
	inp_str=$1
	expect_str=$2

	out=$(echo -e $inp_str | ./smdsh -quiet | tr -d '\0') # ignore null characters as we don't see em

	if [[ "$out" == "$expect_str" ]]; then
		echo PASS
	else
		echo FAIL: got \"$out\", expected \"$expect_str\"
	fi
}

# check basic shell commands
check "file README.md" "README.md: ASCII text"
check "cd ..\ncd smdsh\nfile README.md\n" "README.md: ASCII text"

# check variable storage
check "get 0" "storing \"\""
check "set 0 README.md\nfile \$0\n" "README.md: ASCII text"
check "set 0 README.md\nget 0" "storing \"README.md\""

# check builtins
check "exit" ""
check "" ""

