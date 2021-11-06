# include debug information in binary
debug:
	@clang -Wall -Wextra -nostdlib -nopie -glldb smdsh.S -o smdsh

small:
	@clang -Wall -Wextra -nostdlib -nopie -s smdsh.S -o smdsh

test:
	@make --silent debug
	@./tester.sh

