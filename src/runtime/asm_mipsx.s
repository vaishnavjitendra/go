// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// +build mips mipsle

#include "go_asm.h"
#include "go_tls.h"
#include "funcdata.h"
#include "textflag.h"

#define	REGCTXT	R22

TEXT runtime·rt0_go(SB),NOSPLIT,$0
	// R29 = stack; R1 = argc; R2 = argv

	ADDU	$-12, R29
	MOVW	R1, 4(R29)	// argc
	MOVW	R2, 8(R29)	// argv

	// create istack out of the given (operating system) stack.
	// _cgo_init may update stackguard.
	MOVW	$runtime·g0(SB), g
	MOVW	$(-64*1024), R23
	ADD	R23, R29, R1
	MOVW	R1, g_stackguard0(g)
	MOVW	R1, g_stackguard1(g)
	MOVW	R1, (g_stack+stack_lo)(g)
	MOVW	R29, (g_stack+stack_hi)(g)

// TODO(mips32): cgo

nocgo:
	// update stackguard after _cgo_init
	MOVW	(g_stack+stack_lo)(g), R1
	ADD	$const__StackGuard, R1
	MOVW	R1, g_stackguard0(g)
	MOVW	R1, g_stackguard1(g)

	// set the per-goroutine and per-mach "registers"
	MOVW	$runtime·m0(SB), R1

	// save m->g0 = g0
	MOVW	g, m_g0(R1)
	// save m0 to g0->m
	MOVW	R1, g_m(g)

	JAL	runtime·check(SB)

	// args are already prepared
	JAL	runtime·args(SB)
	JAL	runtime·osinit(SB)
	JAL	runtime·schedinit(SB)

	// create a new goroutine to start program
	MOVW	$runtime·mainPC(SB), R1	// entry
	ADDU	$-12, R29
	MOVW	R1, 8(R29)
	MOVW	R0, 4(R29)
	MOVW	R0, 0(R29)
	JAL	runtime·newproc(SB)
	ADDU	$12, R29

	// start this M
	JAL	runtime·mstart(SB)

	UNDEF
	RET

DATA	runtime·mainPC+0(SB)/4,$runtime·main(SB)
GLOBL	runtime·mainPC(SB),RODATA,$4

TEXT runtime·breakpoint(SB),NOSPLIT,$0-0
	BREAK
	RET

TEXT runtime·asminit(SB),NOSPLIT,$0-0
	RET

/*
 *  go-routine
 */

// void gosave(Gobuf*)
// save state in Gobuf; setjmp
TEXT runtime·gosave(SB),NOSPLIT,$-4-4
	MOVW	buf+0(FP), R1
	MOVW	R29, gobuf_sp(R1)
	MOVW	R31, gobuf_pc(R1)
	MOVW	g, gobuf_g(R1)
	MOVW	R0, gobuf_lr(R1)
	MOVW	R0, gobuf_ret(R1)
	// Assert ctxt is zero. See func save.
	MOVW	gobuf_ctxt(R1), R1
	BEQ	R1, 2(PC)
	JAL	runtime·badctxt(SB)
	RET

// void gogo(Gobuf*)
// restore state from Gobuf; longjmp
TEXT runtime·gogo(SB),NOSPLIT,$8-4
	MOVW	buf+0(FP), R3

	// If ctxt is not nil, invoke deletion barrier before overwriting.
	MOVW	gobuf_ctxt(R3), R1
	BEQ	R1, nilctxt
	MOVW	$gobuf_ctxt(R3), R1
	MOVW	R1, 4(R29)
	MOVW	R0, 8(R29)
	JAL	runtime·writebarrierptr_prewrite(SB)
	MOVW	buf+0(FP), R3

nilctxt:
	MOVW	gobuf_g(R3), g	// make sure g is not nil
	JAL	runtime·save_g(SB)

	MOVW	0(g), R2
	MOVW	gobuf_sp(R3), R29
	MOVW	gobuf_lr(R3), R31
	MOVW	gobuf_ret(R3), R1
	MOVW	gobuf_ctxt(R3), REGCTXT
	MOVW	R0, gobuf_sp(R3)
	MOVW	R0, gobuf_ret(R3)
	MOVW	R0, gobuf_lr(R3)
	MOVW	R0, gobuf_ctxt(R3)
	MOVW	gobuf_pc(R3), R4
	JMP	(R4)

// void mcall(fn func(*g))
// Switch to m->g0's stack, call fn(g).
// Fn must never return. It should gogo(&g->sched)
// to keep running g.
TEXT runtime·mcall(SB),NOSPLIT,$-4-4
	// Save caller state in g->sched
	MOVW	R29, (g_sched+gobuf_sp)(g)
	MOVW	R31, (g_sched+gobuf_pc)(g)
	MOVW	R0, (g_sched+gobuf_lr)(g)
	MOVW	g, (g_sched+gobuf_g)(g)

	// Switch to m->g0 & its stack, call fn.
	MOVW	g, R1
	MOVW	g_m(g), R3
	MOVW	m_g0(R3), g
	JAL	runtime·save_g(SB)
	BNE	g, R1, 2(PC)
	JMP	runtime·badmcall(SB)
	MOVW	fn+0(FP), REGCTXT	// context
	MOVW	0(REGCTXT), R4	// code pointer
	MOVW	(g_sched+gobuf_sp)(g), R29	// sp = m->g0->sched.sp
	ADDU	$-8, R29	// make room for 1 arg and fake LR
	MOVW	R1, 4(R29)
	MOVW	R0, 0(R29)
	JAL	(R4)
	JMP	runtime·badmcall2(SB)

// systemstack_switch is a dummy routine that systemstack leaves at the bottom
// of the G stack.  We need to distinguish the routine that
// lives at the bottom of the G stack from the one that lives
// at the top of the system stack because the one at the top of
// the system stack terminates the stack walk (see topofstack()).
TEXT runtime·systemstack_switch(SB),NOSPLIT,$0-0
	UNDEF
	JAL	(R31)	// make sure this function is not leaf
	RET

// func systemstack(fn func())
TEXT runtime·systemstack(SB),NOSPLIT,$0-4
	MOVW	fn+0(FP), R1	// R1 = fn
	MOVW	R1, REGCTXT	// context
	MOVW	g_m(g), R2	// R2 = m

	MOVW	m_gsignal(R2), R3	// R3 = gsignal
	BEQ	g, R3, noswitch

	MOVW	m_g0(R2), R3	// R3 = g0
	BEQ	g, R3, noswitch

	MOVW	m_curg(R2), R4
	BEQ	g, R4, switch

	// Bad: g is not gsignal, not g0, not curg. What is it?
	// Hide call from linker nosplit analysis.
	MOVW	$runtime·badsystemstack(SB), R4
	JAL	(R4)

switch:
	// save our state in g->sched.  Pretend to
	// be systemstack_switch if the G stack is scanned.
	MOVW	$runtime·systemstack_switch(SB), R4
	ADDU	$8, R4	// get past prologue
	MOVW	R4, (g_sched+gobuf_pc)(g)
	MOVW	R29, (g_sched+gobuf_sp)(g)
	MOVW	R0, (g_sched+gobuf_lr)(g)
	MOVW	g, (g_sched+gobuf_g)(g)

	// switch to g0
	MOVW	R3, g
	JAL	runtime·save_g(SB)
	MOVW	(g_sched+gobuf_sp)(g), R1
	// make it look like mstart called systemstack on g0, to stop traceback
	ADDU	$-4, R1
	MOVW	$runtime·mstart(SB), R2
	MOVW	R2, 0(R1)
	MOVW	R1, R29

	// call target function
	MOVW	0(REGCTXT), R4	// code pointer
	JAL	(R4)

	// switch back to g
	MOVW	g_m(g), R1
	MOVW	m_curg(R1), g
	JAL	runtime·save_g(SB)
	MOVW	(g_sched+gobuf_sp)(g), R29
	MOVW	R0, (g_sched+gobuf_sp)(g)
	RET

noswitch:
	// already on m stack, just call directly
	MOVW	0(REGCTXT), R4	// code pointer
	JAL	(R4)
	RET

/*
 * support for morestack
 */

// Called during function prolog when more stack is needed.
// Caller has already loaded:
// R1: framesize, R2: argsize, R3: LR
//
// The traceback routines see morestack on a g0 as being
// the top of a stack (for example, morestack calling newstack
// calling the scheduler calling newm calling gc), so we must
// record an argument size. For that purpose, it has no arguments.
TEXT runtime·morestack(SB),NOSPLIT,$-4-0
	// Cannot grow scheduler stack (m->g0).
	MOVW	g_m(g), R7
	MOVW	m_g0(R7), R8
	BNE	g, R8, 3(PC)
	JAL	runtime·badmorestackg0(SB)
	JAL	runtime·abort(SB)

	// Cannot grow signal stack (m->gsignal).
	MOVW	m_gsignal(R7), R8
	BNE	g, R8, 3(PC)
	JAL	runtime·badmorestackgsignal(SB)
	JAL	runtime·abort(SB)

	// Called from f.
	// Set g->sched to context in f.
	MOVW	R29, (g_sched+gobuf_sp)(g)
	MOVW	R31, (g_sched+gobuf_pc)(g)
	MOVW	R3, (g_sched+gobuf_lr)(g)
	// newstack will fill gobuf.ctxt.

	// Called from f.
	// Set m->morebuf to f's caller.
	MOVW	R3, (m_morebuf+gobuf_pc)(R7)	// f's caller's PC
	MOVW	R29, (m_morebuf+gobuf_sp)(R7)	// f's caller's SP
	MOVW	g, (m_morebuf+gobuf_g)(R7)

	// Call newstack on m->g0's stack.
	MOVW	m_g0(R7), g
	JAL	runtime·save_g(SB)
	MOVW	(g_sched+gobuf_sp)(g), R29
	// Create a stack frame on g0 to call newstack.
	MOVW	R0, -8(R29)	// Zero saved LR in frame
	ADDU	$-8, R29
	MOVW	REGCTXT, 4(R29)	// ctxt argument
	JAL	runtime·newstack(SB)

	// Not reached, but make sure the return PC from the call to newstack
	// is still in this function, and not the beginning of the next.
	UNDEF

TEXT runtime·morestack_noctxt(SB),NOSPLIT,$0-0
	MOVW	R0, REGCTXT
	JMP	runtime·morestack(SB)

TEXT runtime·stackBarrier(SB),NOSPLIT,$0
	// We came here via a RET to an overwritten LR.
	// R1 may be live. Other registers are available.

	// Get the original return PC, g.stkbar[g.stkbarPos].savedLRVal.
	MOVW	(g_stkbar+slice_array)(g), R2
	MOVW	g_stkbarPos(g), R3
	MOVW	$stkbar__size, R4
	MULU	R3, R4
	MOVW	LO, R4
	ADDU	R2, R4
	MOVW	stkbar_savedLRVal(R4), R4
	ADDU	$1, R3
	MOVW	R3, g_stkbarPos(g)	// Record that this stack barrier was hit.
	JMP	(R4)	// Jump to the original return PC.

// reflectcall: call a function with the given argument list
// func call(argtype *_type, f *FuncVal, arg *byte, argsize, retoffset uint32).
// we don't have variable-sized frames, so we use a small number
// of constant-sized-frame functions to encode a few bits of size in the pc.

#define DISPATCH(NAME,MAXSIZE)	\
	MOVW	$MAXSIZE, R23;	\
	SGTU	R1, R23, R23;	\
	BNE	R23, 3(PC);	\
	MOVW	$NAME(SB), R4;	\
	JMP	(R4)

TEXT reflect·call(SB),NOSPLIT,$0-20
	JMP	·reflectcall(SB)

TEXT ·reflectcall(SB),NOSPLIT,$-4-20
	MOVW	argsize+12(FP), R1

	DISPATCH(runtime·call16, 16)
	DISPATCH(runtime·call32, 32)
	DISPATCH(runtime·call64, 64)
	DISPATCH(runtime·call128, 128)
	DISPATCH(runtime·call256, 256)
	DISPATCH(runtime·call512, 512)
	DISPATCH(runtime·call1024, 1024)
	DISPATCH(runtime·call2048, 2048)
	DISPATCH(runtime·call4096, 4096)
	DISPATCH(runtime·call8192, 8192)
	DISPATCH(runtime·call16384, 16384)
	DISPATCH(runtime·call32768, 32768)
	DISPATCH(runtime·call65536, 65536)
	DISPATCH(runtime·call131072, 131072)
	DISPATCH(runtime·call262144, 262144)
	DISPATCH(runtime·call524288, 524288)
	DISPATCH(runtime·call1048576, 1048576)
	DISPATCH(runtime·call2097152, 2097152)
	DISPATCH(runtime·call4194304, 4194304)
	DISPATCH(runtime·call8388608, 8388608)
	DISPATCH(runtime·call16777216, 16777216)
	DISPATCH(runtime·call33554432, 33554432)
	DISPATCH(runtime·call67108864, 67108864)
	DISPATCH(runtime·call134217728, 134217728)
	DISPATCH(runtime·call268435456, 268435456)
	DISPATCH(runtime·call536870912, 536870912)
	DISPATCH(runtime·call1073741824, 1073741824)
	MOVW	$runtime·badreflectcall(SB), R4
	JMP	(R4)

#define CALLFN(NAME,MAXSIZE)	\
TEXT NAME(SB),WRAPPER,$MAXSIZE-20;	\
	NO_LOCAL_POINTERS;	\
	/* copy arguments to stack */		\
	MOVW	arg+8(FP), R1;	\
	MOVW	argsize+12(FP), R2;	\
	MOVW	R29, R3;	\
	ADDU	$4, R3;	\
	ADDU	R3, R2;	\
	BEQ	R3, R2, 6(PC);	\
	MOVBU	(R1), R4;	\
	ADDU	$1, R1;	\
	MOVBU	R4, (R3);	\
	ADDU	$1, R3;	\
	JMP	-5(PC);	\
	/* call function */			\
	MOVW	f+4(FP), REGCTXT;	\
	MOVW	(REGCTXT), R4;	\
	PCDATA	$PCDATA_StackMapIndex, $0;	\
	JAL	(R4);	\
	/* copy return values back */		\
	MOVW	argtype+0(FP), R5;	\
	MOVW	arg+8(FP), R1;	\
	MOVW	n+12(FP), R2;	\
	MOVW	retoffset+16(FP), R4;	\
	ADDU	$4, R29, R3;	\
	ADDU	R4, R3;	\
	ADDU	R4, R1;	\
	SUBU	R4, R2;	\
	JAL	callRet<>(SB);		\
	RET

// callRet copies return values back at the end of call*. This is a
// separate function so it can allocate stack space for the arguments
// to reflectcallmove. It does not follow the Go ABI; it expects its
// arguments in registers.
TEXT callRet<>(SB), NOSPLIT, $16-0
	MOVW	R5, 4(R29)
	MOVW	R1, 8(R29)
	MOVW	R3, 12(R29)
	MOVW	R2, 16(R29)
	JAL	runtime·reflectcallmove(SB)
	RET

CALLFN(·call16, 16)
CALLFN(·call32, 32)
CALLFN(·call64, 64)
CALLFN(·call128, 128)
CALLFN(·call256, 256)
CALLFN(·call512, 512)
CALLFN(·call1024, 1024)
CALLFN(·call2048, 2048)
CALLFN(·call4096, 4096)
CALLFN(·call8192, 8192)
CALLFN(·call16384, 16384)
CALLFN(·call32768, 32768)
CALLFN(·call65536, 65536)
CALLFN(·call131072, 131072)
CALLFN(·call262144, 262144)
CALLFN(·call524288, 524288)
CALLFN(·call1048576, 1048576)
CALLFN(·call2097152, 2097152)
CALLFN(·call4194304, 4194304)
CALLFN(·call8388608, 8388608)
CALLFN(·call16777216, 16777216)
CALLFN(·call33554432, 33554432)
CALLFN(·call67108864, 67108864)
CALLFN(·call134217728, 134217728)
CALLFN(·call268435456, 268435456)
CALLFN(·call536870912, 536870912)
CALLFN(·call1073741824, 1073741824)

TEXT runtime·procyield(SB),NOSPLIT,$0-4
	RET

// void jmpdefer(fv, sp);
// called from deferreturn.
// 1. grab stored LR for caller
// 2. sub 8 bytes to get back to JAL deferreturn
// 3. JMP to fn
TEXT runtime·jmpdefer(SB),NOSPLIT,$0-8
	MOVW	0(R29), R31
	ADDU	$-8, R31

	MOVW	fv+0(FP), REGCTXT
	MOVW	argp+4(FP), R29
	ADDU	$-4, R29
	NOR	R0, R0	// prevent scheduling
	MOVW	0(REGCTXT), R4
	JMP	(R4)

// Save state of caller into g->sched. Smashes R1.
TEXT gosave<>(SB),NOSPLIT,$0
	MOVW	R31, (g_sched+gobuf_pc)(g)
	MOVW	R29, (g_sched+gobuf_sp)(g)
	MOVW	R0, (g_sched+gobuf_lr)(g)
	MOVW	R0, (g_sched+gobuf_ret)(g)
	// Assert ctxt is zero. See func save.
	MOVW	(g_sched+gobuf_ctxt)(g), R1
	BEQ	R1, 2(PC)
	JAL	runtime·badctxt(SB)
	RET

// func asmcgocall(fn, arg unsafe.Pointer) int32
// Call fn(arg) on the scheduler stack,
// aligned appropriately for the gcc ABI.
// See cgocall.go for more details.
// Not implemented.
TEXT ·asmcgocall(SB),NOSPLIT,$0-12
	UNDEF

// cgocallback(void (*fn)(void*), void *frame, uintptr framesize)
// Turn the fn into a Go func (by taking its address) and call
// cgocallback_gofunc.
// Not implemented.
TEXT runtime·cgocallback(SB),NOSPLIT,$0-16
	UNDEF

// cgocallback_gofunc(FuncVal*, void *frame, uintptr framesize)
// See cgocall.go for more details.
// Not implemented.
TEXT ·cgocallback_gofunc(SB),NOSPLIT,$0-16
	UNDEF

// void setg(G*); set g. for use by needm.
// This only happens if iscgo, so jump straight to save_g
TEXT runtime·setg(SB),NOSPLIT,$0-4
	MOVW	gg+0(FP), g
	JAL	runtime·save_g(SB)
	RET

// void setg_gcc(G*); set g in C TLS.
// Must obey the gcc calling convention.
// Not implemented.
TEXT setg_gcc<>(SB),NOSPLIT,$0
	UNDEF

TEXT runtime·getcallerpc(SB),NOSPLIT,$4-8
	MOVW	8(R29), R1	// LR saved by caller
	MOVW	runtime·stackBarrierPC(SB), R2
	BNE	R1, R2, nobar
	JAL	runtime·nextBarrierPC(SB)	// Get original return PC.
	MOVW	4(R29), R1
nobar:
	MOVW	R1, ret+4(FP)
	RET

TEXT runtime·setcallerpc(SB),NOSPLIT,$4-8
	MOVW	pc+4(FP), R1
	MOVW	8(R29), R2
	MOVW	runtime·stackBarrierPC(SB), R3
	BEQ	R2, R3, setbar
	MOVW	R1, 8(R29)	// set LR in caller
	RET
setbar:
	MOVW	R1, 4(R29)
	JAL	runtime·setNextBarrierPC(SB)	// Set the stack barrier return PC.
	RET

TEXT runtime·abort(SB),NOSPLIT,$0-0
	UNDEF

// memhash_varlen(p unsafe.Pointer, h seed) uintptr
// redirects to memhash(p, h, size) using the size
// stored in the closure.
TEXT runtime·memhash_varlen(SB),NOSPLIT,$16-12
	GO_ARGS
	NO_LOCAL_POINTERS
	MOVW	p+0(FP), R1
	MOVW	h+4(FP), R2
	MOVW	4(REGCTXT), R3
	MOVW	R1, 4(R29)
	MOVW	R2, 8(R29)
	MOVW	R3, 12(R29)
	JAL	runtime·memhash(SB)
	MOVW	16(R29), R1
	MOVW	R1, ret+8(FP)
	RET

// Not implemented.
TEXT runtime·aeshash(SB),NOSPLIT,$0
	UNDEF

// Not implemented.
TEXT runtime·aeshash32(SB),NOSPLIT,$0
	UNDEF

// Not implemented.
TEXT runtime·aeshash64(SB),NOSPLIT,$0
	UNDEF

// Not implemented.
TEXT runtime·aeshashstr(SB),NOSPLIT,$0
	UNDEF

// memequal(a, b unsafe.Pointer, size uintptr) bool
TEXT runtime·memequal(SB),NOSPLIT,$0-13
	MOVW	a+0(FP), R1
	MOVW	b+4(FP), R2
	BEQ	R1, R2, eq
	MOVW	size+8(FP), R3
	ADDU	R1, R3, R4
loop:
	BNE	R1, R4, test
	MOVW	$1, R1
	MOVB	R1, ret+12(FP)
	RET
test:
	MOVBU	(R1), R6
	ADDU	$1, R1
	MOVBU	(R2), R7
	ADDU	$1, R2
	BEQ	R6, R7, loop

	MOVB	R0, ret+12(FP)
	RET
eq:
	MOVW	$1, R1
	MOVB	R1, ret+12(FP)
	RET

// memequal_varlen(a, b unsafe.Pointer) bool
TEXT runtime·memequal_varlen(SB),NOSPLIT,$0-9
	MOVW	a+0(FP), R1
	MOVW	b+4(FP), R2
	BEQ	R1, R2, eq
	MOVW	4(REGCTXT), R3	// compiler stores size at offset 4 in the closure
	ADDU	R1, R3, R4
loop:
	BNE	R1, R4, test
	MOVW	$1, R1
	MOVB	R1, ret+8(FP)
	RET
test:
	MOVBU	(R1), R6
	ADDU	$1, R1
	MOVBU	(R2), R7
	ADDU	$1, R2
	BEQ	R6, R7, loop

	MOVB	R0, ret+8(FP)
	RET
eq:
	MOVW	$1, R1
	MOVB	R1, ret+8(FP)
	RET

// eqstring tests whether two strings are equal.
// The compiler guarantees that strings passed
// to eqstring have equal length.
// See runtime_test.go:eqstring_generic for
// equivalent Go code.
TEXT runtime·eqstring(SB),NOSPLIT,$0-17
	MOVW	s1_base+0(FP), R1
	MOVW	s2_base+8(FP), R2
	MOVW	$1, R3
	MOVBU	R3, ret+16(FP)
	BNE	R1, R2, 2(PC)
	RET
	MOVW	s1_len+4(FP), R3
	ADDU	R1, R3, R4
loop:
	BNE	R1, R4, 2(PC)
	RET
	MOVBU	(R1), R6
	ADDU	$1, R1
	MOVBU	(R2), R7
	ADDU	$1, R2
	BEQ	R6, R7, loop
	MOVB	R0, ret+16(FP)
	RET

TEXT bytes·Equal(SB),NOSPLIT,$0-25
	MOVW	a_len+4(FP), R3
	MOVW	b_len+16(FP), R4
	BNE	R3, R4, noteq	// unequal lengths are not equal

	MOVW	a+0(FP), R1
	MOVW	b+12(FP), R2
	ADDU	R1, R3	// end

loop:
	BEQ	R1, R3, equal	// reached the end
	MOVBU	(R1), R6
	ADDU	$1, R1
	MOVBU	(R2), R7
	ADDU	$1, R2
	BEQ	R6, R7, loop

noteq:
	MOVB	R0, ret+24(FP)
	RET

equal:
	MOVW	$1, R1
	MOVB	R1, ret+24(FP)
	RET

TEXT bytes·IndexByte(SB),NOSPLIT,$0-20
	MOVW	s+0(FP), R1
	MOVW	s_len+4(FP), R2
	MOVBU	c+12(FP), R3	// byte to find
	ADDU	$1, R1, R4	// store base+1 for later
	ADDU	R1, R2	// end

loop:
	BEQ	R1, R2, notfound
	MOVBU	(R1), R5
	ADDU	$1, R1
	BNE	R3, R5, loop

	SUBU	R4, R1	// R1 will be one beyond the position we want so remove (base+1)
	MOVW	R1, ret+16(FP)
	RET

notfound:
	MOVW	$-1, R1
	MOVW	R1, ret+16(FP)
	RET

TEXT strings·IndexByte(SB),NOSPLIT,$0-16
	MOVW	s_base+0(FP), R1
	MOVW	s_len+4(FP), R2
	MOVBU	c+8(FP), R3	// byte to find
	ADDU	$1, R1, R4	// store base+1 for later
	ADDU	R1, R2	// end

loop:
	BEQ	R1, R2, notfound
	MOVBU	(R1), R5
	ADDU	$1, R1
	BNE	R3, R5, loop

	SUBU	R4, R1	// remove (base+1)
	MOVW	R1, ret+12(FP)
	RET

notfound:
	MOVW	$-1, R1
	MOVW	R1, ret+12(FP)
	RET

TEXT runtime·cmpstring(SB),NOSPLIT,$0-20
	MOVW	s1_base+0(FP), R3
	MOVW	s1_len+4(FP), R1
	MOVW	s2_base+8(FP), R4
	MOVW	s2_len+12(FP), R2
	BEQ	R3, R4, samebytes
	SGTU	R1, R2, R7
	MOVW	R1, R8
	CMOVN	R7, R2, R8	// R8 is min(R1, R2)

	ADDU	R3, R8	// R3 is current byte in s1, R8 is last byte in s1 to compare
loop:
	BEQ	R3, R8, samebytes	// all compared bytes were the same; compare lengths

	MOVBU	(R3), R6
	ADDU	$1, R3
	MOVBU	(R4), R7
	ADDU	$1, R4
	BEQ	R6, R7 , loop
	// bytes differed
	SGTU	R6, R7, R8
	MOVW	$-1, R6
	CMOVZ	R8, R6, R8
	JMP	cmp_ret
samebytes:
	SGTU	R1, R2, R6
	SGTU	R2, R1, R7
	SUBU	R7, R6, R8
cmp_ret:
	MOVW	R8, ret+16(FP)
	RET

TEXT bytes·Compare(SB),NOSPLIT,$0-28
	MOVW	s1_base+0(FP), R3
	MOVW	s2_base+12(FP), R4
	MOVW	s1_len+4(FP), R1
	MOVW	s2_len+16(FP), R2
	BEQ	R3, R4, samebytes
	SGTU	R1, R2, R7
	MOVW	R1, R8
	CMOVN	R7, R2, R8	// R8 is min(R1, R2)

	ADDU	R3, R8	// R3 is current byte in s1, R8 is last byte in s1 to compare
loop:
	BEQ	R3, R8, samebytes

	MOVBU	(R3), R6
	ADDU	$1, R3
	MOVBU	(R4), R7
	ADDU	$1, R4
	BEQ	R6, R7 , loop

	SGTU	R6, R7, R8
	MOVW	$-1, R6
	CMOVZ	R8, R6, R8
	JMP	cmp_ret
samebytes:
	SGTU	R1, R2, R6
	SGTU	R2, R1, R7
	SUBU	R7, R6, R8
cmp_ret:
	MOVW	R8, ret+24(FP)
	RET

TEXT runtime·fastrand(SB),NOSPLIT,$0-4
	MOVW	g_m(g), R2
	MOVW	m_fastrand(R2), R1
	ADDU	R1, R1
	BGEZ	R1, 2(PC)
	XOR	$0x88888eef, R1
	MOVW	R1, m_fastrand(R2)
	MOVW	R1, ret+0(FP)
	RET

TEXT runtime·return0(SB),NOSPLIT,$0
	MOVW	$0, R1
	RET

// Called from cgo wrappers, this function returns g->m->curg.stack.hi.
// Must obey the gcc calling convention.
// Not implemented.
TEXT _cgo_topofstack(SB),NOSPLIT,$-4
	UNDEF

// The top-most function running on a goroutine
// returns to goexit+PCQuantum.
TEXT runtime·goexit(SB),NOSPLIT,$-4-0
	NOR	R0, R0	// NOP
	JAL	runtime·goexit1(SB)	// does not return
	// traceback from goexit1 must hit code range of goexit
	NOR	R0, R0	// NOP

TEXT runtime·prefetcht0(SB),NOSPLIT,$0-4
	RET

TEXT runtime·prefetcht1(SB),NOSPLIT,$0-4
	RET

TEXT runtime·prefetcht2(SB),NOSPLIT,$0-4
	RET

TEXT runtime·prefetchnta(SB),NOSPLIT,$0-4
	RET

TEXT ·checkASM(SB),NOSPLIT,$0-1
	MOVW	$1, R1
	MOVB	R1, ret+0(FP)
	RET
