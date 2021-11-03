debug:
	@clang -Wall -Wextra -nostdlib -nopie -glldb smdsh.S -o smdsh

regular:
	@clang -Wall -Wextra -nostdlib -nopie smdsh.S -o smdsh

