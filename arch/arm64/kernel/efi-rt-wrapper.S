/*
 * Copyright (C) 2018 Linaro Ltd <ard.biesheuvel@linaro.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/linkage.h>

SYM_FUNC_START(__efi_rt_asm_wrapper)
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp

	/*
	 * Register x18 is designated as the 'platform' register by the AAPCS,
	 * which means firmware running at the same exception level as the OS
	 * (such as UEFI) should never touch it.
	 */
	stp	x1, x18, [sp, #16]

	/*
	 * We are lucky enough that no EFI runtime services take more than
	 * 5 arguments, so all are passed in registers rather than via the
	 * stack.
	 */
	mov	x8, x0
	mov	x0, x2
	mov	x1, x3
	mov	x2, x4
	mov	x3, x5
	mov	x4, x6
	blr	x8

	ldp	x1, x2, [sp, #16]
	cmp	x2, x18
	ldp	x29, x30, [sp], #32
	b.ne	0f
	ret
0:
#ifdef CONFIG_SHADOW_CALL_STACK
	/*
	 * Restore x18 before returning to instrumented code. This is
	 * safe because the wrapper is called with preemption disabled and
	 * a separate shadow stack is used for interrupts.
	 */
	mov	x18, x2
#endif
	b	efi_handle_corrupted_x18	// tail call
SYM_FUNC_END(__efi_rt_asm_wrapper)
