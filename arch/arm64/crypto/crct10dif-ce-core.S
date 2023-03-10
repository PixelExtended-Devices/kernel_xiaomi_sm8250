//
// Accelerated CRC-T10DIF using arm64 NEON and Crypto Extensions instructions
//
// Copyright (C) 2016 Linaro Ltd <ard.biesheuvel@linaro.org>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License version 2 as
// published by the Free Software Foundation.
//

//
// Implement fast CRC-T10DIF computation with SSE and PCLMULQDQ instructions
//
// Copyright (c) 2013, Intel Corporation
//
// Authors:
//     Erdinc Ozturk <erdinc.ozturk@intel.com>
//     Vinodh Gopal <vinodh.gopal@intel.com>
//     James Guilford <james.guilford@intel.com>
//     Tim Chen <tim.c.chen@linux.intel.com>
//
// This software is available to you under a choice of one of two
// licenses.  You may choose to be licensed under the terms of the GNU
// General Public License (GPL) Version 2, available from the file
// COPYING in the main directory of this source tree, or the
// OpenIB.org BSD license below:
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
// * Redistributions of source code must retain the above copyright
//   notice, this list of conditions and the following disclaimer.
//
// * Redistributions in binary form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the
//   distribution.
//
// * Neither the name of the Intel Corporation nor the names of its
//   contributors may be used to endorse or promote products derived from
//   this software without specific prior written permission.
//
//
// THIS SOFTWARE IS PROVIDED BY INTEL CORPORATION ""AS IS"" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL INTEL CORPORATION OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//       Function API:
//       UINT16 crc_t10dif_pcl(
//               UINT16 init_crc, //initial CRC value, 16 bits
//               const unsigned char *buf, //buffer pointer to calculate CRC on
//               UINT64 len //buffer length in bytes (64-bit data)
//       );
//
//       Reference paper titled "Fast CRC Computation for Generic
//	Polynomials Using PCLMULQDQ Instruction"
//       URL: http://www.intel.com/content/dam/www/public/us/en/documents
//  /white-papers/fast-crc-computation-generic-polynomials-pclmulqdq-paper.pdf
//
//

#include <linux/linkage.h>
#include <asm/assembler.h>

	.text
	.cpu		generic+crypto

	arg1_low32	.req	w19
	arg2		.req	x20
	arg3		.req	x21

	vzr		.req	v13

SYM_FUNC_START(crc_t10dif_pmull)
	frame_push	3, 128

	mov		arg1_low32, w0
	mov		arg2, x1
	mov		arg3, x2

	movi		vzr.16b, #0		// init zero register

	// adjust the 16-bit initial_crc value, scale it to 32 bits
	lsl		arg1_low32, arg1_low32, #16

	// check if smaller than 256
	cmp		arg3, #256

	// for sizes less than 128, we can't fold 64B at a time...
	b.lt		_less_than_128

	// load the initial crc value
	// crc value does not need to be byte-reflected, but it needs
	// to be moved to the high part of the register.
	// because data will be byte-reflected and will align with
	// initial crc at correct place.
	movi		v10.16b, #0
	mov		v10.s[3], arg1_low32		// initial crc

	// receive the initial 64B data, xor the initial crc value
	ldp		q0, q1, [arg2]
	ldp		q2, q3, [arg2, #0x20]
	ldp		q4, q5, [arg2, #0x40]
	ldp		q6, q7, [arg2, #0x60]
	add		arg2, arg2, #0x80

CPU_LE(	rev64		v0.16b, v0.16b			)
CPU_LE(	rev64		v1.16b, v1.16b			)
CPU_LE(	rev64		v2.16b, v2.16b			)
CPU_LE(	rev64		v3.16b, v3.16b			)
CPU_LE(	rev64		v4.16b, v4.16b			)
CPU_LE(	rev64		v5.16b, v5.16b			)
CPU_LE(	rev64		v6.16b, v6.16b			)
CPU_LE(	rev64		v7.16b, v7.16b			)

CPU_LE(	ext		v0.16b, v0.16b, v0.16b, #8	)
CPU_LE(	ext		v1.16b, v1.16b, v1.16b, #8	)
CPU_LE(	ext		v2.16b, v2.16b, v2.16b, #8	)
CPU_LE(	ext		v3.16b, v3.16b, v3.16b, #8	)
CPU_LE(	ext		v4.16b, v4.16b, v4.16b, #8	)
CPU_LE(	ext		v5.16b, v5.16b, v5.16b, #8	)
CPU_LE(	ext		v6.16b, v6.16b, v6.16b, #8	)
CPU_LE(	ext		v7.16b, v7.16b, v7.16b, #8	)

	// XOR the initial_crc value
	eor		v0.16b, v0.16b, v10.16b

	ldr_l		q10, rk3, x8	// xmm10 has rk3 and rk4
					// type of pmull instruction
					// will determine which constant to use

	//
	// we subtract 256 instead of 128 to save one instruction from the loop
	//
	sub		arg3, arg3, #256

	// at this section of the code, there is 64*x+y (0<=y<64) bytes of
	// buffer. The _fold_64_B_loop will fold 64B at a time
	// until we have 64+y Bytes of buffer


	// fold 64B at a time. This section of the code folds 4 vector
	// registers in parallel
_fold_64_B_loop:

	.macro		fold64, reg1, reg2
	ldp		q11, q12, [arg2], #0x20

	pmull2		v8.1q, \reg1\().2d, v10.2d
	pmull		\reg1\().1q, \reg1\().1d, v10.1d

CPU_LE(	rev64		v11.16b, v11.16b		)
CPU_LE(	rev64		v12.16b, v12.16b		)

	pmull2		v9.1q, \reg2\().2d, v10.2d
	pmull		\reg2\().1q, \reg2\().1d, v10.1d

CPU_LE(	ext		v11.16b, v11.16b, v11.16b, #8	)
CPU_LE(	ext		v12.16b, v12.16b, v12.16b, #8	)

	eor		\reg1\().16b, \reg1\().16b, v8.16b
	eor		\reg2\().16b, \reg2\().16b, v9.16b
	eor		\reg1\().16b, \reg1\().16b, v11.16b
	eor		\reg2\().16b, \reg2\().16b, v12.16b
	.endm

	fold64		v0, v1
	fold64		v2, v3
	fold64		v4, v5
	fold64		v6, v7

	subs		arg3, arg3, #128

	// check if there is another 64B in the buffer to be able to fold
	b.lt		_fold_64_B_end

	if_will_cond_yield_neon
	stp		q0, q1, [sp, #.Lframe_local_offset]
	stp		q2, q3, [sp, #.Lframe_local_offset + 32]
	stp		q4, q5, [sp, #.Lframe_local_offset + 64]
	stp		q6, q7, [sp, #.Lframe_local_offset + 96]
	do_cond_yield_neon
	ldp		q0, q1, [sp, #.Lframe_local_offset]
	ldp		q2, q3, [sp, #.Lframe_local_offset + 32]
	ldp		q4, q5, [sp, #.Lframe_local_offset + 64]
	ldp		q6, q7, [sp, #.Lframe_local_offset + 96]
	ldr_l		q10, rk3, x8
	movi		vzr.16b, #0		// init zero register
	endif_yield_neon

	b		_fold_64_B_loop

_fold_64_B_end:
	// at this point, the buffer pointer is pointing at the last y Bytes
	// of the buffer the 64B of folded data is in 4 of the vector
	// registers: v0, v1, v2, v3

	// fold the 8 vector registers to 1 vector register with different
	// constants

	ldr_l		q10, rk9, x8

	.macro		fold16, reg, rk
	pmull		v8.1q, \reg\().1d, v10.1d
	pmull2		\reg\().1q, \reg\().2d, v10.2d
	.ifnb		\rk
	ldr_l		q10, \rk, x8
	.endif
	eor		v7.16b, v7.16b, v8.16b
	eor		v7.16b, v7.16b, \reg\().16b
	.endm

	fold16		v0, rk11
	fold16		v1, rk13
	fold16		v2, rk15
	fold16		v3, rk17
	fold16		v4, rk19
	fold16		v5, rk1
	fold16		v6

	// instead of 64, we add 48 to the loop counter to save 1 instruction
	// from the loop instead of a cmp instruction, we use the negative
	// flag with the jl instruction
	adds		arg3, arg3, #(128-16)
	b.lt		_final_reduction_for_128

	// now we have 16+y bytes left to reduce. 16 Bytes is in register v7
	// and the rest is in memory. We can fold 16 bytes at a time if y>=16
	// continue folding 16B at a time

_16B_reduction_loop:
	pmull		v8.1q, v7.1d, v10.1d
	pmull2		v7.1q, v7.2d, v10.2d
	eor		v7.16b, v7.16b, v8.16b

	ldr		q0, [arg2], #16
CPU_LE(	rev64		v0.16b, v0.16b			)
CPU_LE(	ext		v0.16b, v0.16b, v0.16b, #8	)
	eor		v7.16b, v7.16b, v0.16b
	subs		arg3, arg3, #16

	// instead of a cmp instruction, we utilize the flags with the
	// jge instruction equivalent of: cmp arg3, 16-16
	// check if there is any more 16B in the buffer to be able to fold
	b.ge		_16B_reduction_loop

	// now we have 16+z bytes left to reduce, where 0<= z < 16.
	// first, we reduce the data in the xmm7 register

_final_reduction_for_128:
	// check if any more data to fold. If not, compute the CRC of
	// the final 128 bits
	adds		arg3, arg3, #16
	b.eq		_128_done

	// here we are getting data that is less than 16 bytes.
	// since we know that there was data before the pointer, we can
	// offset the input pointer before the actual point, to receive
	// exactly 16 bytes. after that the registers need to be adjusted.
_get_last_two_regs:
	add		arg2, arg2, arg3
	ldr		q1, [arg2, #-16]
CPU_LE(	rev64		v1.16b, v1.16b			)
CPU_LE(	ext		v1.16b, v1.16b, v1.16b, #8	)

	// get rid of the extra data that was loaded before
	// load the shift constant
	adr_l		x4, tbl_shf_table + 16
	sub		x4, x4, arg3
	ld1		{v0.16b}, [x4]

	// shift v2 to the left by arg3 bytes
	tbl		v2.16b, {v7.16b}, v0.16b

	// shift v7 to the right by 16-arg3 bytes
	movi		v9.16b, #0x80
	eor		v0.16b, v0.16b, v9.16b
	tbl		v7.16b, {v7.16b}, v0.16b

	// blend
	sshr		v0.16b, v0.16b, #7	// convert to 8-bit mask
	bsl		v0.16b, v2.16b, v1.16b

	// fold 16 Bytes
	pmull		v8.1q, v7.1d, v10.1d
	pmull2		v7.1q, v7.2d, v10.2d
	eor		v7.16b, v7.16b, v8.16b
	eor		v7.16b, v7.16b, v0.16b

_128_done:
	// compute crc of a 128-bit value
	ldr_l		q10, rk5, x8		// rk5 and rk6 in xmm10

	// 64b fold
	ext		v0.16b, vzr.16b, v7.16b, #8
	mov		v7.d[0], v7.d[1]
	pmull		v7.1q, v7.1d, v10.1d
	eor		v7.16b, v7.16b, v0.16b

	// 32b fold
	ext		v0.16b, v7.16b, vzr.16b, #4
	mov		v7.s[3], vzr.s[0]
	pmull2		v0.1q, v0.2d, v10.2d
	eor		v7.16b, v7.16b, v0.16b

	// barrett reduction
_barrett:
	ldr_l		q10, rk7, x8
	mov		v0.d[0], v7.d[1]

	pmull		v0.1q, v0.1d, v10.1d
	ext		v0.16b, vzr.16b, v0.16b, #12
	pmull2		v0.1q, v0.2d, v10.2d
	ext		v0.16b, vzr.16b, v0.16b, #12
	eor		v7.16b, v7.16b, v0.16b
	mov		w0, v7.s[1]

_cleanup:
	// scale the result back to 16 bits
	lsr		x0, x0, #16
	frame_pop
	ret

_less_than_128:
	cbz		arg3, _cleanup

	movi		v0.16b, #0
	mov		v0.s[3], arg1_low32	// get the initial crc value

	ldr		q7, [arg2], #0x10
CPU_LE(	rev64		v7.16b, v7.16b			)
CPU_LE(	ext		v7.16b, v7.16b, v7.16b, #8	)
	eor		v7.16b, v7.16b, v0.16b	// xor the initial crc value

	cmp		arg3, #16
	b.eq		_128_done		// exactly 16 left
	b.lt		_less_than_16_left

	ldr_l		q10, rk1, x8		// rk1 and rk2 in xmm10

	// update the counter. subtract 32 instead of 16 to save one
	// instruction from the loop
	subs		arg3, arg3, #32
	b.ge		_16B_reduction_loop

	add		arg3, arg3, #16
	b		_get_last_two_regs

_less_than_16_left:
	// shl r9, 4
	adr_l		x0, tbl_shf_table + 16
	sub		x0, x0, arg3
	ld1		{v0.16b}, [x0]
	movi		v9.16b, #0x80
	eor		v0.16b, v0.16b, v9.16b
	tbl		v7.16b, {v7.16b}, v0.16b
	b		_128_done
SYM_FUNC_END(crc_t10dif_pmull)

// precomputed constants
// these constants are precomputed from the poly:
// 0x8bb70000 (0x8bb7 scaled to 32 bits)
	.section	".rodata", "a"
	.align		4
// Q = 0x18BB70000
// rk1 = 2^(32*3) mod Q << 32
// rk2 = 2^(32*5) mod Q << 32
// rk3 = 2^(32*15) mod Q << 32
// rk4 = 2^(32*17) mod Q << 32
// rk5 = 2^(32*3) mod Q << 32
// rk6 = 2^(32*2) mod Q << 32
// rk7 = floor(2^64/Q)
// rk8 = Q

rk1:	.octa		0x06df0000000000002d56000000000000
rk3:	.octa		0x7cf50000000000009d9d000000000000
rk5:	.octa		0x13680000000000002d56000000000000
rk7:	.octa		0x000000018bb7000000000001f65a57f8
rk9:	.octa		0xbfd6000000000000ceae000000000000
rk11:	.octa		0x713c0000000000001e16000000000000
rk13:	.octa		0x80a6000000000000f7f9000000000000
rk15:	.octa		0xe658000000000000044c000000000000
rk17:	.octa		0xa497000000000000ad18000000000000
rk19:	.octa		0xe7b50000000000006ee3000000000000

tbl_shf_table:
// use these values for shift constants for the tbl/tbx instruction
// different alignments result in values as shown:
//	DDQ 0x008f8e8d8c8b8a898887868584838281 # shl 15 (16-1) / shr1
//	DDQ 0x01008f8e8d8c8b8a8988878685848382 # shl 14 (16-3) / shr2
//	DDQ 0x0201008f8e8d8c8b8a89888786858483 # shl 13 (16-4) / shr3
//	DDQ 0x030201008f8e8d8c8b8a898887868584 # shl 12 (16-4) / shr4
//	DDQ 0x04030201008f8e8d8c8b8a8988878685 # shl 11 (16-5) / shr5
//	DDQ 0x0504030201008f8e8d8c8b8a89888786 # shl 10 (16-6) / shr6
//	DDQ 0x060504030201008f8e8d8c8b8a898887 # shl 9  (16-7) / shr7
//	DDQ 0x07060504030201008f8e8d8c8b8a8988 # shl 8  (16-8) / shr8
//	DDQ 0x0807060504030201008f8e8d8c8b8a89 # shl 7  (16-9) / shr9
//	DDQ 0x090807060504030201008f8e8d8c8b8a # shl 6  (16-10) / shr10
//	DDQ 0x0a090807060504030201008f8e8d8c8b # shl 5  (16-11) / shr11
//	DDQ 0x0b0a090807060504030201008f8e8d8c # shl 4  (16-12) / shr12
//	DDQ 0x0c0b0a090807060504030201008f8e8d # shl 3  (16-13) / shr13
//	DDQ 0x0d0c0b0a090807060504030201008f8e # shl 2  (16-14) / shr14
//	DDQ 0x0e0d0c0b0a090807060504030201008f # shl 1  (16-15) / shr15

	.byte		 0x0, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87
	.byte		0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f
	.byte		 0x0,  0x1,  0x2,  0x3,  0x4,  0x5,  0x6,  0x7
	.byte		 0x8,  0x9,  0xa,  0xb,  0xc,  0xd,  0xe , 0x0
