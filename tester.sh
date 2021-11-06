#!/usr/bin/env bash

check() {
	inp_str=$1
	expect_str=$2

	out=$(echo $inp_str | ./smdsh -quiet | tr -d '\0') # ignore null characters as we don't see em

	if [[ "$out" == "$expect_str" ]]; then
		echo PASS
	else
		echo FAIL: got \"$out\", expected \"$expect_str\"
	fi
}

check "file README.md" "README.md: ASCII text"

check "get 0" "storing \"\""
check "exit" ""

check "" ""

