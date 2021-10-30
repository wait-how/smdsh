# smdsh

A shell that doesn't rely on stack or heap allocation.  Keep commands short; there isn't a lot of error checking here.

## Features
 - uses only 128 bytes of RAM (the Linux x86-64 red zone)
 - all environment variables defined at launch are passed to children
 - basic builtin support
 - extensive use of SIMD instructions to speed up data processing

`old_variants` contains older versions of smdsh that didn't work for various reasons.
 - `smdsh_xmm_str.s` used SSE string processing instructions for everything, which was a huge hassle and hard to read and adjust.  Better method is to use regular cmp and mask instructions.
 - `smdsh_tight.s` packed all commands and args as tight as possible in XMM registers which made it really hard to do string processing or shifting without losing data.

