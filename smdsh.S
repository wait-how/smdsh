# A simd shell!

#define Version "0.4"

# red zone memory map

#define Argv 0
#define Argv_arg 16
#define Argv_ptr 64
#define Argv_end 120

#define Arg_set 0, 1, 2, 3, 4, 5
#define Var_set 0, 1, 2, 3, 4, 5

# colors for output

#define Yellow "\x1B[1;33m"
#define Green "\x1B[32m"
#define BW "\x1B[0m"

# global register usage

# rbp -> base of red zone
# r8 -> **env

# xmm0 -> command
# xmm1-xmm5 -> args
# xmm10-xmm15 -> variables

# st0 -> command line mode (executes anything from stdin and exits)

.global _start

.text

# read text into str (xmm), clobbering mask (xmm) and returning number of chars in count (gpr)
.macro Read str, mask, count
	cmpb $'\n', (%rbp) # check if we need to do anything at all
	jz L2_\@

	vmovdqu simd_one, \mask
	mov $0, \count

L0_\@:
	# read()
	xor %rax, %rax
	xor %rdi, %rdi
	mov %rbp, %rsi
	mov $1, %rdx
	syscall

	# test if out of space in str
	cmp $16, \count
	jz L1_\@

	# test for arg delimiters or break character
	cmpb $'\t', (%rbp)
	jz L1_\@

	cmpb $' ', (%rbp)
	jz L1_\@

	cmpb $'\n', (%rbp)
	jz L1_\@

	# insert the current string index in mask
	vpslldq $1, \mask, \mask
	vpinsrb $0, \count, \mask, \mask

	# insert the character read in str
	vpslldq $1, \str, \str
	vpinsrb $0, (%rbp), \str, \str

	# increment index
	inc \count

	jmp L0_\@

L1_\@:
	vpshufb \mask, \str, \str # reverse str using mask and zero unused chars

L2_\@:
.endm

.macro Jmp_xmm_sub sub, str, reg, idx, end
	cmp \idx, \reg
	jnz L0_\@
	vmovdqu \sub, \str
	jmp \end
L0_\@:
	inc \idx
.endm

# replaces str (xmm) with xmm reg if str starts with the correct subst character
# reg, idx are trashed
.macro Sub_xmm_arg str, reg, idx
test_reg_\@:
	pextrb $0, \str, \reg
	cmp subst, \reg
	jnz sub_end_\@

	pextrb $1, \str, \reg
	sub $0x30, \reg
	mov $0, \idx

	.irp j, Var_set
		Jmp_xmm_sub %xmm1\j, \str, \reg, \idx, sub_end_\@
	.endr

	# do nothing if no match

sub_end_\@:
.endm

# writes str (xmm) or subst (xmm) to the red zone and writes arg addresses into *argv table
# increments str_idx (gpr) and addr_idx (gpr) accordingly, clobbers mask (gpr), rcx
# (works for multiple C strings in str, but not used this way)
.macro Write_xmm_args str, str_idx, addr_idx, mask
	vmovdqu \str, (\str_idx)

	# put null mask in mask gpr
	vpcmpeqb simd_zero, \str, %xmm7
	vpmovmskb %xmm7, \mask

	# sign extend mask so comparisons against 0b11 that fall off the end of the mask word still work
	movsx \mask\()w, \mask

L0_\@:
	# test for 0b11 (two null bytes)
	mov \mask, %rcx
	and $0b11, %rcx
	cmp $0b11, %rcx
	jz L1_\@

	# find offset of null byte in mask, add to str_idx
	bsf \mask, %rcx
	add %rcx, \str_idx

	inc \str_idx # point to char after null ptr
	inc %cl

	shr %cl, \mask # adjust mask

	mov \str_idx, (\addr_idx) # fill argv address
	add $8, \addr_idx

	jmp L0_\@ # see if more mask bits exist

L1_\@:
.endm

# wrapper for Write_xmm_args, dumps all xmm registers memory in a packed fashion
# cmd_idx, argv_idx, mask trashed
.macro Write_all_argv cmd_idx, argv_idx, mask
	lea Argv(%rbp), \cmd_idx # command string index
	lea (Argv_ptr + 8)(%rbp), \argv_idx # *argv index

	# pack args together in red zone and write *argv pointers
	.irp i, Arg_set
		Write_xmm_args %xmm\i, \cmd_idx, \argv_idx, \mask
	.endr

	movq $0, -8(\argv_idx) # overwrite last address with a null pointer
.endm

# prints memory pointed to by absolute address
.macro Print label, len
	# write()
	mov $1, %rax
	mov $1, %rdi
	lea \label, %rsi
	mov \len, %rdx
	syscall
.endm

# prints memory pointed to by reg
.macro Print_reg reg, len
	# write()
	mov $1, %rax
	mov $1, %rdi
	mov \reg, %rsi
	mov \len, %rdx
	syscall
.endm

# jumps to dst if str != cmp
.macro Jmp_str str, cmp, dst
	pcmpistri $0x18, \cmp, \str
	jnb \dst # jmp if CF = 0, CF = 0 if bytes in string differ
.endm

# prints status of carry flag and exits if flag is clear
.macro Check_feature_flag fatal
	jc L1_\@
L0_\@:
	Print check_no, $(check_no_end - check_no)
.if \fatal
	mov $60, %rax
	mov $1, %rdi
	syscall
.else
	jmp L2_\@
.endif
L1_\@:
	Print check_yes, $(check_yes_end - check_yes)
L2_\@:
.endm

# NOTE: currently unused
# finds the index of the first char in mm (xmm/ymm) and writes idx with the result
.macro Find_idx mem, mm, idx
	lea \mem, \idx
	vpcmpeqb (\idx), \mm, %xmm7
	vpmovmskb %xmm7, \idx
	bsf \idx, \idx
.endm

_start:
	lea -128(%rsp), %rbp # legal red zone is rsp - 1 to rsp - 128

	# find **env and put in r8
	mov (%rsp), %r8 # get argc
	lea 16(%rsp, %r8, 8), %r8 # put 16 + (rsp + r8 * 8) (**env) in r8

arg_check:
	# skip if no args present
	cmpq $1, (%rsp)
	jz cpu_check

	# get offset of arg, load into xmm register, and check it against valid strings
	mov 16(%rsp), %r15
	movdqu (%r15), %xmm0

	Jmp_str %xmm0, arg_quiet, set_quiet

	Print bad_shopt_msg, $(bad_shopt_msg_end - bad_shopt_msg)
	jmp exit

set_quiet:
	# set quiet mode (disables startup cpu checks)
	movq $1, (%rbp)
	fildq (%rbp)
	jmp reset

cpu_check:
	# check for SSE 4.2
	Print check_sse, $(check_sse_end - check_sse)
	mov $1, %rax
	cpuid
	bt $20, %rcx
	Check_feature_flag 1

	# check for AVX
	Print check_avx, $(check_avx_end - check_avx)
	mov $1, %rax
	cpuid
	bt $28, %rcx
	Check_feature_flag 1

	# check for AVX2
	Print check_avx2, $(check_avx2_end - check_avx2)
	mov $7, %rax
	xor %rcx, %rcx
	cpuid
	bt $5, %rbx
	Check_feature_flag 1

	# see if we have AVX512 (not required)
	Print check_avx512, $(check_avx512_end - check_avx512)
	bt $16, %rbx
	Check_feature_flag 0

	Print newline, $1

reset:
	.irp i, Arg_set, 6
		vpxor %xmm\i, %xmm\i, %xmm\i
	.endr

	movb $0, (%rbp) # clear newline from previous cmd

	Print prompt, $(prompt_end - prompt)

rd_cmd:
	# use vextracti128/vinserti128 to get upper 128 bits of ymm registers

	# read command and args
	.irp i, Arg_set
		Read %xmm\i, %xmm7, %r10

		# replace spaces with null bytes
		lea simd_space, %r11
		vpcmpeqb (%r11), %xmm\i, %xmm7

		# arg1: mask register
		# arg2: written if mask >= 0x80
		# arg3: written if mask < 0x80
		# arg4: dest
		vpblendvb %xmm7, %xmm6, %xmm\i, %xmm\i

		Sub_xmm_arg %xmm\i, %r12, %r11
	.endr

try_builtin:
	# handle builtins

	Jmp_str %xmm0, cmd_empty, empty

	Jmp_str %xmm0, cmd_help, help

	Jmp_str %xmm0, cmd_version, version
	Jmp_str %xmm0, cmd_exit, exit
	Jmp_str %xmm0, cmd_cd, cd

	Jmp_str %xmm0, cmd_set, set
	Jmp_str %xmm0, cmd_get, get

write_argv:
	mov %rbp, Argv_ptr(%rbp) # set argv[0]

	Write_all_argv %r15, %r14, %r13

write_end_argv:
	movq $0, (Argv_end)(%rbp)

is_parent:
	# fork()
	mov $57, %rax
	syscall

	# ...if child, call exec()
	cmp $0, %rax
	jz do_exec

wait_exec:
	# int waitid(int which, pid_t upid, <*struct>, int options, <*struct>)
	mov $247, %rax
	mov $0, %rdi # P_ALL (wait for any child to return, ignore upid)
	mov $0, %rsi # ignored because of P_ALL
	mov $0, %rdx # NULL struct ptr
	mov $4, %r10 # WEXITED (check which children exited)
	mov %r8, %r15 # save r8
	mov $0, %r8 # NULL struct ptr
	syscall

	mov %r15, %r8 # restore r8
	jmp reset

do_exec:
	# try cmd itself with execve()
	mov $59, %rax
	lea Argv(%rbp), %rdi # create *filename
	lea Argv_ptr(%rbp), %rsi # create **argv
	mov %r8, %rdx # copy **env
	syscall

	# try /usr/bin/<exec>
	mov $59, %rax
	mov path_usr_bin, %r13
	vpslldq $(path_usr_bin_end - path_usr_bin), %xmm0, %xmm0
	pinsrq $0, %r13, %xmm0
	pinsrb $8, %r13, %xmm0

	Write_all_argv %r15, %r14, %r13
	syscall

	# bail out if both tries failed
	Print err_msg, $(err_msg_end - err_msg)

	# exit()
	mov $60, %rax
	mov $1, %rdi
	syscall

empty:
	jmp reset

help:
	Print help_msg, $(help_msg_end - help_msg)
	jmp reset

version:
	Print ver_msg, $(ver_msg_end - ver_msg)
	jmp reset

exit:
	mov $60, %rax
	xor %rdi, %rdi
	syscall

cd:
	# chdir()
	mov $80, %rax
	vmovdqu %xmm1, Argv_arg(%rbp)
	lea Argv_arg(%rbp), %rdi # new directory
	syscall

	jmp reset

set:
	.irp i, Var_set
		Jmp_str %xmm1, num_\i, set_1\i
	.endr

	Print get_set_err_msg, $(get_set_err_msg_end - get_set_err_msg)
	jmp reset

.irp i, Var_set
set_1\i:
	movdqa %xmm2, %xmm1\i
	jmp reset
.endr

get:
	.irp i, Var_set
		Jmp_str %xmm1, num_\i, get_1\i
	.endr

	Print get_set_err_msg, $(get_set_err_msg_end - get_set_err_msg)
	jmp reset

.irp i, Var_set
get_1\i:
	movdqu %xmm1\i, (%rbp)
	Print get_prefix, $(get_prefix_end - get_prefix)
	Print_reg %rbp, $16
	Print get_suffix, $(get_suffix_end - get_suffix)
	jmp reset
.endr

cmd_empty:
	.byte 0
cmd_empty_end:

cmd_help:
	.asciz "help"

help_msg:
	.ascii "SIMD shell\n\n"
	.ascii "A shell that doesn't rely on stack or heap allocation."
	.ascii " Keep commands short.\n\n"

	.ascii "commands:\n"
	.ascii "version: print version\n"
	.ascii "exit: exit the shell\n"
	.ascii "help: show this help menu\n"
	.ascii "get <n>: prints contents of variable slot <n>\n"
	.ascii "set <n>: sets contents of variable slot <n>\n"

	.ascii "\nshell flags:\n"
	.ascii "-quiet: skip instruction checks at startup\n"

	.asciz "\n"
help_msg_end:

cmd_version:
	.asciz "version"

ver_msg:
	.ascii "smdsh v"
	.ascii Version
	.ascii "\n"
ver_msg_end:

cmd_exit:
	.asciz "exit"

cmd_cd:
	.asciz "cd"

cmd_set:
	.asciz "set"

cmd_get:
	.asciz "get"

get_prefix:
	.asciz "storing \""
get_prefix_end:

get_suffix:
	.asciz "\"\n"
get_suffix_end:

err_msg:
	.ascii Yellow
	.ascii "cannot locate executable!\n"
	.asciz BW
err_msg_end:

get_set_err_msg:
	.ascii Yellow
	.ascii "invalid index!\n"
	.asciz BW
get_set_err_msg_end:

bad_shopt_msg:
	.ascii Yellow
	.ascii "invalid option!\n"
	.asciz BW
bad_shopt_msg_end:

prompt:
	.asciz "smdsh $ "
prompt_end:

path_usr_bin:
	.ascii "/usr/bin/"
path_usr_bin_end:

check_sse:
	.asciz "sse 4.2\t"
check_sse_end:

check_avx:
	.asciz "avx\t"
check_avx_end:

check_avx2:
	.asciz "avx2\t"
check_avx2_end:

check_avx512:
	.asciz "avx-512\t"
check_avx512_end:

check_yes:
	.ascii "["
	.ascii Green
	.ascii "supported"
	.ascii BW
	.asciz "]\n"
check_yes_end:

check_no:
	.ascii "["
	.ascii Yellow
	.ascii "unsupported"
	.ascii BW
	.asciz "]\n"
check_no_end:

.irp i, Var_set
	num_\i:
		.asciz "\i"
.endr

newline:
	.byte '\n'

subst:
	.byte '$'

# 32 bytes of zeros
simd_zero:
	.fill 32, 1, 0

# 32 bytes of ones
simd_one:
	.fill 32, 1, 0xFF

# 32 spaces
simd_space:
	.fill 32, 1, ' '

arg_quiet:
	.asciz "-quiet"

