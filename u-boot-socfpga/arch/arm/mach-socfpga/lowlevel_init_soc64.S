/*
 * Copyright (C) 2020-2023 Intel Corporation. All rights reserved
 *
 * SPDX-License-Identifier:    GPL-2.0
 */

#include <asm-offsets.h>
#include <config.h>
#include <linux/linkage.h>
#include <asm/macro.h>

#if !defined(CONFIG_SPL_BUILD) && defined(CONFIG_ARMV8_PSCI)
.align 3
_el3_exception_vectors:
	.quad el3_exception_vectors;
#endif

ENTRY(lowlevel_init)
	mov	x29, lr			/* Save LR */

#ifdef CONFIG_SPL_BUILD
	/* Check for L2 reset magic word */
	ldr	x4, =L2_RESET_DONE_REG
	ldr	x5, [x4]
	ldr	x1, =L2_RESET_DONE_STATUS
	cmp	x1, x5
	/* No L2 reset, skip warm reset */
	b.ne	skipwarmreset
	/* Put all slaves CPUs into WFI mode */
	branch_if_slave x0, put_cpu_in_wfi
	/* L2 reset completed */
	str	xzr, [x4]
	/* Clear previous CPU release address */
	ldr	x4, =CPU_RELEASE_ADDR
	str	wzr, [x4]
	/* Master CPU (CPU0) request for warm reset */
	mrs	x1, rmr_el3
	orr	x1, x1, #0x02
	msr	rmr_el3, x1
	isb
	dsb	sy
put_cpu_in_wfi:
	wfi
	b	put_cpu_in_wfi
skipwarmreset:
#endif

#if defined(CONFIG_GICV2) || defined(CONFIG_GICV3)
#if defined(CONFIG_SPL_BUILD) && defined(CONFIG_SPL_ATF)

	/*
	 * In ATF flow, need to clear the old CPU address when cold reset
	 * being triggered, but shouldn't clear CPU address if it is reset
	 * by CPU-ON, so that the core can correctly jump to ATF code after
	 * reset by CPU-ON. CPU-ON trigger the reset via mpumodrst.
	 *
	 * Hardware will set 1 to core*_irq in mpurststat register in
	 * reset manager if the core is reset by mpumodrst.
	 *
	 * The following code will check the mpurststat to identify if the
	 * core is reset by mpumodrst, and it will skip CPU address clearing
	 * if the core is reset by mpumodrst. At last, the code need to clear
	 * the core*_irq by set it to 1. So that it can reflect the correct
	 * and latest status in next reset.
	 */

	/* Check if it is a master core off/on from kernel using boot scratch
	 * cold register 8 bit 19. This bit is set by ATF.
	 */
	ldr	x4, =BOOT_SCRATCH_COLD8
	ldr	x5, [x4]
	and	x6, x5, #0x80000
	cbnz	x6, wait_for_atf_master

	/* Retrieve mpurststat register in reset manager */
	ldr	x4, =SOCFPGA_RSTMGR_ADDRESS
	ldr	w5, [x4, #0x04]

	/* Set mask based on current core id */
	mrs	x0, mpidr_el1
	and	x1, x0, #0xF
	ldr	x2, =0x00000100
	lsl	x2, x2, x1

	/* Skip if core*_irq register is set */
	and	x6, x5, x2
	cbnz	x6, skip_clear_cpu_address

	/*
	 * Reach here means core*_irq is 0, means the core is
	 * reset by cold, warm or watchdog reset.
	 * Clear previous CPU release address
	 */
	ldr	x4, =CPU_RELEASE_ADDR
	str	wzr, [x4]
	b	skip_clear_core_irq

skip_clear_cpu_address:
	/* Clear core*_irq register by writing 1 */
	ldr	x4, =SOCFPGA_RSTMGR_ADDRESS
	str	w2, [x4, #0x04]

skip_clear_core_irq:
	/* Master CPU (CPU0) does not need to wait for atf */
	branch_if_master x0, master_cpu

wait_for_atf:
	ldr	x4, =CPU_RELEASE_ADDR
	ldr	x5, [x4]
	cbz	x5, slave_wait_atf
	br	x5
slave_wait_atf:
	branch_if_slave x0, wait_for_atf

wait_for_atf_master:
	ldr	x4, =CPU_RELEASE_ADDR
	ldr	x5, [x4]
	cbz	x5, master_wait_atf
	br	x5
master_wait_atf:
	branch_if_master x0, wait_for_atf_master

master_cpu:
#else
	branch_if_slave x0, 1f
#endif
	ldr	x0, =GICD_BASE
	bl	gic_init_secure
1:
#if defined(CONFIG_GICV3)
	ldr	x0, =GICR_BASE
	bl	gic_init_secure_percpu
#elif defined(CONFIG_GICV2)
	ldr	x0, =GICD_BASE
	ldr	x1, =GICC_BASE
	bl	gic_init_secure_percpu
#endif
#endif

#ifdef CONFIG_ARMV8_MULTIENTRY
	branch_if_master x0, 2f

	/*
	 * Slave should wait for master clearing spin table.
	 * This sync prevent slaves observing incorrect
	 * value of spin table and jumping to wrong place.
	 */
#if defined(CONFIG_GICV2) || defined(CONFIG_GICV3)
#ifdef CONFIG_GICV2
	ldr	x0, =GICC_BASE
#endif
	bl	gic_wait_for_interrupt
#endif

#if defined(CONFIG_SPL_BUILD) && !defined(CONFIG_SPL_ATF)
	/*
	 * Read the u-boot's PSCI exception handler's vector base
	 * address from the sysmgr.boot_scratch_cold6 & 7 and update
	 * their VBAR_EL3 respectively.
	 */
wait_vbar_el3:
	ldr	x4, =VBAR_EL3_BASE_ADDR
	ldr	x5, [x4]
	cbz	x5, wait_vbar_el3
	msr	vbar_el3, x5
#endif
	/*
	 * All slaves will enter EL2 and optionally EL1.
	 */
	adr	x4, lowlevel_in_el2
	ldr	x5, =ES_TO_AARCH64
	bl	armv8_switch_to_el2

lowlevel_in_el2:
#ifdef CONFIG_ARMV8_SWITCH_TO_EL1
	adr	x4, lowlevel_in_el1
	ldr	x5, =ES_TO_AARCH64
	bl	armv8_switch_to_el1

lowlevel_in_el1:
#endif

#endif /* CONFIG_ARMV8_MULTIENTRY */

2:
#if !defined(CONFIG_SPL_BUILD) && defined(CONFIG_ARMV8_PSCI)
	/*
	 * Write the u-boot PSCI exception handler's vector base address
	 * into a sysmgr.boot_scratch_cold6 & 7 so that other slave cpus
	 * are able to get the vector base address and update their VBAR_EL3
	 * respectively.
	 */
	adr	x0, _el3_exception_vectors
	ldr	x5, [x0]
	ldr	x4, =VBAR_EL3_BASE_ADDR
	str	x5, [x4]
#endif

#ifdef CONFIG_SPL_BUILD
	branch_if_slave x0, 3f

	/* Check rstmgr.stat for warm reset status */
	ldr	x1, =SOCFPGA_RSTMGR_ADDRESS
	ldr	x0, [x1]
	/* Check whether any L4 watchdogs or MPUs had triggered warm reset */
	ldr	x2, =0x000F0F00
	ands	x0, x0, x2
	/*
	 * If current Reset Manager's status is warm reset just reload the
	 * .data section by copying the data from data preserve section.
	 * Otherwise, copy the .data section to the data preserve section to
	 * keep an original copy of .data section. This ensure SPL is
	 * reentrant after warm reset.
	 */
	b.ne	reload_data_section
	/* Copy from .data to preserved .data to backup the SPL state */
	ldr	x0, =__data_start
	ldr	x1, =__preserve_data_start
	ldr	x2, =__preserve_data_end
	b	copy_loop
reload_data_section:
	/* Copy from preserved .data to .data to restore the SPL state */
	ldr	x0, =__preserve_data_start
	ldr	x1, =__data_start
	ldr	x2, =__data_end
copy_loop:
	ldr	w3, [x0]
	add	x0, x0, #4
	str	w3, [x1]
	add	x1, x1, #4
	cmp	x1, x2
	b.ne	copy_loop
3:
#endif
	mov	lr, x29			/* Restore LR */
	ret
ENDPROC(lowlevel_init)
