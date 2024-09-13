	PAGE	59,132
	TITLE	MT32MSG

;----------------------------------------------------------------------------;
; MT-32 Screen Display
;
; Write text from DOS command line to MT-32 using an MPU-401 compatible MIDI
; interface at I/O port 330h.
;
; Usage:
;	MT32MSG String To Write
;
; If no command line string, the MT-32 screen is reset to normal display.
;
; Copyright (c) 2023-2024, 640KB under GPLv3.
;----------------------------------------------------------------------------;
; This program is free software: you can redistribute it and/or modify it
; under the terms of the GNU General Public License as published by the Free
; Software Foundation, either version 3 of the License, or (at your option)
; any later version.
;
; This program is distributed in the hope that it will be useful, but WITHOUT
; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
; FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
; more details.
;
; You should have received a copy of the GNU General Public License along
; with this program. If not, see <https://www.gnu.org/licenses/>.
;----------------------------------------------------------------------------;
; Build using MASM 5.x or 6.x:
;	MASM MT32MSG;
;	LINK MT32MSG;
;	EXE2BIN MT32MSG.EXE MT32MSG.COM
;----------------------------------------------------------------------------;

;----------------------------------------------------------------------------;
; Configuration
;
MPU_BASE_PORT	EQU	330H		; MPU I/O port - 330h or 300h
SYSEX_DELAY		EQU	18		; delay between bytes in ms (0 to disable)
ASCII_FILTER	EQU	1		; allow only ASCII 32-127

;----------------------------------------------------------------------------;
; MIDI SYSEX
;
SYSEX_BEGIN		EQU	0F0H		; MIDI sysex start marker
SYSEX_END		EQU	0F7H		; MIDI sysex end marker

;----------------------------------------------------------------------------;
; Roland SYSEX Addresses (commands)
;
CMD_RQ1		EQU	11H		; Request Data command (request FROM device)
CMD_DT1		EQU	12H		; Data Set command (sent TO device)
CMD_DISP		EQU	20H 		; Write to display
CMD_MODE_UART	EQU	3FH		; Set mode UART
CMD_WSD		EQU	40H		; Want to send data
CMD_RQD		EQU	41H		; Request Data
CMD_ACK		EQU	0FEH		; MPU acknowledge
CMD_RESET		EQU	0FFH		; MPU Reset

;----------------------------------------------------------------------------;
; Display command options
;
DISP_OUT		EQU	0000H		; Write data to display
DISP_CLR		EQU	0001H		; Clear display

;----------------------------------------------------------------------------;
; Roland Model options
;
MFG_ROLAND		EQU	41H		; Roland Manufacturer's ID
MODEL_MT32		EQU	16H		; MT-32 Model ID
MODEL_D50		EQU	14H		; D-50 Model ID
MODEL_SC		EQU	42H		; SC-xx Model ID
DEVICE_ID		EQU	17		; Unit number default is 17 (one-based)

;----------------------------------------------------------------------------;
; MPU Status register
;----------------------------------------------------------------------------;
; 84218421
; 7	    |	DSR:	Data Set Ready (active low)
;			1. The HOST can read this signal on bit 7 of STATPORT or 
;				DSR line. The MPU-401 wants to send a byte to the
;				HOST when DSR is low.
;			2. Line for DSR signal
;  6	    | DRR:	Data Receive Ready (active low)
;			The HOST can read this signal on bit 6 of STATPORT. When
;			the DRR is low the HOST can send a command or a data byte.
;   543210|	MPUX:	Unused
;----------------------------------------------------------------------------;
MPU_SR	RECORD	DSR:1, DRR:1, MPUX:6

;----------------------------------------------------------------------------;
; MAX val: REG, VAL
;----------------------------------------------------------------------------;
MAX		MACRO	REG, VAL
		LOCAL	EXIT
	CMP	REG, VAL			; max value is VAL
	JBE	EXIT				; jump if <= VAL
	MOV	REG, VAL			; if longer, use VAL
EXIT:
		ENDM

;----------------------------------------------------------------------------;
; Filter ASCII chars to allow only 32-127
;----------------------------------------------------------------------------;
ASC_FILTER	MACRO	REG
		LOCAL	EXIT
	CMP	REG, ' '			; is ASCII >= 32 and ASCII <= 127?
	JG	EXIT				; valid if so
	MOV	REG, ' '			; if not, replace with space
EXIT:
		ENDM

_TEXT		SEGMENT
		ASSUME	CS:_TEXT, DS:_TEXT, ES:_TEXT, SS:_TEXT

;----------------------------------------------------------------------------;
; DOS PSP
;----------------------------------------------------------------------------;
		ORG	80H
PSP_CMD_LEN	DB	?			; DOS PSP command line tail length

;----------------------------------------------------------------------------;
; Begin DOS program
;----------------------------------------------------------------------------;
		ORG	100H
START:
MT32		PROC	NEAR
	MOV	DX, MPU_BASE_PORT		; set MPU base port (330h or 300h)
	MOV	SI, OFFSET PSP_CMD_LEN	; input string pointer to DOS PSP
	LODSW					; AL = string length with leading char
	CBW					; AH = 0
	XCHG	AX, CX			; CX = string length + 1
	JCXZ	START_DISP			; jump if input length is 0 (no input)
	DEC	CX				; remove leading character from length
START_DISP:
	CALL	MPU_RESET_UART		; reset and put in UART mode and ready
	JNZ	MT32_EXIT			; exit if reset failed or ready timeout
	CALL	STR_TO_SYSEX		; convert input string DS:[SI] to sysex data
	CALL	WRITE_MPU			; write [SI] (length CX) to MPU-401
	JMP	SHORT MPU_RESET		; reset MPU interface and return to DOS

;----------------------------------------------------------------------------;
; SYSEX data buffer
;----------------------------------------------------------------------------;
SYSEX 	DB	SYSEX_BEGIN		; sysex begin marker
		DB	MFG_ROLAND, DEVICE_ID - 1, MODEL_MT32
		DB	CMD_DT1		; command direction TO MPU (DT1 12H)
SXDAT		DB	CMD_DISP		; write to display command
		DW	DISP_CLR 		; default to reset display function
SYXSTR	DB	20 DUP(' ') 	; 20 chars of data (space padded)
LSXDAT	EQU	$-SXDAT 		; length of checksummed data (always 23)
CHKSUM	DB	?			; checksum
		DB	SYSEX_END		; sysex EOI (End of Exclusive)
LSYSEX 	EQU	$-SYSEX 		; length of sysex (always 30)

;----------------------------------------------------------------------------;
; STR_TO_SYSEX: Convert text string to MT-32 Screen Display MIDI SYSEX
;----------------------------------------------------------------------------;
; Convert printable ASCII string to byte array of SYSEX command and data.
; If CX = 0, display is cleared.
;
; Input:
;	DS:[SI] = input string
;	CX = data length
; Output:
;	DS:[SI] = SYSEX string
;	CX = new data length
; Clobbers: AH
;----------------------------------------------------------------------------;
STR_TO_SYSEX PROC
	MAX	CX, <LENGTH SYXSTR>	; max length of string is 20 bytes
	MOV	DI, OFFSET SXDAT		; output to data offset of sysex
	PUSH	DI				; save beginning of data
	XOR	AX, AX			; DISP_OUT=0 if display, AH = zero checksum
	JCXZ	CHECKSUM			; if CX=0, reset display and don't copy data
	INC	DI				; DI = display function address
	STOSW					; replace command/address bytes in sysex
			IF ASCII_FILTER EQ 1
;----------------------------------------------------------------------------;
; Only ASCII chars 32-127 allowed. Replace invalid chars with spaces.
;
FILTER_LOOP:
	LODSB					; load input char
	ASC_FILTER	AL			; replace invalid chars with space
	STOSB					; write to output buffer
	LOOP	FILTER_LOOP
			ELSE
	REP	MOVSB				; copy input string to output sysex buffer
			ENDIF
CHECKSUM:					; calculate Roland checksum
	POP	SI				; SI = beginning of data to checksum
	MOV	CL, LSXDAT			; length of data to checksum (always 23)
SUM_LOOP:
	LODSB 				; AL = next byte
	ADD	AH, AL 			; add to byte sum
	LOOP	SUM_LOOP
	NEG	AH 				; two's complement the sum
	AND	AH, 07FH 			; mask off high bit ( mod 128 )
	MOV	[SI], AH			; write checksum remainder to sysex data
	MOV	SI, OFFSET SYSEX		; SI = beginning of sysex buffer
	MOV	CL, LSYSEX			; length of sysex data (always 30)
STR_TO_SYSEX ENDP
MT32_EXIT:
	RET

MT32	ENDP

MPU_UART	PROC
;----------------------------------------------------------------------------;
; WRITE_MPU: Write MIDI event data string to MPU
;----------------------------------------------------------------------------;
; Input:
;	DS:[SI] = MIDI event data string
;	CX = length of string
;	DX = MPU base (DATA) port
; Clobbers: AL
;----------------------------------------------------------------------------;
WRITE_MPU	PROC
	CLI					; no interrupts while writing
	CALL	MPU_READY			; wait for DRR
	JNZ	WRITE_MPU_RET		; exit if DRR timeout
	LODSB					; load next byte
	OUT	DX, AL			; write to DATA port
	STI					; allow interrupts between bytes
			IF SYSEX_DELAY GT 0
	MOV	AX, SYSEX_DELAY		; delay for SYSEX
	CALL	IO_DELAY_MS			; AL * ms delay
			ENDIF
	LOOP	WRITE_MPU			; loop through string
WRITE_MPU_RET:
	STI					; restore interrupts
	RET
WRITE_MPU	ENDP

;----------------------------------------------------------------------------;
; MPU_RESET: Reset MPU, set to default mode
;----------------------------------------------------------------------------;
; Input:
;	DX = MPU base (DATA) port
; Output:
;	ZF if reset ok and MPU ready
;	NZ if timeout or MPU not ready
; Clobbers: AX
;----------------------------------------------------------------------------;
MPU_RESET	PROC
	PUSH	CX				; call-preserve registers
	CLI					; no interrupts/ISR
	CALL	MPU_READY			; wait for DRR/READY, ZF if okay
	JNZ	MPU_RESET_EXIT		; exit if DRR timeout

;----------------------------------------------------------------------------;
; Send MPU interface reset command
;
	INC	DX				; COMMAND/STATUS port
	MOV	AL, CMD_RESET		; Reset command
	OUT	DX, AL			; reset interface
	DEC	DX				; DATA port
	CALL	MPU_STATUS			; wait for for DSR/STATUS, ZF if okay
	JNZ	MPU_RESET_EXIT		; exit if DSR timeout

;----------------------------------------------------------------------------;
; Wait for ACK
; MPU will not send ACK if already in UART mode
;
	MOV	CX, 10			; retry 10 times
MPU_RESET_STATUS:
	IN	AL, DX			; read from MPU
	CMP	AL, CMD_ACK			; is ACK?
	LOOPNE MPU_RESET_STATUS		; retry if not
	CALL	MPU_READY			; wait for DRR/READY again, ZF if okay
MPU_RESET_EXIT:
	STI
	POP	CX
	RET
MPU_RESET	ENDP

;----------------------------------------------------------------------------;
; MPU_RESET_UART: Reset MPU, set MPU to UART mode
;----------------------------------------------------------------------------;
; Input:
;	DX = MPU base (DATA) port
; Output:
;	NZ if error
;	ZF if no error
;	AL = 0, if no error
;----------------------------------------------------------------------------;
MPU_RESET_UART	PROC
	CALL	MPU_RESET			; reset MPU
	JNZ	MPU_RESET_UART_EXIT	; exit if DRR timeout	
	INC	DX				; COMMAND/STATUS port
	MOV	AL, CMD_MODE_UART		; set mode UART
	OUT	DX, AL			; write command
	DEC	DX				; DATA port
	XOR	AL, AL			; set ZF (success)
MPU_RESET_UART_EXIT:
	RET
MPU_RESET_UART	ENDP

;----------------------------------------------------------------------------;
; MPU_STATUS: Check DSR for byte waiting to be read from buffer
;----------------------------------------------------------------------------;
; Input:
;	DX = MPU base (DATA) port
; Output:
;	ZF = 1 if byte waiting
;	ZF = 0 if no byte waiting
; Clobbers: AX
;----------------------------------------------------------------------------;
MPU_STATUS	PROC
	MOV	AH, MASK DSR		; Data Set Ready: 80h (bit 7)
	JMP	SHORT MPU_POLL

;----------------------------------------------------------------------------;
; MPU_READY: Check DRR ready status
;----------------------------------------------------------------------------;
; Input:
;	DX = MPU base (DATA) port
; Output:
;	ZF = 1 if ready (okay to read/write)
;	ZF = 0 if not ready or timeout
;	DX = status port
; Clobbers: AX
;----------------------------------------------------------------------------;
MPU_READY	PROC
	MOV	AH, MASK DRR		; Data Receive Ready: 40h (bit 6)

;----------------------------------------------------------------------------;
; MPU_POLL: Check STATUS bits with timeout
;----------------------------------------------------------------------------;
; Input:
;	DX = MPU base (DATA) port
;	AH = status bit to poll
; Output:
;	ZF = 1 if bit is clear (okay to read/write)
;	ZF = 0 if bit is set (timeout)
; Clobbers: AX
;----------------------------------------------------------------------------;
MPU_POLL	PROC
	PUSH	CX				; preserve caller registers
	PUSH	DX
	INC	DX				; DX = STATUS/COMMAND port
	XOR	CX, CX			; timeout 64K loops
MPU_POLL_LOOP:
	IN	AL, DX			; read MPU status
	AND	AL, AH			; check status bit
	LOOPNZ MPU_POLL_LOOP		; loop until set or timeout
	POP	DX
	POP	CX
	RET
MPU_POLL	ENDP
MPU_READY	ENDP
MPU_STATUS	ENDP

MPU_UART	ENDP

			IF SYSEX_DELAY GT 0
;----------------------------------------------------------------------------;
; Delay using PIT counter increments of 1 ms
;----------------------------------------------------------------------------;
; - Calculate the total number of PIT ticks necessary (where 1,193,000 = 1s)
; - Latch the PIT and draw down the countdown total on each read.
; - Exit when countdown underflows.
;
; Note: Mode 3 (Square Wave) decements the readable counter by 2, so the
; effective frequency of the counter is actually 2,386,360 Hz.
;
; Input:
;	AX = wait in number of ms
; Clobbers: AX, BX, DI
;
; Based on contribution by @Raffzahn (under CC BY-SA 4.0):
; https://retrocomputing.stackexchange.com/a/24874/21323
;
; https://stanislavs.org/helppc/8253.html
;----------------------------------------------------------------------------;
IO_DELAY_MS	PROC
	PUSH	DX
	MOV	BX, 1193 * 2		; 1,193,180 / 1000 ms * 2 = 2,386 ticks/ms
	MUL	BX				; DX:AX = countdown of PIT ticks to wait
	XCHG	AX, BX			; DX:BX = countdown ticks
	CALL	IO_WAIT_LATCH		; AX = start read
IO_WAIT_MS_LOOP:
	MOV	DI, AX			; DI = last read
	CALL	IO_WAIT_LATCH		; AX = current counter reading
	SUB	DI, AX			; DI = # of ticks elapsed since last reading
	SUB	BX, DI			; subtract change in ticks from countdown
	SBB	DX, 0				; borrow out of high word (if necessary)
	JAE	IO_WAIT_MS_LOOP		; loop while countdown >= 0
	POP	DX
	RET

;----------------------------------------------------------------------------;
; Latch PIT 0 and read counter to AX
;----------------------------------------------------------------------------;
PIT_CH0	EQU		40H		; 8253 PIT Channel/Counter 0 port
PIT_CTRL	EQU		43H		; 8253 PIT Control Word port

IO_WAIT_LATCH PROC
	MOV	AL, 0				; Counter 0, Latch (00b)
	CLI					; disable interrupts
	OUT	PIT_CTRL, AL		; Write command to CTC
	IN	AL, PIT_CH0			; Read low byte of Counter 0 latch
	MOV	AH, AL			; Save it
	IN	AL, PIT_CH0			; Read high byte of Counter 0 latch
	STI					; restore interrupts
	XCHG	AL, AH			; convert endian
	RET
IO_WAIT_LATCH ENDP
IO_DELAY_MS ENDP
			ENDIF

_TEXT	ENDS
END START

----------------------------------------------------------------------------
Text Auto-Formatting:

----------------------------------------------------------------------------
Sublime Text syntax:
{
 	"tab_completion": false,
	"auto_complete": false,
	"tab_size": 6,
}

----------------------------------------------------------------------------
Modeline magic for various editors

/* vim: set tabstop=6:softtabstop=6:shiftwidth=6:noexpandtab */
# sublime: tab_completion false; auto_complete false; tab_size 6