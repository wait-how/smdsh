# smdsh

A shell that doesn't rely on stack or heap allocation.  Keep commands short; there isn't a lot of error checking here.

The assembly here is optimized for runtime size and makes fairly heavy use of GAS macros.  Not sure if that was a good idea or not.

## Rules
1. no heap memory allocation (malloc, brk, mmap, new processes, etc.)
2. no stack allocation (meaning the adjustment of rbp or rsp)
3. no calling libraries that violate rules 1 or 2
4. using memory that is already allocated at the start of the program is ok, but don't abuse it
5. storing read-only data in .text is ok
6. no self-modifying code (sssslllloooowwww!)

## Memory used
 - 128-byte red zone after rsp
 - regular x86 and x64 registers
 - xmm0 - xmm15
   - NOTE: AVX2 is required to run smdsh.
 - x87 FPU stack registers

### Potentially usable memory
 - x87 float control/status registers
 - ymm0 - ymm15
 - zmm0 - zmm15 on machines with AVX512

### Memory map
|      | 0x0 - 0x8 | 0x9 - 0xF |
|------|-----------|-----------|
| 0x00 | **argv    | **argv    |
| 0x10 | **argv    | **argv    |
| 0x20 | **argv    | **argv    |
| 0x30 | **argv    | **argv    |
| 0x40 | argv[0]   | argv[1]   |
| 0x50 | argv[2]   | argv[3]   |
| 0x60 | argv[4]   | argv[5]   |
| 0x70 | NULL      |           |

## Building
 - `make regular`: build without debug symbols
 - `make debug`: build with debug symbols

## Features
 - uses only 128 bytes of RAM
 - all environment variables defined at launch are passed to children
 - basic builtin support
 - basic variable substitution support
 - basic command line option checking
 - extensive use of SIMD instructions to speed up (?) data processing

`old_variants` contains older versions of smdsh that didn't work for various reasons.
 - `smdsh_xmm_str.s` used SSE string processing instructions for everything, which was a huge hassle and hard to read and adjust.  Better method is to use regular cmp and mask instructions.
 - `smdsh_tight.s` packed all commands and args as tight as possible in XMM registers which made it really hard to do string processing or shifting without losing data.

