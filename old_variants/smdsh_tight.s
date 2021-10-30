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

# memory I can use (assuming AVX2 support):
# x86 registers, r8 - r15
# xmm0 - xmm7, xmm8 - xmm15, ymm0 - ymm15
# x87 float registers (or MMX registers)
# x87 float control registers
# 128-byte red zone after rsp

# TODO:
# implement strstr, '+', '=', and '-'
# reload: assembles and launches itself, ship source as .ascii
# fix encodings (all VEX?)
# clean up assembly (mov $0 -> xor, etc)

# red zone memory map

# space to store command and args
.equ Argv_0, 0
.equ Argv_1, 16
.equ Argv_2, 32
.equ Argv_3, 48
.equ Argv_ptr, 64 # table of 4 *argv elements + NULL
.equ Argv_ptr_end, 96
.equ Argv_env_0, 104 # table of 2 *env elements + NULL
.equ Argv_env_1, 112
.equ Argv_env_end, 120

.global _start

.text

# fills xmm with val, fill (gpr) clobbered
.macro Reset_xmm_mask xmm, fill, val
	mov \val, \fill
	pinsrb $0, \fill, \xmm
	vpbroadcastb \xmm, \xmm
.endm

# read text into str (xmm), clobbering mask (xmm) and returning number of chars in count (gpr)
.macro Read str, mask, count
	cmpb $'\n', (%r9) # check if we need to do anything at all
	jz L3_\@

	movdqu simd_one, \mask
	mov $0, \count

L0_\@:
	# test for \n (done with command)
	cmpb $'\n', (%r9)
	jz L1_\@

	# read()
	mov $0, %rax
	mov $0, %rdi
	mov %r9, %rsi
	mov $1, %rdx
	syscall

	# insert the current string index in mask
	vpslldq $1, \mask, \mask
	pinsrb $0, \count, \mask

	# insert the character read in str
	vpslldq $1, \str, \str
	pinsrb $0, (%r9), \str

	# increment index
	inc \count

	# test if out of space in str
	cmp $16, \count
	jz L2_\@

	jmp L0_\@

L1_\@:
	# un-get break token
	vpsrldq $1, \str, \str
	vpsrldq $1, \mask, \mask
	pinsrb $15, simd_one, \mask # mask off upper byte to account for logical shift instead of arith

L2_\@:
	vpshufb \mask, \str, \str # reverse str using mask and zero unused chars

L3_\@:
.endm

# writes str (xmm) to the red zone and writes arg addresses into *argv table
# increments str_idx (gpr) and addr_idx (gpr) accordingly, clobbers mask (gpr), rcx
.macro Write_xmm_args str, str_idx, addr_idx, mask
	# put null mask in mask gpr
	vpcmpeqb simd_zero, \str, %xmm7
	vpmovmskb %xmm7, \mask

L0_\@:
	# test for 0b11 (two null bytes)
	mov \mask, %rcx
	and $0b11, %rcx
	cmp $0b11, %rcx
	jz L1_\@

	# find offset of null byte in mask, add to r15
	bsf \mask, %rcx
	add %rcx, \str_idx

	inc \str_idx # point to char after null ptr
	inc %cl

	shr %cl, \mask # adjust mask

	mov \str_idx, (\addr_idx) # fill argv address
	add $8, \addr_idx

	# TODO: buffer overflow possible here with too many args

	jmp L0_\@ # see if more mask bits exist

L1_\@:
.endm

.macro Print label, len
	# write()
	mov $1, %rax
	mov $1, %rdi
	lea \label, %rsi
	mov \len, %rdx
	syscall
.endm

# finds the index of the first char in mm (xmm/ymm) and writes idx with the result
.macro Find_idx mem, mm, idx
	lea \mem, \idx
	vpcmpeqb (\idx), \mm, %xmm7
	vpmovmskb %xmm7, \idx
	bsf \idx, \idx
.endm

# jumps to dst if str != cmp
.macro Jmp_str str, cmp, dst
	pcmpistri $0x18, \cmp, \str
	jnb \dst # jmp if CF = 0, CF = 0 if bytes in string differ
.endm

_start:
	lea -128(%rsp), %r9 # legal red zone is rsp - 1 to rsp - 128

	# find **env and put in r8
	mov (%rsp), %r8 # get argc
	lea 16(%rsp, %r8, 8), %r8 # put 16 + (rsp + r8 * 8) (**env) in r8
	mov (%r8), %r8 # put *env in r8

reset:
	.irp i, 0, 1, 2, 3
		vpxor %xmm\i, %xmm\i, %xmm\i
	.endr

rd_cmd:
	Print prompt, $(prompt_end - prompt)

	movb $0, (%r9) # clear newline from previous cmd

	# use palignr to move xmm registers into ymm

	vpxor %xmm6, %xmm6, %xmm6

	# read up to 64 bytes of cmd
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
	.irp i, 0, 1, 2, 3
		vmovdqu %xmm\i, Argv_\i(%r9)
	.endr

	mov %r9, Argv_ptr(%r9) # set argv[0]

	lea Argv_0(%r9), %r15 # r15 = command string index
	lea (Argv_ptr + 8)(%r9), %r10 # r10 = *argv index

	Write_xmm_args %xmm0, %r15, %r10, %r14
	Write_xmm_args %xmm1, %r15, %r10, %r14

	movq $0, -8(%r10) # overwrite last address with a null pointer

write_end_argv:
	movq $0, (Argv_env_end)(%r9)

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
	lea Argv_0(%r9), %rdi # create *filename
	lea Argv_ptr(%r9), %rsi # create **argv
	lea Argv_env_0(%r9), %rdx # create **env
	syscall

	# try /bin/<exec>
	#mov $59, %rax
	#mov path_bin, %r15w
	#syscall

	# try /usr/bin/<exec>
	#mov $59, %rax
	#mov path_usr_bin, %r15w
	#syscall

	# error out if all three tries failed
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
	movdqu %xmm1, Argv_1(%r9)
	lea Argv_1(%r9), %rdi # new directory
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

	.ascii "+ <search>: pass the environment string starting with term <search> to commands executed\n"
	.ascii "=: list stored environment variables\n"

	.asciz "\n"
help_msg_end:

cmd_version:
	.asciz "version"

ver_msg:
	.ascii "smdsh v0.1\n"
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

path_bin:
	.asciz "/bin/"

path_usr_bin:
	.asciz "/usr/bin/"

# 32 bytes of zeros
simd_zero:
	.fill 32, 1, 0

# 32 bytes of ones
simd_one:
	.fill 32, 1, 0xFF

# 32 newlines
simd_space:
	.fill 32, 1, ' '

