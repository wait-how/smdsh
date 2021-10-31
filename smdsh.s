# shell entirely within AVX registers
#
# rules:
# 1. no heap memory allocation (malloc, brk, mmap, new processes, etc)
# 2. no stack allocation (meaning the adjustment of rbp or rsp)
#      a. red zones are fair game but vary by OS and architecture
# 3. no calling libraries that violate rules 1 or 2 (including libc)
# 4. using memory that is already allocated at the start of the program is ok, but don't abuse it
# 5. storing read only data in .text is ok
#
# to run:
# $ clang -nostdlib smdsh.s -o smdsh && ./smdsh

# usable memory (assuming AVX2 support):
# x86 registers, r8 - r15
# xmm0 - xmm7, xmm8 - xmm15, ymm0 - ymm15
# x87 float registers (or MMX registers)
# x87 float control registers
# 128-byte red zone after rsp

# red zone memory map

.equ Argv, 0
.equ Argv_arg, 16
.equ Argv_ptr, 64 # table of 7 *argv elements + NULL
.equ Argv_end, 120

.global _start

.text

# read text into str (xmm), clobbering mask (xmm) and returning number of chars in count (gpr)
.macro Read str, mask, count
	cmpb $'\n', (%r9) # check if we need to do anything at all
	jz L2_\@

	vmovdqu simd_one, \mask
	mov $0, \count

L0_\@:
	# read()
	xor %rax, %rax
	xor %rdi, %rdi
	mov %r9, %rsi
	mov $1, %rdx
	syscall

	# test if out of space in str
	cmp $16, \count
	jz L1_\@

	# test for arg delimiters or break character
	cmpb $'\t', (%r9)
	jz L1_\@

	cmpb $' ', (%r9)
	jz L1_\@

	cmpb $'\n', (%r9)
	jz L1_\@

	# insert the current string index in mask
	vpslldq $1, \mask, \mask
	vpinsrb $0, \count, \mask, \mask

	# insert the character read in str
	vpslldq $1, \str, \str
	vpinsrb $0, (%r9), \str, \str

	# increment index
	inc \count

	jmp L0_\@

L1_\@:
	vpshufb \mask, \str, \str # reverse str using mask and zero unused chars

L2_\@:
.endm

# writes str (xmm) to the red zone and writes arg addresses into *argv table
# increments str_idx (gpr) and addr_idx (gpr) accordingly, clobbers mask (gpr), rcx
# (works for multiple C strings in str, but not used this way)
.macro Write_xmm_args str, str_idx, addr_idx, mask
	vmovdqu \str, (\str_idx)

	# put null mask in mask gpr
	vpcmpeqb simd_zero, \str, %xmm7
	vpmovmskb %xmm7, \mask

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
.macro Write_all_argv cmd_idx, argv_idx, mask
	lea Argv(%r9), \cmd_idx # command string index
	lea (Argv_ptr + 8)(%r9), \argv_idx # *argv index

	# pack args together in red zone and write *argv pointers
	.irp i, 0, 1, 2, 3
		Write_xmm_args %xmm\i, \cmd_idx, \argv_idx, \mask
	.endr

	movq $0, -8(\argv_idx) # overwrite last address with a null pointer
.endm

.macro Print label, len
	# write()
	mov $1, %rax
	mov $1, %rdi
	lea \label, %rsi
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
	lea -128(%rsp), %r9 # legal red zone is rsp - 1 to rsp - 128

	# find **env and put in r8
	mov (%rsp), %r8 # get argc
	lea 16(%rsp, %r8, 8), %r8 # put 16 + (rsp + r8 * 8) (**env) in r8

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
	.irp i, 0, 1, 2, 3
		vpxor %xmm\i, %xmm\i, %xmm\i
	.endr

rd_cmd:
	Print prompt, $(prompt_end - prompt)

	movb $0, (%r9) # clear newline from previous cmd

	# use palignr to move xmm registers into ymm

	vpxor %xmm6, %xmm6, %xmm6

	# read 4 commands
	.irp i, 0, 1, 2, 3
		Read %xmm\i, %xmm7, %r10

		# replace spaces with null bytes
		lea simd_space, %r11
		vpcmpeqb (%r11), %xmm\i, %xmm7

		# arg1: mask register
		# arg2: written if mask >= 0x80
		# arg3: written if mask < 0x80
		# arg4: dest
		vpblendvb %xmm7, %xmm6, %xmm\i, %xmm\i
	.endr

try_builtin:
	# handle builtins
	Jmp_str %xmm0, cmd_help, help
	Jmp_str %xmm0, cmd_version, version
	Jmp_str %xmm0, cmd_exit, exit
	Jmp_str %xmm0, cmd_cd, cd

write_argv:
	mov %r9, Argv_ptr(%r9) # set argv[0]

	Write_all_argv %r15, %r14, %r13

write_end_argv:
	movq $0, (Argv_end)(%r9)

is_parent:
	# fork()
	mov $57, %rax
	syscall

	# if child, call exec()
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
	lea Argv(%r9), %rdi # create *filename
	lea Argv_ptr(%r9), %rsi # create **argv
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

	# error out if both tries failed
	Print err_msg, $(err_msg_end - err_msg)

	# exit()
	mov $60, %rax
	mov $1, %rdi
	syscall

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
	vmovdqu %xmm1, Argv_arg(%r9)
	lea Argv_arg(%r9), %rdi # new directory
	syscall

	jmp reset

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

	.asciz "\n"
help_msg_end:

cmd_version:
	.asciz "version"

ver_msg:
	.ascii "smdsh v0.3\n"
ver_msg_end:

cmd_exit:
	.asciz "exit"

cmd_cd:
	.asciz "cd"

err_msg:
	.asciz "cannot locate executable!\n"
err_msg_end:

prompt:
	.asciz "smdsh $ "
prompt_end:

space_msg:
	.asciz " "

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
	.asciz "[supported]\n"
check_yes_end:

check_no:
	.asciz "[unsupported]\n"
check_no_end:

newline:
	.byte '\n'

# 32 bytes of zeros
simd_zero:
	.fill 32, 1, 0

# 32 bytes of ones
simd_one:
	.fill 32, 1, 0xFF

# 32 spaces
simd_space:
	.fill 32, 1, ' '

