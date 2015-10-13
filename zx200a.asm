; Zendex ZX-200A Multibus floppy disk controller firmware
; Copyright disavowed 2015

; 2716 EPROM labelled BD-5 V1.3

; disassembled by Eric Smith <spacewar@gmail.com>

; cross-assembles with AS Macro Assembler:
;    http://john.ccac.rwth-aachen.de:8000/as/
; NOTE: will not assemble with most CP/M resident
; assemblers due to the use of long symbols

; limitations:
; * when formatting, doesn't write an index mark
; * doesn't handle reading deleted data
; * doesn't generate drive status changed interrupts
;     for single density
; * doesn't generate two drive status changed interrupts
;     when ready went false then true again during an
;     operation

; The ZX-200A emulates two Intel Multibus floppy disk controllers
; normally found in Intel MDS development systems:
;
; * Intel iSBC 201 single-density floppy disk controller, which
;   supports two eight-inch drives using an IBM-compatible FM
;   format with 26 sectors per track of 128 bytes per sector.,
;
; * Intel iSBC 202 double-density floppy disk controller, which
;   supports four eight-inch drives using an incompatible M2FM
;   format with 52 sectors per track of 128 bytes per sector.
;
; The ZX-200A appears to the host as both Intel controllers,
; and provides most of the functionality of both, using the same
; connected floppy drives.  Assuming no hard disk is present in
; the system, the drives are mapped as:
;
;             double-   single-
;             density   density
; hardware:    ISIS      ISIS
; ---------   -------   -------
; drive 0      :F0:      :F4:
; drive 1      :F1:      :F5:
; drive 2      :F2:
; drive 3      :F3:
;
; If an MDS 740 or MDX 750 hard disk subsystem is present, the
; ISIS drive numbers above are each increased by four.

fillto	macro	endaddr
	while	$<endaddr
	if	(endaddr-$)>1024
	db	1024 dup (0ffh)
	else
	db	(endaddr-$) dup (0ffh)
	endif
	endm
	endm


; FM (single-density) mark patterns, IBM-compatible
fm_index_mark		equ	0fch	; clock 0d7h
fm_address_mark		equ	0feh	; clock 0c7h
fm_data_mark		equ	0fbh	; clock 0c7h
fm_deleted_data_mark	equ	0f8h	; clock 0c7h

; M2FM (double-density) mark patterns
m2fm_index_mark		equ	00ch	; clock 071h
m2fm_address_mark	equ	00eh	; clock 070h
m2fm_data_mark		equ	00bh	; clock 070h
m2fm_deleted_data_mark	equ	008h	; clock 072h


; There is 1KB of local RAM, implemented by two 2114 1Kx4
; static RAM chips
ram_start	equ	4000h
stack		equ	ram_start + 0200h
local_buffer	equ	ram_start + 0300h


; I/O ports

; The ZX-200A design depends on the 8080/8085 feature that I/O port
; access puts the port address on both the low and high bytes of the
; address bus. Note that the Z80 CPU does not have that behavior, and
; the high byte of the address bus during Z80 I/O cycles is either the
; A or B register.

; The ZX-200A ignores the 8085 IO/M signal, so input or output to port
; 0ABh is equivalent to memory read or write to address 0ABABh.  The
; memory map of most of the I/O ports is deliberately incompletely
; decoded, ignoring the low byte of the address, so that a
; memory-mapped device nominally at 0AB00h is mapped to the full
; 0AB00h through 0ABFFh range, to allow access by I/O instructions to
; port 0ABh.

; The IN and OUT instructions have the advantage of taking only 10
; clock cycles, vs. 13 for the LDA and STA instructions. At 3 MHz
; (using 6 MHz crystal), the I/O instructions take 3.33 us vs. the
; LDA/STA which take 4.33 us. This performance advantage is useful in
; tight data transfer loops, if another register pair is not available
; for the port address.
 
; The host interface registers, read at 6400h..6401h and 6500h..6501h,
; and written at 6400h..6403h, and the DMA controller at 2000h..200fh,
; are counterexamples which do depend on low-order address bits, so
; care should be taken if accessing them via I/O instructions.  It appears
; that it should be possible to access the DMAC registers at I/O addresses
; 20h..2fh, but this has not been verifed.


; 8257 DMAC registers, memory-mapped

; Only channel 0 is used, and it can transfer 1 to 256 bytes to or
; from the Multibus system memory.  When the DMAC does a transfer to
; or from Multibus memory address HHLLh, the local side of the
; transfer is address 43LLh.  In other words, if the ZX-200A is told
; by the host to use an IOPB at Multibus address 62fch, it will copy
; ten bytes from Multibus 62fch through 6305h to local memory 43fch
; through 43ffh then 4300h through 4305h.  Writes to Multibus memory
; work the same way, with the local source having to be in the 43xx
; page, and the low byte of the local address matching the low byte of
; the Multibus address.

dmac_ch_0_addr	equ	2000h
dmac_ch_0_tc	equ	0001h
dmac_mode_set	equ	2008h


	
; disk serializer/deserializer interface (memory-mapped):
serdes_fm_mark		equ	6000h
serdes_m2fm_mark	equ	6100h
serdes_data		equ	6200h
serdes_crc		equ	6300h

serdes_match		equ	6500h	; write pattern to match in rx data stream


; SBC 202 (double density) host interface (memory-mapped):
dhost_r6400		equ	6400h	; read
dhost_iopb_addr		equ	6401h	; read 16-bit

dhost_w6400		equ	6400h	; write
dhost_w6401		equ	6401h	; write
dhost_w6402		equ	6402h	; write
dhost_result_byte	equ	6403h	; write


; SBC 201 (single density) host interface (memory-mapped):
shost_r6500		equ	6500h	; read
shost_iopb_addr		equ	6501h	; read 16-bit


; drive interface
p_drive_status		equ	6600h	; input:  bit 7: CRC error status
					;         bit 6: track00 status
					;         bit 5: write protect (causes seek error?)
					;         bit 4: W1 jumper
					;         bit 3: W2 jumper
					;         bit 2: index
					;	  bit 1: two-sided
					;         bit 0: ready

p_drive_select		equ	6600h	; output: (all negative logic)
					;         bit 7: side select (unused)
					;         bit 6: drive 0 select
					;         bit 5: drive 1 select
					;         bit 4: drive 2 select
					;         bit 3: drive 3 select
					;         bit 2: TG43
					;         bit 1: direction
					;         bit 0: step

p_radial_ready		equ	6700h	; input:  bit 7: SD int pending
					;         bit 6: DD int pending
					;         bit 5: unused
					;         bit 4: unused
					;         bit 3: drive 3 ready status
					;         bit 2: drive 2 ready status
					;         bit 1: drive 1 ready status
					;         bit 0: drive 0 ready status
				
p_mode			equ	6700h	; output: bit 7: 1 to set SD host interrupt
					;         bit 6: 1 to set DD host interrupt
					;         bit 5: unused?
					;         bit 4: unused?
					;         bit 3: ???
					;         bit 2: enables floppy control
					;         bit 1: enables writing floppy
					;         bit 0: 1=FM, 0=M2FM



host_clear_new_iopb	equ	8000h	; input: clears host new IOPB interrupt flags


			org	ram_start
iopb			equ	$
iopb_channel_word:	ds	1
iopb_instruction:	ds	1
iopb_rec_count:		ds	1
iopb_track:		ds	1
iopb_sector:		ds	1
iopb_buffer_addr:	ds	2
iopb_block_num:		ds	1
iopb_link_addr:		ds	2

drive_sel_bits:		ds	1
host_iopb_addr:		ds	2	; current host IOPB addr (SD only)
current_unit:		ds	1	; 0..3, or 0ffh for none
current_track_table:	ds	4	; indexed by unit number
density:		ds	1	; 000h for single (FM), 0ffh for double (M2FM)
index_counter:		ds	1
drive_ready_status:	ds	1
cmd_is_write:		ds	1	; 000h for read cmds, 0ffh for write
data_mark:		ds	1
X4017:			ds	1
X4018:			ds	1
X4019:			ds	1
need_recal_tbl:		ds	4	; indexed by unit number,
					; needs recal if 000h


	org	0

; reset entry
	nop
	add	b	; ???

	xra	a
	lxi	sp,stack
	lxi	h,ram_start
X0009:	mov	m,a
	inr	l
	jnz	X0009

	in	p_radial_ready >> 8
	ani	0fh
	sta	drive_ready_status

X0015:	mvi	a,0ffh			; no drive selected
	sta	current_unit

	xra	a
	out	p_mode >> 8

	jmp	main_loop


; trap interrupt entry
; index pulse from selected drive
	fillto	024h
	push	psw
	jmp	trap2


; rst 5.5 interrupt entry
; SBC 201 (single density) command
	fillto	02ch
	lhld	shost_iopb_addr
	in	host_clear_new_iopb >> 8
	jmp	sd_new_host_iopb


; rst 6.5 interrupt entry
; SBC 202 (double density) command
	fillto	034h
	lhld	dhost_iopb_addr
	in	host_clear_new_iopb >> 8
	jmp	dd_new_host_iopb


; rst 7.5 interrupt entry
; Used for host write to port base+3 to stop operation after current
; IOPB is completed (SD only).
	fillto	03ch
X003c:	push	psw
	lda	iopb_channel_word
	ani	0fbh			; mask off successor bit
	sta	iopb_channel_word	; store back

	mvi	a,10h			; 7.5 not allowed
	sim

	pop	psw
	ret


; continuation of trap interrupt handler
trap2:	lda	index_counter
	dcr	a
	sta	index_counter
	rim				; not necessary
	pop	psw
	ret


; main loop
main_loop:
	mvi	a,8		; mask set enable, and all x.5 interrupts enabled
	ei
	sim
	
	in	p_radial_ready >> 8
	mov	b,a
	ani	0c0h
	jnz	X006a

	mov	a,b
	ani	0fh
	lxi	h,drive_ready_status
	cmp	m
	cnz	X0074

X006a:	lda	index_counter
	ora	a
	jnz	main_loop
	jmp	X0015


; interrupt host with diskette ready status
X0074:	mov	c,a
	rrc
	rrc
	mov	b,a
	mov	a,c
	rlc
	rlc
	ora	b
	ori	0fh
	cma
	sta	dhost_w6401
	sta	dhost_result_byte

	mvi	a,2			; result byte contains diskette ready status
	sta	dhost_w6400
	sta	dhost_w6402

	lda	current_unit		; is a drive selected
	inr	a
	jz	X0096			;   no

	mvi	a,8			;   yes

X0096:	ori	40h			; generate DD host interrupt - why no SD host interrupt?
	out	p_mode >> 8
	mov	m,c
	ret


; double-density command
; HL contains IOPB host address
dd_new_host_iopb:
	pop	d		; pop and discard interrupt return status

	lda	dhost_r6400
	out	serdes_data >> 8

	call	execute_dd

	sta	dhost_result_byte

	mvi	a,0		; I/O complete (unlinked)
	sta	dhost_w6402

	mvi	a,4
	out	p_mode >> 8

	mvi	a,8
	sta	index_counter

	lda	iopb_channel_word
	ani	10h		; interrupt disabled?
	jnz	main_loop

	mvi	a,44h		; generate DD host interrupt
	out	p_mode >> 8
	
	jmp	main_loop


; single-density command
sd_new_host_iopb:
	pop	d		; pop and discard interrupt return address

; HL contains IOPB host address
sd_next_iopb:
	di

	lda	shost_r6500
	out	serdes_data >> 8

	call	execute_sd

	push	psw

	sta	dhost_w6401
	lda	iopb_channel_word
	mov	b,a
	ani	4		; successor bit
	jz	X00e3

	lda	iopb_block_num
	rlc
	rlc
	ori	3
X00e3:	dcr	a
	cma
	sta	dhost_w6400

	pop	psw

	ora	a
	cnz	X003c
	
	mvi	a,0dh		; mask set enable, and only 6.5 interrupt enabled
	ei
	sim

	mvi	a,4
	out	p_mode >> 8

	mvi	a,8
	sta	index_counter

	mov	a,b

	push	psw	; save channel word (A)

	rlc		; lock override?
	jc	X0111	; yes

; update channel word of host IOPB
	lhld	host_iopb_addr	; get current host IOPB addr and save
	push	h

	mvi	h,local_buffer>>8	; convert to local buffer addr
	rrc			; shift channel word back into original position
	ori	1		; set wait bit
	mov	m,a

	pop	h		; get back saved host IOPB addr
	lxi	b,04000h	; write 1 byte
	call	start_dma

X0111:	pop	psw		; restore channel word into B
	mov	b,a

	ani	20h		; interrupt after current operation?
	jnz	X0127		;   yes

	lhld	iopb_link_addr	; get linked IOPB host addr
	mov	a,b
	ani	4		; successor bit?
	jnz	sd_next_iopb	;   yes, proceed to next IOPB

	mov	a,b		; interrupt disabled?
	ani	10h
	jnz	main_loop

X0127:	mvi	a,84h		; generate SD host interrupt
	out	p_mode >> 8

X012b:	lda	iopb_channel_word
	ani	4		; successor bit?
	jz	main_loop	;   no, done

	mvi	a,0ah		; mask set enable, and ints 7.5 and 5.5 enabled
	sim

	in	p_radial_ready >> 8
	ani	80h
	jnz	X012b
	lhld	iopb_link_addr
	jmp	sd_next_iopb


; execute a double-density command
execute_dd:
	call	get_iopb

	lda	iopb_instruction
	rrc
	rrc
	rrc
	rrc
	ani	3		; unit select bits
	mov	c,a

	mvi	e,4		; double density bits for p_mode

	mvi	a,m2fm_data_mark	; normal M2FM data mark
	sta	data_mark

	mvi	a,0ffh		; set double density (M2FM)
	jmp	execute


execute_sd_next:
	lhld	iopb_link_addr
	rrc
	jc	execute_sd

	mvi	b,0ah
	call	delay

	lhld	host_iopb_addr

execute_sd:
	shld	host_iopb_addr

	call	get_iopb
	
	lda	iopb_channel_word
	rrc			; wait bit
	jc	execute_sd_next


; Intel uses a non-obvious logical unit number encoding in the
; IOPB disk instruction byte:
;
;  bit  bit  logical  
;   5    4   unit #   
;  ---  ---  -------  
;   0    0     0      
;   1    1     1      
;   1    0     2   (DD only)
;   0    1     3   (DD only)

	lda	iopb_instruction	; decode unit number (0..3) into C
	rrc
	rrc
	rrc
	ani	6
	mov	c,a
	rrc
	xra	c
	ani	3
	mov	c,a

	mvi	e,5		; single density bits for p_mode

	mvi	a,fm_data_mark	; normal FM data mark
	sta	data_mark

	xra	a		; set single density (FM)

execute:
	sta	density

	lxi	h,tbl_drive	; look up drive table entry for unit # in C
	mvi	b,0
	dad	b
	dad	b
	mov	d,m		; get first byte of entry, drive ready mask

	in	p_radial_ready >> 8	; is the drive ready?
	ana	d
	mvi	a,80h		; prepare for not ready error
	rnz			;   drive isn't ready, return

	push	b		; save unit number in BC

	inx	h		; get second byte of drive table entry,
	mov	a,m		;   drive select bit
	out	p_drive_select >> 8
	sta	drive_sel_bits

	lda	current_unit	; set ZF false if unit changed
	cmp	c
	mov	a,c		; and save selected unit
	sta	current_unit

	mov	a,e		; set hardware density
	out	p_mode >> 8

	mvi	b,23h		; if the selected unit changed, delay
	cnz	delay

	pop	b			; get unit number back from BC
	lxi	h,need_recal_tbl	; does it need a recal?
	dad	b
	mov	a,m			; get current table entry
	mvi	m,0ffh			; set table entry for no recal needed
	ora	a			; was entry 000h?
	cz	op_recalibrate		;   yes, recalibrate

	lxi	h,tbl_op_dispatch
	lda	iopb_instruction
	rlc
	ani	0eh
	mov	e,a
	mvi	d,0
	dad	d
	mov	e,m
	inx	h
	mov	d,m
	xchg
	pchl

tbl_op_dispatch:
	dw	op_no_operation
	dw	op_seek
	dw	op_format_track
	dw	op_recalibrate
	dw	op_read
	dw	op_verify_crc
	dw	op_write
	dw	op_write_deleted


; table with a two-byte entry for each logical unit (0-3)
; The first byte of each entry is the mask for the ready bit
; from the hardware port p_radial_ready.
tbl_drive:
	db	001h,0bfh
	db	002h,0dfh
	db	004h,0efh
	db	008h,0f7h


; copy IOPB into local memory
; on entry:
;   HL = host address
get_iopb:
	lxi	b,08009h	; read 10 bytes
	call	start_dma
	mvi	h,local_buffer>>8

	lxi	d,iopb		; D = local addr of IOPB
	mvi	c,10		; C = byte count (10 to include linked IOPBs)
X01fa:	mov	a,m
	stax	d
	inx	d
	inr	l
	dcr	c
	jnz	X01fa
	ret


; set up DMA channel 0 and start DMA
; on entry:
;   HL = host address
;   BC = terminal count (low 14 bits), RD (bit 15), WR (bit 14)      
start_dma:
	sub	a
	out	serdes_match >> 8
	
	push	h
	xchg

	; load channel 0 DMA address from DE (was in HL)
	lxi	h,dmac_ch_0_addr
	mov	m,e
	mov	m,d

	; load channel 0 terminal count from BC
	inx	h
	mov	m,c
	mov	m,b
	
	mvi	a,41h	; TC stop + Enabel channel 0
	sta	dmac_mode_set

	pop	h
	ret


op_no_operation:
	call	op_seek
	ora	a
	rnz

; using record count as a sub-op for diagnostic loops?
	lda	iopb_rec_count
	ani	7
	rlc
	mov	c,a
	mvi	b,0
	lxi	h,tbl_diag_cmd_dispatch
	dad	b
	mov	e,m
	inx	h
	mov	d,m
	xchg
	pchl

tbl_diag_cmd_dispatch:
	dw	diag_loop_read_6200
	dw	diag_loop_read_6100
	dw	diag_loop_write_6200
	dw	diag_loop_write_6100
	dw	diag_dma_read_once
	dw	diag_dma_read_forever
	dw	diag_dma_write_once
	dw	diag_dma_write_forever
	
diag_loop_read_6200:
	lxi	d,serdes_data

X0241:	ldax	d		; infinite loop (escape by interrupt?)
	jmp	X0241

diag_loop_read_6100:
	lxi	d,serdes_m2fm_mark
	jmp	X0241

diag_loop_write_6200:
	lxi	d,serdes_data
	jmp	X0254

diag_loop_write_6100:
	lxi	d,serdes_m2fm_mark
X0254:	push	d
	call	X02f0
	pop	d
	rz

	lda	iopb_sector

X025d:	stax	d		; infinite loop (escape by interrupt?)
	jmp	X025d


diag_dma_read_once:
	mvi	c,0
	jmp	X0268

diag_dma_read_forever:
	mvi	c,0ffh
X0268:	mvi	b,80h
	jmp	X0276

diag_dma_write_once:
	mvi	c,0
	jmp	X0274

diag_dma_write_forever:
	mvi	c,0ffh
X0274:	mvi	b,40h

; at this point, b=40h for write, 80h for read
;                c=00h for once, ffh to loop forever
X0276:	push	b		; save DMA direction, flag
	mvi	c,0ffh		; transfer 256 bytes
	lhld	iopb_buffer_addr		
	call	start_dma
	pop	b
	xra	a
	ora	c
	jnz	X0276
	ret


op_seek:
	lda	iopb_track		; is IOPB track zero?
	ora	a
	jz	op_recalibrate

	mov	d,a		; save target track number in D
	cpi	77
	mvi	a,8		; address error
	rnc

	mov	a,d		; track greater than 43?
	cpi	43
	jc	X02a0

	lxi	h,drive_sel_bits	; set TG43 (negative logic)
	mov	a,m
	ani	0fbh
	mov	m,a

X02a0:	call	get_current_track_entry
X02a3:	mov	a,d
	sub	m
	rz
	call	track_step
	jmp	X02a3


; on entry:
;   CF = 0 for outward (toward 0)
;   CF = 1 for inward  (toward 76)
track_step:
	lda	drive_sel_bits

				; stepping inward (toward 76) or outward (toward 0)?
	jc	X02b6		;   branch if stepping out


	ani	0fdh		; set direction signal to inward (negative logic)
	inr	m		; increment track number by two, will get
	inr	m		;   decremented below

X02b6:	dcr	m		; decrement track number

	out	p_drive_select >> 8	; output drive select with direction

	dcr	a		; set step signal active (low)
	nop
	out	p_drive_select >> 8	; start step pulse

	nop			; end step pulse
	ori	1
	out	p_drive_select >> 8

	nop			; set direction signal to outward (negative logic)
	ori	2
	out	p_drive_select >> 8

; track step delay
	mvi	b,8

delay:	mvi	c,0d6h
X02cb:	dcr	c
	jnz	X02cb
	dcr	b
	jnz	delay
	ret


; On exit:
;   HL points to current track table entry for unit
get_current_track_entry:
	lxi	h,current_track_table
	lda	current_unit
	mov	c,a
	mvi	b,0
	dad	b
	ret


op_recalibrate:
	call	get_current_track_entry
recal_loop:
	mvi	m,0		; clear current track

	in	p_drive_status >> 8	; at track zero?
	ani	40h
	rz			;   yes, done

	stc
	call	track_step
	jmp	recal_loop


X02f0:	lda	density
	cma
	ani	1
	ori	6
	out	p_mode >> 8

	in	p_drive_status >> 8	; check write protect
	ani	20h
	mvi	a,20h
	ret


op_read:
op_verify_crc:
	xra	a
	jmp	read_or_write


op_write_deleted:
	lxi	h,data_mark
	mov	a,m
	ani	0f8h		; deleted data mark
	mov	m,a

op_write:
	call	X02f0
	rz
	mvi	a,0ffh

read_or_write:
	sta	cmd_is_write

	call	op_seek
	ora	a
	rnz

	lxi	h,iopb_sector

	mvi	b,54			; DD max sector # +2

	lda	density			; is double density?
	ora	a
	mov	a,m			; get sector number
	jnz	X032c			;   DD

	ani	1fh			; SD: mask off upper three bits
	mov	m,a
	mvi	b,28			; SD max sector # +2

X032c:	inr	a			; is sector number zero?
	sta	X4019
	dcr	a
	mvi	a,8
	rz				;   yes, address error

	lxi	d,iopb_rec_count	; is sector number + rec count too high?
	ldax	d
	add	m
	cmp	b
	mvi	a,8
	rnc				;   yes, address error

	ldax	d
	ora	a
	rar
	sta	X4018
	aci	0
	stax	d

X0346:	xra	a
	sta	X4017

; if it is a write command, read a sector from host memory
	lhld	iopb_buffer_addr
	lxi	b,0807fh		; read 128 bytes
	lda	cmd_is_write
	ora	a
	cnz	start_dma

	mvi	a,4
	sta	index_counter
	
X035c:	lxi	h,serdes_match
	lxi	d,serdes_data
	lda	density
	ora	a
	jz	X04b1

; double-density address field search
X0369:	mvi	m,0
	in	p_drive_status >> 8	; prepare CRC generator

X036d:	lda	index_counter
	ora	a
	jm	X0470

X0374:	inr	b
	jz	X036d
	lda	serdes_crc
	inr	a
	jnz	X0374
	mvi	c,6
X0381:	ldax	d
	inr	a
	jnz	X0374
	dcr	c
	jnz	X0381
	mvi	m,70h
	ldax	d

	lda	serdes_m2fm_mark
	cpi	m2fm_address_mark	; is ID address mark?
	jnz	X0369

address_mark_found:
	ldax	d			; read track number
	lxi	h,iopb_track
	cmp	m
	jnz	addr_field_wrong_track

	ldax	d			; skip head number
	inx	h

	ldax	d			; read sector number
	cmp	m
	jnz	X035c			;   not the one we're looking for

	ldax	d			; read and ignore sector size

	ldax	d			; read and ignore two bytes of CRC
	ldax	d			;   (hardware will check)

	ldax	d			; read and ignore first byte of gap 2

	in	p_drive_status >> 8	; check CRC
	ral
	jc	X0492			; CRC error

	ldax	d
	inr	m
	inr	m
	ldax	d

	lda	density
	ora	a
	jz	X04e9
	ldax	d

	lda	cmd_is_write
	ora	a
	jnz	X040b

; read sector data field
	mvi	b,12h
X03c3:	ldax	d
	dcr	b
	jnz	X03c3
	ldax	d
	lxi	h,serdes_match
	mvi	m,0
X03ce:	nop
	lda	serdes_crc
	inr	a
	jnz	X03ce
	mvi	m,70h
	ldax	d

	lda	serdes_m2fm_mark
	cpi	m2fm_data_mark		; is normal (non-deleted) data mark?
	jnz	X049a

X03e1:	lhld	iopb_buffer_addr
	mvi	h,local_buffer>>8
	ldax	d
	mov	m,a
	mvi	c,7fh

X03ea:	inr	l
	ldax	d
	mov	m,a
	dcr	c
	jnz	X03ea

	ldax	d			; read and ignore two bytes of CRC
	ldax	d			;   (hardware will check)

	ldax	d

	in	p_drive_status >> 8	; check CRC
	ral
	mvi	a,2
	rc				; return with error if bad CRC

	lhld	iopb_buffer_addr
	lxi	b,0407fh		; write 128 bytes to host
	lda	iopb_instruction
	ani	1			; is it a verify?
	cz	start_dma		;   no, so actually write host mem
	jmp	X0445


; write sector data field
X040b:	ldax	d
	mvi	c,9
X040e:	ldax	d
	dcr	c
	jnz	X040e

	stax	d
	stax	d

	mvi	a,0ffh		; write 8 bytes of 0ffh
	mvi	c,8
X0419:	stax	d
	dcr	c
	jnz	X0419

	lxi	b,serdes_m2fm_mark	; set up to write M2FM data field

X0421:	stax	d		; and write one more byte of pre-data-mark gap

	lhld	iopb_buffer_addr
	mvi	h,local_buffer>>8
	stax	d

	lda	data_mark	; write the data mark
	stax	b

	mov	a,m		; transfer first byte
	stax	d

	mvi	c,7fh		; transfer another 127 bytes
X0430:	inr	l
	mov	a,m
	stax	d
	dcr	c
	jnz	X0430

	sta	serdes_crc	; write two bytes of CRC
	lda	density
	cma
	sta	serdes_crc

	stax	d		; write first four bytes of gap 3
	stax	d
	stax	d
	stax	d


; read command rejoins us here
X0445:	lxi	h,iopb_buffer_addr+1	; increment high byte of buffer address
	inr	m

	lxi	h,iopb_rec_count	; decrement record count
	dcr	m
	jnz	X0346

	lxi	d,X4018
	ldax	d
	ora	a
	rz
	mov	m,a
	xra	a
	stax	d
	lda	X4019
	lxi	h,iopb_sector
	mov	d,m
	mov	m,a
	sub	d
	rar
	mov	d,a

	mvi	e,128			; advance IOPB buffer to next sector
	lhld	iopb_buffer_addr
	dad	d
	shld	iopb_buffer_addr

	jmp	X0346

X0470:	lda	X4017
	ora	a
	rnz
	mvi	a,0eh
	ret


addr_field_wrong_track:
	ldax	d
	ldax	d
	ldax	d
	ldax	d
	ldax	d
	ldax	d

	in	p_drive_status >> 8	; check CRC
	ral
	jc	X0492			; CRC error, so ignore read track number

	mvi	a,4
	sta	X4017
	call	op_recalibrate
	call	op_seek
	jmp	X035c


X0492:	mvi	a,0ah
	sta	X4017
	jmp	X035c

X049a:	cpi	8
	jmp	X04a1

X049f:	cpi	0f8h
X04a1:	mvi	a,0fh
	sta	X4017
	mvi	a,1
	rz
	lxi	h,iopb_sector
	dcr	m
	dcr	m
	jmp	X035c


; single-density address field search
X04b1:	mvi	m,0ffh

X04b3:	lda	index_counter
	ora	a
	jm	X0470

X04ba:	inr	b
	jz	X04b3
	lda	serdes_crc
	ora	a
	jnz	X04ba
	ldax	d
	ora	a
	jnz	X04ba
	ldax	d
	ora	a
	jnz	X04ba
X04cf:	mvi	m,0c7h

X04d1:	lda	serdes_fm_mark
	ora	a
	jz	X04d1
	cpi	fm_address_mark
	jz	address_mark_found
	mvi	m,0ffh
	lda	serdes_crc
	ora	a
	jz	X04cf
	jmp	X04b1


X04e9:	lda	cmd_is_write
	ora	a
	jnz	X050e

	ldax	d
	mvi	b,0ah
X04f3:	ldax	d
	dcr	b
	jnz	X04f3
	ldax	d
	lxi	h,serdes_match
	mvi	m,0ffh
	lda	serdes_crc
	mvi	m,0c7h

	lda	serdes_fm_mark
	cpi	fm_data_mark	; normal data mark?
	jnz	X049f
	jmp	X03e1


X050e:	ldax	d
	ldax	d
	mvi	a,0ffh
	stax	d
	stax	d
	stax	d
	xra	a
	stax	d
	stax	d
	stax	d
	stax	d

	lxi	b,serdes_fm_mark	; set up to write FM data field
	jmp	X0421		; and go do it


op_format_track:
	call	op_seek
	ora	a
	rnz

	call	X02f0
	rz
	
	lxi	b,08068h	; read 105 bytes - minor BUG, should only be 104 (26 * 4)?
	lhld	iopb_buffer_addr
	call	start_dma

	mvi	h,local_buffer>>8

	lda	iopb_channel_word
	ani	40h		; random format sequence
	jnz	X054b

	push	h		; normal format sequence
	mov	a,m
	lxi	b,03401h
X0541:	mov	m,c
	inr	l
	mov	m,a
	inr	l
	inr	c
	dcr	b
	jnz	X0541
	pop	h

X054b:	lxi	b,index_counter
	lxi	d,serdes_data
	mvi	a,1
	stax	b
	lda	density
	ora	a
	jz	X05c5

X055b:	ldax	b		; wait for index
	ora	a
	jnz	X055b

	xra	a
	mvi	c,3fh		; write 63 bytes of 00
X0563:	stax	d
	dcr	c
	jnz	X0563

	stax	d		; and one more

	mvi	b,52		; sector count (double density)

X056b:	in	p_drive_status >> 8	 ; prepare CRC generator
	mvi	a,0ffh

	mvi	c,9		; write 9 bytes of 0ffh
X0571:	stax	d
	dcr	c
	jnz	X0571

	stax	d		; and one more
	
	mvi	a,m2fm_address_mark	; write address mark and reset CRC
	sta	serdes_m2fm_mark

	lda	iopb_track	; write track
	stax	d

	xra	a		; write head
	stax	d

	mov	a,m		; write sector
	stax	d

	xra	a		; write sector size
	inr	l
	stax	d

	sta	serdes_crc	; write two bytes of CRC
	sta	serdes_crc

; write gap 2
	mvi	c,11h		; write 17 bytes of 000h
X058f:	stax	d
	dcr	c
	jnz	X058f

	stax	d		; and one more

	mvi	a,0ffh		; write 9 bytes of 0ffh
	mvi	c,9
X0599:	stax	d
	dcr	c
	jnz	X0599

	stax	d		; and one more

; write data record
	mvi	a,m2fm_data_mark	; write data mark (normal, not deleted)
	sta	serdes_m2fm_mark
	
	mov	a,m		; write 127 bytes of ???
	mvi	c,7fh
X05a7:	stax	d
	dcr	c
	jnz	X05a7

	stax	d		; and one more

	xra	a		; write two bytes of CRC
	sta	serdes_crc
	inr	l
	sta	serdes_crc
	
; write gap 3
	mvi	c,11h		; write 17 bytes of 000h
X05b7:	stax	d
	dcr	c
	jnz	X05b7
	stax	d		; and one more
	
	dcr	b
	jnz	X056b

	stax	d
	jmp	format_gap4

X05c5:	ldax	b
	ora	a
	jnz	X05c5
	mvi	a,0ffh
	mvi	c,48h
X05ce:	stax	d
	dcr	c
	jnz	X05ce
	stax	d

	mvi	b,1ah

X05d6:	xra	a		; write 7 bytes of 00h
	stax	d
	stax	d
	stax	d
	stax	d
	stax	d
	stax	d

	mvi	a,fm_address_mark	; write address mark
	sta	serdes_fm_mark

	lda	iopb_track
	stax	d

	xra	a
	stax	d

	mov	a,m
	stax	d

	xra	a
	inr	l
	stax	d

	mvi	a,0ffh		; write two bytes of CRC
	sta	serdes_crc
	sta	serdes_crc

	mvi	c,0ah		; write 10 bytes of 0ffh
X05f7:	stax	d
	dcr	c
	jnz	X05f7

	stax	d		; and one more

	xra	a		; write 6 bytes of 000h
	stax	d
	stax	d
	stax	d
	stax	d
	stax	d
	stax	d

	mvi	a,fm_data_mark	; write data mark (normal, not deleted)
	sta	serdes_fm_mark

	mov	a,m		; write 127 bytes of ???
	mvi	c,7fh
X060c:	stax	d
	dcr	c
	jnz	X060c
	
	stax	d		; and one more

	mvi	a,0ffh		; write two bytes of CRC
	sta	serdes_crc
	inr	l
	sta	serdes_crc

; write gap 3
	mvi	c,1ah		; write 26 bytes of 0ffh
X061d:	stax	d
	dcr	c
	jnz	X061d

	stax	d		; and one more

	dcr	b		; more sectors?
	jnz	X05d6		;   yes

	stax	d		; write one more 0ffh


; enter with:
;   A = byte to write in gap 4 (pre-index gap)
format_gap4:
	xchg

	lxi	d,index_counter
	mov	b,a

X062d:	mov	m,b		; write gap 4 byte

	ldax	d		; has index occurred yet?
	ora	a
	jp	X062d

	xra	a		; no error
	ret

	fillto	07ffh

	db	030h	; version number or checksum?

	end
