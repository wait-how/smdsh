debug:
	@clang -nostdlib -nopie -glldb smdsh.s -o smdsh

regular:
	@clang -nostdlib -nopie smdsh.s -o smdsh

