; vim:noet:sw=8:ts=8:ai:syn=pic
;
; USB Mass Storage Bootloader for PIC16(L)F1454/5/9
;
; Notes on function calls:
; FSR0L, FSR0H, FSR1L, and FSR1H are used to pass additional arguments
; to functions, and may be used as scratch registers inside of functions.


	radix dec
	list n=0,st=off
	include "p16f1454.inc"
	include "bdt.inc"
	include "usb.inc"
	include "log_macros.inc"
	errorlevel -302


;;; Configuration
	__config _CONFIG1, _FOSC_INTOSC & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _BOREN_ON & _IESO_OFF & _FCMEN_OFF
	__config _CONFIG2, _WRT_OFF & _CPUDIV_NOCLKDIV & _USBLSCLK_48MHz & _PLLMULT_3x & _PLLEN_ENABLED & _STVREN_ON & _BORV_LO & _LVP_OFF



;;; Constants
FOSC			equ	48000000
BAUD			equ	38400
BAUDVAL			equ	(FOSC/(16*BAUD))-1	; BRG16=0, BRGH=1

NUM_CONFIGS		equ	1
NUM_INTERFACES		equ	1
NUM_ENDPOINTS		equ	0	; other than endpoint 0
CONFIG_DESC_TOTAL_LEN	equ	CONFIG_DESC_LEN+(NUM_INTERFACES*INTF_DESC_LEN)+(NUM_ENDPOINTS*ENDPT_DESC_LEN)

EP0_BUF_SIZE 		equ	8	; endpoint 0 buffer size
RESERVED_RAM_SIZE	equ	5	; amount of RAM reserved by the bootloader
EP0OUT_BUF		equ	BUF_START+RESERVED_RAM_SIZE
EP0IN_BUF		equ	EP0OUT_BUF+EP0_BUF_SIZE
BANKED_EP0OUT_BUF	equ	BANKED_BUF_START+RESERVED_RAM_SIZE
BANKED_EP0IN_BUF	equ	BANKED_EP0OUT_BUF+EP0_BUF_SIZE	; EP0IN buffer spills over to bank 1... deal with it



;;; Variables
RESERVED_RAM		equ	BANKED_BUF_START
USB_STATE		equ	RESERVED_RAM+0
EP0_DATA_IN_PTRL	equ	RESERVED_RAM+1	; pointer to block of data to be sent
EP0_DATA_IN_PTRH	equ	RESERVED_RAM+2	;   in the current EP0 IN transaction
EP0_DATA_IN_COUNT	equ	RESERVED_RAM+3	; remaining bytes to be sent
GET_CONFIG_BUF		equ	RESERVED_RAM+4	; response buffer for Get Configuration

LINEAR_GET_CONFIG_BUF	equ	0x2000+(GET_CONFIG_BUF-0x20)

; USB_STATE bit flags
IS_CONTROL_WRITE	equ	0	; current endpoint 0 transaction is a control write
EP0_HANDLED		equ	1	; last endpoint 0 transaction was handled; will stall if 0
ADDRESS_PENDING		equ	2	; need to set address in next IN transaction
EP0_IN_ALL_SENT		equ	3	; all data packets for EP0 IN transaction have been sent
DEVICE_CONFIGURED	equ	4	; the device is configured

;;; Macros
	nolist
;;; Loads the address of the given symbol into FSR0.
ldfsr0	macro 	x
	movlw	low x
	movwf	FSR0L
	movlw	high x
	movwf	FSR0H
	endm

;;; Loads the given address in data space into FSR0.
;;; (This ensures that the high bit is not set, which the high directive may
;;; do implicitly)
ldfsr0d	macro	x
	movlw	low x
	movwf	FSR0L
	movlw	(high x) & 0x7F
	movwf	FSR0H
	endm

;;; Loads the address of the given symbol into FSR1.
ldfsr1	macro 	x
	movlw	low x
	movwf	FSR1L
	movlw	high x
	movwf	FSR1H
	endm

;;; Loads the given address in data space into FSR1.
;;; (This ensures that the high bit is not set, which the high directive may
;;; do implicitly)
ldfsr1d	macro	x
	movlw	low x
	movwf	FSR1L
	movlw	(high x) & 0x7F
	movwf	FSR1H
	endm

;;; Loads the address of the given symbol into PMADRH:PMADRL.
ldpmadr	macro	x
	banksel	PMADRL
	movlw	low x
	movwf	PMADRL
	movlw	high x
	movwf	PMADRH
	endm

;;; Waits until the bit in the specified register is set.
waitfs	macro 	reg,bit
	btfss	reg,bit
	goto	$-1
	endm

;;; Waits until the bit in the specified register is cleared.
waitfc	macro 	reg,bit
	btfsc	reg,bit
	goto	$-1
	endm

;;; Returns if the Z flag is set.
retz	macro
	skpnz
	return
	endm

;;; Returns if the Z flag is not set.
retnz	macro
	skpz
	return
	endm

;;; Subtracts the literal from W. (opposite of 'sublw')
subwl	macro	x
	addlw	256-x
	endm

;;; Increments W.
incw	macro
	addlw	1
	endm

;;; Decrements W.
decw	macro
	addlw	255
	endm


	
;;; Vectors
	list
	org	0x0000
RESET_VECT
	goto	bootloader_start
	org	0x0004
INTERRUPT_VECT
	call	usb_service
	retfie



;;; Main function
	org	0x0006
bootloader_start
; Configure the oscillator (48MHz from INTOSC using 3x PLL)
	banksel	OSCCON
	movlw	(1<<SPLLEN)|(1<<SPLLMULT)|(1<<IRCF3)|(1<<IRCF2)|(1<<IRCF1)|(1<<IRCF0)
	movwf	OSCCON

; Wait for the oscillator and PLL to stabilize
_wait_osc_ready
	movlw	(1<<PLLRDY)|(1<<HFIOFR)|(1<<HFIOFS)
	andwf	OSCSTAT,w
	sublw	(1<<PLLRDY)|(1<<HFIOFR)|(1<<HFIOFS)
	bnz	_wait_osc_ready

; Enable active clock tuning
	banksel	ACTCON
	movlw	(1<<ACTSRC)|(1<<ACTEN)
	movwf	ACTCON		; source = USB

; Turn on the LED
	banksel TRISA
	bcf	TRISA,TRISA4	; RA4 as output
	bcf	TRISA,TRISA5	; RA5 as output
	banksel	LATA
	bsf	LATA,LATA4	; set RA4 high
	bcf	LATA,LATA5

; Enable the UART
	banksel	SPBRGL
	movlw	low BAUDVAL	; set baud rate divisor
	movwf	SPBRGL
	bsf	TXSTA,BRGH	; high speed
	bsf	RCSTA,SPEN	; enable serial port
	bsf	TXSTA,TXEN	; enable transmission

; Print a power-on character
	call	log_init
	logch	'^',LOG_NEWLINE

; Initialize USB
	;call	usb_init
	;call	usb_attach
	;bsf	INTCON,GIE	; enable interrupts

; Main loop
loop	
; Blink the LED
	banksel	LATA
	movlw	(1<<LATA4)
	xorwf	LATA,f
; Print any pending characters in the log
	call	log_service
	goto	loop



;;; Initializes the USB system and resets all associated registers.
;;; arguments:	none
;;; returns:	none
;;; clobbers:	W, BSR, FSR0, FSR1H
usb_init
	logch	'R',LOG_NEWLINE
; clear our state
	banksel	USB_STATE
	clrf	USB_STATE
	clrf	EP0_DATA_IN_PTRL
	clrf	EP0_DATA_IN_PTRH
	clrf	EP0_DATA_IN_COUNT
; disable USB interrupts
	banksel	PIE2
	bcf	PIE2,USBIE
; clear USB registers
	banksel	UEIR
	clrf	UEIR
	clrf	UIR
; disable all endpoints
	clrf	UEP0
	clrf	UEP1
	clrf	UEP2
	clrf	UEP3
	clrf	UEP4
	clrf	UEP5
	clrf	UEP6
	clrf	UEP7
; set configuration
	movlw	(1<<UPUEN)|(1<<FSEN)
	movwf	UCFG		; enable pullups, full speed, no ping-pong buffering
	movlw	(1<<BTSEE)|(1<<BTOEE)|(1<<DFN8EE)|(1<<CRC16EE)|(1<<CRC5EE)|(1<<PIDEE)
	movwf	UEIE		; enable all error interrupts
	movlw	(1<<IDLEIE)|(1<<TRNIE)|(1<<UERRIE)|(1<<URSTIE)
	movwf	UIE		; all interrupts except stall, SOF, and Bus Activity Detect
; clear all BDT entries
	ldfsr0d	BDT_START
	movlw	BDT_LEN
	movwf	FSR1H		; loop count
	movlw	0
_bdtclr	movwi	FSR0++
	decfsz	FSR1H,f
	goto	_bdtclr
; reset ping-pong buffers and address
	bsf	UCON,PPBRST
	clrf	UADDR
	bcf	UCON,PKTDIS	; enable packet processing
	bcf	UCON,PPBRST	; clear ping-pong buffer reset flag
; flush pending transactions
_tflush	btfss	UIR,TRNIF
	goto	_initep
	bcf	UIR,TRNIF
	call	_ret		; need at least 6 cycles before checking TRNIF again
	goto	_tflush
; initialize endpoint 0
_initep	movlw	(1<<EPHSHK)|(1<<EPOUTEN)|(1<<EPINEN)
	movwf	UEP0
	banksel	BANKED_EP0OUT
	movlw	EP0_BUF_SIZE	; set CNT
	movwf	BANKED_EP0OUT_CNT
	movlw	low EP0OUT_BUF	; set ADRL
	movwf	BANKED_EP0OUT_ADRL
	movlw	EP0OUT_BUF>>8	; set ADRH
	movwf	BANKED_EP0OUT_ADRH
	movlw	_DAT0|_BSTALL	; set STAT; arm EP0 OUT to receive a SETUP packet
	movwf	BANKED_EP0OUT_STAT
	bsf	BANKED_EP0OUT_STAT,UOWN	; give ownership to SIE
	movlw	low EP0IN_BUF	; set IN endpoint ADRL
	movwf	BANKED_EP0IN_ADRL
	movlw	EP0IN_BUF>>8	; set IN endpoint ADRH
	movwf	BANKED_EP0IN_ADRH
_ret	return	



;;; Enables the USB module.
;;; Assumes all registers have been properly configured by calling usb_init.
;;; arguments:	none
;;; returns:	none
;;; clobbers:	W, BSR, FSR0
usb_attach
	logch	'A',0
	banksel	UCON		; reset UCON
	clrf	UCON
	banksel	PIE2
	bsf	PIE2,USBIE	; enable USB interrupts
	bsf	INTCON,PEIE
	banksel	UCON
_usben	bsf	UCON,USBEN	; enable USB module and wait until ready
	btfss	UCON,USBEN
	goto	_usben
	logch	'!',LOG_NEWLINE



;;; Services the USB bus.
;;; Should be called from the interrupt handler, or at least every 1ms.
;;; arguments:	none
;;; returns:	none
;;; clobbers:	W, BSR, FSR0, FSR1H
usb_service
	banksel	UIR
; reset?
	btfss	UIR,URSTIF
	goto	_uidle
	call	usb_init
	banksel	PIE2
	bsf	PIE2,USBIE	; reenable USB interrupts
	banksel	UIR
	bcf	UIR,URSTIF	; clear the flag
; idle? just clear the flag (TODO)
_uidle	btfsc	UIR,IDLEIF
	bcf	UIR,IDLEIF
; error?
	btfss	UIR,UERRIF
	goto	_utrans
	mlog
	mlogch	'E',0
	mloghex	1,LOG_NEWLINE
	mlogf	UEIR
	mlogend
	banksel	UEIR
	clrf	UEIR		; clear error flags
; service transactions
_utrans	banksel	UIR
	btfss	UIR,TRNIF
	goto	_usdone
	movfw	USTAT		; stash the status in a temp register
	movwf	FSR1H
	bcf	UIR,TRNIF	; clear flag and advance USTAT fifo
	andlw	b'01111000'	; check endpoint number
	bnz	_utrans		; if not endpoint 0, loop (TODO)
	movfw	FSR1H		; bring original USTAT value back to W
	call	usb_service_ep0	; handle the control message
	goto	_utrans
; clear USB interrupt
_usdone	banksel	PIR2
	bcf	PIR2,USBIF
	return



;;; Handles a control transfer on endpoint 0.
;;; arguments:	USTAT value in W
;;; returns:	none
;;; clobbers:	W, BSR, FSR0
usb_service_ep0
	banksel	BANKED_EP0OUT_STAT
	btfsc	WREG,DIR	; is it an IN transfer or an OUT/SETUP?
	goto	_usb_ctrl_in
; it's an OUT or SETUP transfer
	movfw	BANKED_EP0OUT_STAT
	andlw	b'00111100'	; isolate PID bits
	sublw	PID_SETUP	; is it a SETUP packet?
	bnz	_usb_ctrl_out	; if not, it's a regular OUT
	; it's a SETUP packet--fall through



;;; Handles a SETUP control transfer on endpoint 0.
;;; arguments:	BSR=0
;;; returns:	none
;;; clobbers:
_usb_ctrl_setup
; ensure the OUT endpoint isn't armed
	bcf	BANKED_EP0OUT_STAT,UOWN	; take ownership of EP0 OUT buffer
	bcf	USB_STATE,EP0_IN_ALL_SENT
	bcf	USB_STATE,IS_CONTROL_WRITE
; get bmRequestType
	movfw	BANKED_EP0OUT_BUF+bmRequestType
	btfss	BANKED_EP0OUT_BUF+bmRequestType,7	; is this host->device?
	bsf	USB_STATE,IS_CONTROL_WRITE		; if so, this is a control write
	movlw	_REQ_TYPE
	andwf	BANKED_EP0OUT_BUF+bmRequestType,w
	bnz	_unhreq			; ignore non-standard requests
; print packet
	mlog
	mlogch	'P',0
	mloghex	8,LOG_NEWLINE|LOG_SPACE
	mlogf	BANKED_EP0OUT_BUF+0
	mlogf	BANKED_EP0OUT_BUF+1
	mlogf	BANKED_EP0OUT_BUF+2
	mlogf	BANKED_EP0OUT_BUF+3
	mlogf	BANKED_EP0OUT_BUF+4
	mlogf	BANKED_EP0OUT_BUF+5
	mlogf	BANKED_EP0OUT_BUF+6
	mlogf	BANKED_EP0OUT_BUF+7
	mlogend
;	movfw	BANKED_EP0OUT_BUF+0
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+1
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+2
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+3
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+4
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+5
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+6
;	call	uart_print_hex
;	banksel	BANKED_EP0OUT_BUF
;	movfw	BANKED_EP0OUT_BUF+7
;	call	uart_print_hex
;	call	uart_print_nl
	banksel	BANKED_EP0OUT_BUF
; check request number: is it Get Descriptor?
	movlw	GET_DESCRIPTOR
	subwf	BANKED_EP0OUT_BUF+bRequest,w
	bz	_usb_get_descriptor
; is it Set Address?
	movlw	SET_ADDRESS
	subwf	BANKED_EP0OUT_BUF+bRequest,w
	bz	_usb_set_address
; is it Set_Configuration?
	movlw	SET_CONFIG
	subwf	BANKED_EP0OUT_BUF+bRequest,w
	bz	_usb_set_configuration
; is it Get Configuration?
	movlw	GET_CONFIG
	subwf	BANKED_EP0OUT_BUF+bRequest,w
	bz	_usb_get_configuration
; unhandled request
_unhreq	mlog
	mlogch	'?',0
	mlogch	'R',0
	mloghex	1,LOG_NEWLINE
	mlogf	BANKED_EP0OUT_BUF+bRequest
	mlogend

; Finishes a SETUP transaction.
_usb_ctrl_complete
	banksel	UCON
	bcf	UCON,PKTDIS	; reenable packet processing
; if the request wasn't handled, stall
	banksel	USB_STATE
	btfsc	USB_STATE,EP0_HANDLED
	goto	_cvalid
	logch	'X',LOG_NEWLINE
	banksel	BANKED_EP0IN
	movlw	_DAT0|_DTSEN|_BSTALL
	movwf	BANKED_EP0IN_STAT	; stall the EP0 IN endpoint
	bsf	BANKED_EP0IN_STAT,UOWN	; and arm it
	movlw	EP0_BUF_SIZE
	movwf	BANKED_EP0OUT_CNT
	movlw	_DAT0|_DTSEN|_BSTALL
	movwf	BANKED_EP0OUT_STAT	; stall the OUT endpoint
	bsf	BANKED_EP0OUT_STAT,UOWN	; and arm it
	return

_cvalid	banksel	USB_STATE
	bcf	USB_STATE,EP0_HANDLED	; clear for next transaction
	btfsc	USB_STATE,IS_CONTROL_WRITE
	goto	_cwrite
; this is a control read; prepare the IN endpoint for the data stage
; and the OUT endpoint for the status stage
_cread	call	ep0_read_in		; read data into IN buffer
	movlw	_DAT1|_DTSEN		; arm IN buffer
	movwf	BANKED_EP0IN_STAT
	bsf	BANKED_EP0IN_STAT,UOWN
	movlw	EP0_BUF_SIZE
	movwf	BANKED_EP0OUT_CNT
	movlw	_DAT1|_DTSEN
	movwf	BANKED_EP0OUT_STAT	; arm OUT buffer for status stage
	bsf	BANKED_EP0OUT_STAT,UOWN
	return

; this is a control write: prepare the IN endpoint for the status stage
; and the OUT endpoint for the next SETUP transaction
_cwrite	clrf	BANKED_EP0IN_CNT	; we'll be sending a zero-length packet
	movlw	_DAT1|_DTSEN
	movwf	BANKED_EP0IN_STAT	; arm IN buffer for status stage
	bsf	BANKED_EP0IN_STAT,UOWN
	movlw	EP0_BUF_SIZE
	movwf	BANKED_EP0OUT_CNT
	movlw	_DAT0|_DTSEN|_BSTALL
	movwf	BANKED_EP0OUT_STAT
	bsf	BANKED_EP0OUT_STAT,UOWN
	return

; Handles a Get Descriptor request.
; BSR=0
_usb_get_descriptor
	bsf	USB_STATE,EP0_HANDLED	; assume it'll be a valid request
; check descriptor type
	movlw	DESC_DEVICE
	subwf	BANKED_EP0OUT_BUF+wValueH,w
	bz	_device_descriptor
	movlw	DESC_CONFIG
	subwf	BANKED_EP0OUT_BUF+wValueH,w
	bz	_config_descriptor
; unsupported descriptor
	bcf	USB_STATE,EP0_HANDLED
	mlog
	mlogch	'?',0
	mlogch	'D',0
	mloghex	1,LOG_NEWLINE
	mlogf	BANKED_EP0OUT_BUF+wValueH
	mlogend
	banksel	BANKED_EP0OUT_BUF
	goto	_usb_ctrl_complete
_device_descriptor
	movlw	low DEVICE_DESCRIPTOR
	movwf	EP0_DATA_IN_PTRL
	movlw	high DEVICE_DESCRIPTOR
	movwf	EP0_DATA_IN_PTRH
	movlw	DEVICE_DESC_LEN
	movwf	EP0_DATA_IN_COUNT
	goto	_adjust_data_in_count
_config_descriptor
	movlw	low CONFIGURATION_DESCRIPTOR
	movwf	EP0_DATA_IN_PTRL
	movlw	high CONFIGURATION_DESCRIPTOR
	movwf	EP0_DATA_IN_PTRH
	movlw	CONFIG_DESC_TOTAL_LEN	; length includes all subordinate descriptors
	movwf	EP0_DATA_IN_COUNT
; the count needs to be set to the minimum of the descriptor's length (in W)
; and the requested length
_adjust_data_in_count
	subwf	BANKED_EP0OUT_BUF+wLengthL,w	; just ignore high byte...
	bc	_usb_ctrl_complete		; if W <= f, no need to adjust
	movfw	BANKED_EP0OUT_BUF+wLengthL
	movwf	EP0_DATA_IN_COUNT
	goto	_usb_ctrl_complete

; Handles a Set Address request.
; The address is actually set in the IN status stage.
_usb_set_address
	bsf	USB_STATE,ADDRESS_PENDING	; address will be assigned in the status stage
	bsf	USB_STATE,EP0_HANDLED
	goto	_usb_ctrl_complete

; Handles a Set Configuration request.
; For now just accept any nonzero configuration.
; BSR=0
_usb_set_configuration
	bcf	USB_STATE,DEVICE_CONFIGURED	; temporarily clear flag
	tstf	BANKED_EP0OUT_BUF+wValueL	; anything other than 0 is valid
	skpz
	bsf	USB_STATE,DEVICE_CONFIGURED
	bsf	USB_STATE,EP0_HANDLED
	goto	_usb_ctrl_complete

; Handles a Get Configuration request.
; BSR=0
_usb_get_configuration
; Put either 0 or 1 into GET_CONFIG_BUF
	clrw
	btfsc	USB_STATE,DEVICE_CONFIGURED
	incf	GET_CONFIG_BUF,f
; Seems like overkill for a 1-byte transfer, but it keeps things consistent
	movlw	low LINEAR_GET_CONFIG_BUF
	movwf	EP0_DATA_IN_PTRL
	movlw	high LINEAR_GET_CONFIG_BUF
	movwf	EP0_DATA_IN_PTRH
	movlw	1
	movwf	EP0_DATA_IN_COUNT
	bsf	USB_STATE,EP0_HANDLED
	goto	_usb_ctrl_complete

; Handles an OUT control transfer on endpoint 0.
; BSR=0
_usb_ctrl_out
; Only time this will get called is in the status stage of a control read,
; since we don't support any control writes with a data stage.
; All we have to do is re-arm the OUT endpoint.
	movlw	EP0_BUF_SIZE
	movwf	BANKED_EP0OUT_CNT
	movlw	_DAT0|_DTSEN|_BSTALL
	movwf	BANKED_EP0OUT_STAT
	bsf	BANKED_EP0OUT_STAT,UOWN
	return



; Handles an IN control transfer on endpoint 0.
; BSR=0
_usb_ctrl_in
	btfsc	USB_STATE,IS_CONTROL_WRITE	; is this a control read or write?
	goto	_check_for_pending_address
; fetch more data and re-arm the IN endpoint
	call	ep0_read_in
	movlw	_DTSEN
	btfss	BANKED_EP0IN_STAT,DTS	; toggle DTS
	bsf	WREG,DTS
	movwf	BANKED_EP0IN_STAT
	bsf	BANKED_EP0IN_STAT,UOWN	; arm IN buffer
	return
; if this is the status stage of a Set Address request, assign the address here.
; The OUT buffer has already been armed for the next SETUP.
_check_for_pending_address
	btfss	USB_STATE,ADDRESS_PENDING
	return
; read the address out of the setup packed in the OUT buffer
	bcf	USB_STATE,ADDRESS_PENDING
	movfw	BANKED_EP0OUT_BUF+wValueL
	banksel	UADDR
	movwf	UADDR
	mlog
	mlogch	'A',0
	mloghex	1,LOG_NEWLINE
	mlogf	UADDR
	mlogend
	return



;;; Reads data from EP0_DATA_IN_PTRL:EP0_DATA_IN_PTRH, copies it to the EP0 IN buffer,
;;; and decrements EP0_DATA_IN_COUNT.
;;; arguments:	BSR=0
;;; returns:	EP0_DATA_IN_PTRL:EP0_DATA_IN_PTRH advanced
;;;		EP0_DATA_IN_COUNT decremented
;;; clobbers:	W, FSR0, FSR1
ep0_read_in
	clrf	BANKED_EP0IN_CNT	; initialize buffer size to 0
	tstf	EP0_DATA_IN_COUNT	; do nothing if there are 0 bytes to send
	retz
	movfw	EP0_DATA_IN_PTRL	; set up source pointer
	movwf	FSR0L
	movfw	EP0_DATA_IN_PTRH
	movwf	FSR0H
	ldfsr1d	EP0IN_BUF		; set up destination pointer
	clrw
; byte copy loop
_bcopy	sublw	EP0_BUF_SIZE		; have we filled the buffer?
	bz	_bcdone
	moviw	FSR0++
	movwi	FSR1++
	incf	BANKED_EP0IN_CNT,f	; increase number of bytes copied
	movfw	BANKED_EP0IN_CNT	; save to test on the next iteration
	decfsz	EP0_DATA_IN_COUNT,f	; decrement number of bytes remaining
	goto	_bcopy
; write back the updated source pointer
_bcdone	movfw	FSR0L
	movwf	EP0_DATA_IN_PTRL
	movfw	FSR0H
	movwf	EP0_DATA_IN_PTRH
	return


;;;;;;; Low-latency logging

; Linear address of the 256-byte buffer
; Aligned to a 256-byte boundary
LOG_BUFFER	equ	0x2300

; Banked RAM locations used by logging system
; (directly before the log buffer)
LOG_WREG_SAVE	equ	0x539		; bank 0x0A
LOG_FSR0L_SAVE	equ	0x53a
LOG_FSR0H_SAVE	equ	0x53b
LOG_HEAD	equ	0x53c
LOG_TAIL	equ	0x53d
LOG_FMT_FLAGS	equ	0x53e		; hex count/newline/space flags
LOG_CURR_BYTE	equ	0x53f

log_init
	banksel	LOG_HEAD
	clrf	LOG_HEAD
	clrf	LOG_TAIL
	clrf	LOG_FMT_FLAGS
	return

log_service
	banksel	LOG_HEAD
_lsloop	movfw	LOG_TAIL	; if head == tail, buffer is empty
	subwf	LOG_HEAD,w
	skpnz
	return
;	banksel	LATA
;	movlw	(1<<LATA5)
;	xorwf	LATA,f
;	banksel	LOG_HEAD
; dequeue a byte
	movlw	LOG_BUFFER>>8
	movwf	FSR0H
	movfw	LOG_HEAD
	movwf	FSR0L
	moviw	FSR0++
	movwf	LOG_CURR_BYTE
; save advanced head pointer
	movfw	FSR0L
	movwf	LOG_HEAD
; are we in hex mode?
	btfsc	LOG_FMT_FLAGS,7
	goto	_lsphex
; process the byte
	btfsc	LOG_CURR_BYTE,7	; is this a hex marker?
	goto	_lsshex
; we're just in ASCII mode
	movfw	LOG_CURR_BYTE
	andlw	b'00111111'	; mask off high bits
	addlw	32		; upper bits need to be set properly
	call	_uart_print_ch
	btfsc	LOG_CURR_BYTE,6	; need to print a trailing newline?
	call	_uart_print_nl
	goto	_lsloop
_lsshex	movfw	LOG_CURR_BYTE	; starting hex mode? write flags and loop
	movwf	LOG_FMT_FLAGS
	goto	_lsloop	
_lsphex	btfsc	LOG_FMT_FLAGS,5	; need to print a leading space?
	call	_uart_print_space
	call	_uart_print_hex	; prints byte in LOG_CURR_BYTE
	movfw	LOG_FMT_FLAGS	; decrement hex byte count
	andlw	b'00011111'	; isolate count bits
	decfsz	WREG,w		; subtract 1
	goto	_nxthex
; hex counter reached 0; print newline if needed and clear format flags
	btfsc	LOG_FMT_FLAGS,6	; need to print a trailing newline?
	call	_uart_print_nl
	clrf	LOG_FMT_FLAGS
	goto	_lsloop
; hex counter > 0; write back new count
_nxthex	xorwf	LOG_FMT_FLAGS,w	; xor-swap new count and old flags
	xorwf	LOG_FMT_FLAGS,f
	xorwf	LOG_FMT_FLAGS,w	; LOG_FMT_FLAGS contains new count, but NOT old flags
	andlw	b'11100000'	; isolate old flags
	iorwf	LOG_FMT_FLAGS,f	; write them back to LOG_FMT_FLAGS
	goto	_lsloop



log_single_byte
	banksel	LOG_WREG_SAVE	; need to save W and FSR0
	movwf	LOG_WREG_SAVE
	movfw	FSR0L
	movwf	LOG_FSR0L_SAVE
	movfw	FSR0H
	movwf	LOG_FSR0H_SAVE
	call	_log_byte_inner	; and fall through
log_multi_byte_end
	banksel	LOG_FSR0L_SAVE	; (redundant when falling through)
; restore registers
	movfw	LOG_FSR0L_SAVE
	movwf	FSR0L
	movfw	LOG_FSR0H_SAVE
	movwf	FSR0H
	movfw	LOG_WREG_SAVE
	return

log_multi_byte_start
; save FSR0
	banksel	LOG_WREG_SAVE
	movfw	FSR0L
	movwf	LOG_FSR0L_SAVE
	movfw	FSR0H
	movwf	LOG_FSR0H_SAVE
	return

log_byte
	banksel	LOG_WREG_SAVE
	movwf	LOG_WREG_SAVE	;and fall through
; load tail pointer into FSR0
_log_byte_inner
	movlw	LOG_BUFFER>>8
	movwf	FSR0H
	movfw	LOG_TAIL
	movwf	FSR0L
	movfw	LOG_WREG_SAVE	; write byte into log buffer
	movwi	FSR0++		; advance tail pointer
; save new tail pointer
	movfw	FSR0L		; high byte is ignored for 256-byte wraparound
	movwf	LOG_TAIL
; always keep one slot open; if (tail+1)%256 == head, advance head
	subwf	LOG_HEAD,w
	skpnz
	incf	LOG_HEAD,f
	return


_uart_print_space
	movlw	' '
	goto	_uart_print_ch
_uart_print_nl
	movlw	'\n'
; prints char in W
_uart_print_ch
	banksel	TXREG
	movwf	TXREG		; transmit the character
	banksel	PIR1		; need 1 cycle delay before checking TXIF
	waitfs	PIR1,TXIF	; loop until character is sent
	banksel	LOG_FMT_FLAGS	; preserve BSR
	return



;;; Converts the lower nibble of W to its ASCII hexadecimal representation.
_w2hd	macro			; 'w to hex digit'
	andlw	b'00001111'
	subwl	10		; is W >= 10?
	skpnc
	addlw	7		; if so, shift to letters
	addlw	'A'-7		; shift to printable ASCII
	endm
_uart_print_hex
	movfw	LOG_CURR_BYTE
	swapf	WREG,w		; get high nibble
	_w2hd
	call	_uart_print_ch	; print high nibble
	movfw	LOG_CURR_BYTE	; bring back original byte
	_w2hd
	goto	_uart_print_ch	; print low nibble



	if 0
;;; Transmits a newline over the UART.
;;; arguments:	none
;;; returns:	none
;;; clobbers:	W, BSR
uart_print_nl
	movlw	'\n'		; fall through to uart_print_char



;;; Transmits a character over the UART and returns when complete.
;;; arguments:	character in W
;;; returns:	none
;;; clobbers:	BSR
uart_print_char
	banksel	TXREG
	movwf	TXREG		; transmit the character
	banksel	PIR1		; need 1 cycle delay before checking TXIF
	waitfs	PIR1,TXIF	; loop until character is sent
	return



;;; Transmits a null-terminated string over the UART.
;;; arguments:	pointer to string in FSR0
;;; returns:	none
;;; clobbers:	FSR0, W, BSR
uart_print_str
	moviw	FSR0++		; get a character and advance
	retz			; return if zero
	call	uart_print_char
	goto	uart_print_str	; next character



;;; Transmits a null-terminated packed (2 characters per word) ASCII string.
;;; from program memory over the UART.
;;; arguments:	pointer to string in PMADRH:PMADRL
;;		BSR=3
;;; returns:	none
;;; clobbers:	W, BSR, PMADRH:PMADRL
uart_print_packed_str
	bcf	PMCON1,CFGS	; don't read from configuration space
_l1	bsf	PMCON1,RD	; initiate read
	nop
	nop
	lslf	PMDATL,f	; shift lsb of high byte into PMDATH
	rlf	PMDATH,w
	tstf	WREG		; needed because rlf doesn't affect the Z flag
	retz			; return if high byte is 0
	call	uart_print_char	; print high byte
	banksel	PMDATL
	lsrf	PMDATL,w	; readjust PMDATL (this *does* affect the Z flag)
	retz			; return if low byte is 0
	call	uart_print_char	; print low byte
	banksel	PMADRL		; advance to next word
	incf	PMADRL,f
	skpnc
	incf	PMADRH,f
	goto	_l1
	endif






;;; Descriptors
DEVICE_DESCRIPTOR
	dt	DEVICE_DESC_LEN	; bLength
	dt	0x01		; bDescriptorType
	dt	0x00, 0x02	; bcdUSB USB 2.0
	dt	0x00		; bDeviceClass
	dt	0x00		; bDeviceSubclass
	dt	0x00		; bDeviceProtocol
	dt	0x08		; bMaxPacketSize0 (8 bytes)
	dt	0xd8, 0x04	; idVendor (Microchip)
	dt	0xdd, 0xdd	; idProduct (fake value)
	dt	0x01, 0x00	; bcdDevice (1)
	dt	0x00		; iManufacturer (TODO)
	dt	0x00		; iProduct (TODO)
	dt	0x00		; iSerialNumber (TODO)
	dt	0x01		; bNumConfigurations

CONFIGURATION_DESCRIPTOR
	dt	CONFIG_DESC_LEN	; bLength
	dt	0x02		; bDescriptorType
	dt	low CONFIG_DESC_TOTAL_LEN	; wTotalLengthL
	dt	high CONFIG_DESC_TOTAL_LEN	; wTotalLengthH
	dt	0x01		; bNumInterfaces
	dt	0x01		; bConfigurationValue
	dt	0x00		; iConfiguration
	dt	b'11000000'	; bmAttributes (self-powered)
	dt	0x19		; bMaxPower (25 -> 50 mA)

INTERFACE_DESCRIPTOR
	dt	INTF_DESC_LEN	; bLength
	dt	0x04		; bDescriptorType
	dt	0x00		; bInterfaceNumber
	dt	0x00		; bAlternateSetting
	dt	0x00		; bNumEndpoints (TODO)
	dt	0xFF		; bInterfaceClass (TODO)
	dt	0x00		; bInterfaceSubclass
	dt	0x00		; bInterfaceProtocol
	dt	0x00		; iInterface

	end	
