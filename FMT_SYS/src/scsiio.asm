; Written by CaptainYS
; SCSI Utility

PHASE_FLAG_COMMAND		EQU		01H
PHASE_FLAG_DATA_IN		EQU		02H
PHASE_FLAG_MESSAGE		EQU		04H
PHASE_FLAG_STATUS		EQU		08H

IO_1US_WAIT				EQU		06CH	; Available after FM Towns 20F

IO_SCSI_DATA			EQU		0C30H
IO_SCSI_STATUS			EQU		0C32H
IO_SCSI_COMMAND			EQU		0C32H

IO_DMA_INITIALIZE		EQU		0A0H
IO_DMA_CHANNEL			EQU		0A1H
IO_DMA_COUNT_LOW		EQU		0A2H
IO_DMA_COUNT_HIGH		EQU		0A3H
IO_DMA_ADDR_LOW			EQU		0A4H
IO_DMA_ADDR_MID_LOW		EQU		0A5H
IO_DMA_ADDR_MID_HIGH	EQU		0A6H
IO_DMA_ADDR_HIGH		EQU		0A7H
IO_DMA_DEVICE_CTRL_LOW	EQU		0A8H
IO_DMA_DEVICE_CTRL_HIGH	EQU		0A9H
IO_DMA_MODE_CONTROL		EQU		0AAH
IO_DMA_STATUS			EQU		0ABH
IO_DMA_REQUEST			EQU		0AEH
IO_DMA_MASK				EQU		0AFH

SCSI_STATUS_GOOD                      	EQU		0
SCSI_STATUS_CHECK_CONDITION           	EQU		02H
SCSI_STATUS_CONDITION_MET             	EQU		04H
SCSI_STATUS_BUSY                      	EQU		08H
SCSI_STATUS_INTERMEDIATE              	EQU		10H
SCSI_STATUS_INTERMEDIATE_CONDITION_MET	EQU		14H
SCSI_STATUS_RESERVATION_CONFLICT      	EQU		18H
SCSI_STATUS_COMMAND_TERMINATED        	EQU		22H
SCSI_STATUS_QUEUE_FULL                	EQU		28H



SCSI_PHASE_FLAG			EQU		1
SCSI_STATUS_RETURN		EQU		2
SCSI_MESSAGE_RETURN		EQU		3
SCSI_COMMAND_STACKFRAME_SIZE	EQU		4


; Steps to access a SCSI device
; 
; (1) Wait for the SCSI controller to be ready (SCSI_WAIT_READY)
; (2) Initialize DMA (SCSI_DMA_INITIALIZE)
; (3) Select SCSI ID.  Write SCSI ID bits (bit7+bitN) to DATA register, and then set WEN and SEL bits. (SCSI_SELECT)
; (4) SCSI controller must enter SELECTION phase and become BUSY.  If not, something is wrong (SCSI_WAIT_BUSY)
;     If something is gone wrong, make sure to clear SEL bit before exiting, otherwise SCSI controller will be stuck in the
;     SELECTION phase.
; (5) Clear SEL bit to start the sequence (SCSI_START_COMMAND_SEQUENCE)
; (6) While the SCSI controller is BUSY:
;       When BUSY bit is clear, break the loop.
;       When REQ bit is set, process according to the phase:
;         In MESSAGE_IN phase, read data byte and cache it for MESSAGE return.
;         In STATUS phase, read data byte and cache it for STATUS return.
;         In DATA IN/OUT phase:
;           6-1 Set DMA transfer direction (48H for Mem to I/O, 44H for I/O to Mem)
;           6-2 Set DMA address and count (FM TOWNS BIOS adjusts the count so that the DMA transfer does not cross 64K border.
;               It is unknown if it is really a limitation of the TOWNS DMA or if the code is left over from FM-R50.)
;           6-3 Wait until DMAE (DMA End) bit is set or the SCSI Phase is not DATA In/Out.
;           6-4 If the SCSI Phase is not DATA In/Out, move on to the next phase.
;           6-5 If not (which means DMAE), move the data pointer forward and goto 6-2.
;         Other phases can be ignored


;Input
; CL		SCSI ID
; DS:[SI]   SCSI Command
; EDI       Data Return Buffer Physical Address
;Output
; AH		0       : No Error
;           80H     : Failed to talk to the SCSI device
;			Non-Zero: SCSI Status
; AL        SCSI Message
; Carry     0       : No Error
;           1       : Error
; Other registers won't be preserved.
SCSI_COMMAND:
						PUSHF
						MOV		BP,SP
						SUB		SP,SCSI_COMMAND_STACKFRAME_SIZE
						MOV		BX,SP	; Tentative, so that nothing will be written to strange location.


						; Pentium model may be too fast for SCSI controller when multiple commands
						; are shot in a short time.  Add 10ms delay.
						PUSH	CX
						MOV		CX,10000
.ten_millisec_delay:
						OUT		6CH,AL
						LOOP	.ten_millisec_delay
						POP		CX


						CLI		; Expected to be used when the BIOS it no present.  Do all by polling.

						MOV		BYTE SS:[BP-SCSI_PHASE_FLAG],0

						CALL	SCSI_WAIT_READY	; AL,DX Destroyed

						CALL	SCSI_DMA_INITIALIZE

						CALL	SCSI_SELECT
						JB		SCSI_ERROR_80

						; CL (SCSI ID) no longer needed

						CALL	SCSI_WAIT_BUSY
						CALL	SCSI_START_COMMAND_SEQUENCE
						JB		SCSI_ERROR_80

						; Keep DS:SI command pointer in the loop.

SCSI_PHASE_LOOP:
						; I don't know if it is necessary, but SYSROM service routine reads STATUS I/O twice >>
						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX
						; I don't know if it is necessary, but SYSROM service routine reads STATUS I/O twice <<

						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX
						TEST	AL,08H			; Zero means BUSFREE
						JE		SCSI_END_OF_SEQUENCE

						TEST	AL,80H			; Non-Zero means REQ
						JE		SCSI_PHASE_LOOP

; Phase and I/O [0xC32] read
;  PHASE_BUSFREE:       C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x0*
;  PHASE_DATA_OUT:      C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x0*
;  PHASE_COMMAND:       C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x1*
;                                                                    (0x2*)
;  PHASE_MESSAGE_OUT:   C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x3*
;  PHASE_DATA_IN:       C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x4*
;  PHASE_STATUS:        C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x5*
;                                                                    (0x6*)
;  PHASE_MESSAGE_IN:    C_D=0x10  MSG=0x20  I_O=0x40     I/O [0xC32]  0x7*

						AND		AL,70H
						JE		SCSI_DATA_OUT_PHASE
						CMP		AL,10H
						JE		SCSI_COMMAND_PHASE
						CMP		AL,40H
						JE		SCSI_DATA_IN_PHASE
						CMP		AL,50H
						JE		SCSI_STATUS_PHASE
						CMP		AL,70H
						JNE		SCSI_PHASE_LOOP

SCSI_MESSAGE_PHASE:
						OR		BYTE SS:[BP-SCSI_PHASE_FLAG],PHASE_FLAG_MESSAGE
						LEA		BX,[BP-SCSI_MESSAGE_RETURN]
						JMP		SCSI_GET_BYTE
SCSI_STATUS_PHASE:
						OR		BYTE SS:[BP-SCSI_PHASE_FLAG],PHASE_FLAG_STATUS
						LEA		BX,[BP-SCSI_STATUS_RETURN]
SCSI_GET_BYTE:
						MOV		DX,IO_SCSI_DATA
						IN		AL,DX
						MOV		SS:[BX],AL
						JMP		SCSI_PHASE_LOOP

SCSI_COMMAND_PHASE:
						OR		BYTE SS:[BP-SCSI_PHASE_FLAG],PHASE_FLAG_COMMAND
						LODSB
						MOV		DX,IO_SCSI_DATA
						OUT		DX,AL
						JMP		SCSI_PHASE_LOOP

SCSI_DATA_IN_PHASE:
						OR		BYTE SS:[BP-SCSI_PHASE_FLAG],PHASE_FLAG_DATA_IN
						MOV		AL,44H		; Single Mode, I/O=>Memory
						CALL	SCSI_EXEC_DMA
						JMP		SCSI_PHASE_LOOP

SCSI_DATA_OUT_PHASE:
						OR		BYTE SS:[BP-SCSI_PHASE_FLAG],PHASE_FLAG_DATA_IN
						MOV		AL,48H		; Single Mode, Memory=>I/O
						CALL	SCSI_EXEC_DMA
						JMP		SCSI_PHASE_LOOP

SCSI_END_OF_SEQUENCE:
						MOV		AH,SS:[BP-SCSI_STATUS_RETURN]
						MOV		AL,SS:[BP-SCSI_MESSAGE_RETURN]
						AND		AH,AH
						JNE		SCSI_ERROR

SCSI_NOERR:
						MOV		SP,BP
						POPF
						CLC
						RET

SCSI_ERROR_80:
						MOV		AH,80H
SCSI_ERROR:
						MOV		SP,BP
						POPF
						STC
						RET





SCSI_WAIT_READY:
						PUSH	CX
						CLC
						MOV		CX,3000
.wait_ready_loop:
						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX
						AND		AL,8	; BUSY Flag
						JE		.scsi_is_ready
						OUT		IO_1US_WAIT,AL
						LOOP	.wait_ready_loop
						STC
.scsi_is_ready:
						POP		CX
						RET




SCSI_DMA_INITIALIZE:
						MOV		AL,3	; Reset SCSI Controller
						OUT		IO_DMA_INITIALIZE,AL
						MOV		AL,1	; Channel 1 SCSI
						OUT		IO_DMA_CHANNEL,AL
						MOV		AL,20H	; DMA enable
						OUT		IO_DMA_DEVICE_CTRL_LOW,AL
						RET




; CL   SCSI ID
; Must Preserve CL
SCSI_SELECT:
						MOV		DX,IO_SCSI_DATA
						MOV		AL,1
						SHL		AL,CL
						OR		AL,80H	; Bit7 for CPU, Bit# for SCSI Device
						OUT		DX,AL
						MOV		DX,IO_SCSI_COMMAND
						MOV		AL,86H	; WEN,SEL
						OUT		DX,AL
						CLC
						RET




SCSI_WAIT_BUSY:
						CLC
						MOV		CX,3000
.wait_busy_loop:
						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX
						AND		AL,8
						JNE		.scsi_is_busy		; Yes, the SCSI controller wakes up!
						OUT		IO_1US_WAIT,AL
						LOOP	.wait_busy_loop
						STC
.scsi_is_busy:
						RET




; Should preserve CF
SCSI_START_COMMAND_SEQUENCE:
						MOV		DX,IO_SCSI_COMMAND
						MOV		AL,82H	; WEN,DMAE
						OUT		DX,AL	; It starts the SCSI-command sequence.
						RET




; Input
; AL:  44H=Data In (I/O to Mem)   48H=Data Out (Mem to I/O)
; EDI: Physical Address for the Data Buffer
SCSI_EXEC_DMA:
						OUT		IO_DMA_MODE_CONTROL,AL

SCSI_EXEC_DMA_TRANSFER_LOOP:
						MOV		EAX,EDI
						OUT		IO_DMA_ADDR_LOW,AX
						SHR		EAX,16
						OUT		IO_DMA_ADDR_MID_HIGH,AL
						MOV		AL,AH
						OUT		IO_DMA_ADDR_HIGH,AL

						MOV		AX,0FFFFH
						SUB		AX,DI
						OUT		IO_DMA_COUNT_LOW,AX

						; Unmask DMA
						IN		AL,IO_DMA_MASK
						AND		AL,0DH
						OUT		IO_DMA_MASK,AL

.wait_dmae:
						MOV		DX,IO_DMA_STATUS
						IN		AL,DX
						AND		AL,2	; DMAE bit for SCSI (DMA Ch 1) Non-zero means Terminal Count or DMA End
						JNE		.dmae_set

						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX

						; Should continue as long as
						;    (AL&0x30)==0  // In Data-In or Data-Out phase
						;    &&
						;    (AL&8)!=0     // SCSI controller is still busy

						XOR		AL,8
						TEST	AL,38H	; Non-zero means no longer in Data-In nor Data-Out phase
						JE		.wait_dmae

.dmae_set:
						; Mask DMA
						IN		AL,IO_DMA_MASK
						AND		AL,0FH
						OR		AL,02H
						OUT		IO_DMA_MASK,AL

						MOV		DI,0
						ADD		EDI,10000H

						; The conditions to come here:
						;  (1) Terminal Count / DMA End and/or
						;  (2) SCSI Phase changed from Data phase, or SCSI ready (means command prematurely terminated)
						; If in Data Phase and SCSI is busy, continue transfer.  If not, transfer is done.

						MOV		DX,IO_SCSI_STATUS
						IN		AL,DX

						; Should continue as long as
						;    (AL&0x30)==0  // In Data-In or Data-Out phase
						;    &&
						;    (AL&8)!=0     // SCSI controller is still busy

						XOR		AL,8
						TEST	AL,38H	; Non-zero means no longer in Data-In nor Data-Out phase
						JE		SCSI_EXEC_DMA_TRANSFER_LOOP


						; IO.SYS apparently won't reset Highest Byte of the DMA address.
						; Make sure to clear when exit.
						XOR		AL,AL
						OUT		IO_DMA_ADDR_HIGH,AL


						RET




; Input
;   DX:AX            Real-Mode SEG:OFFSET
; Output
;   EDX              Linear address
;   Hi-Word of EAX   0
SCSI_UTIL_REALADDR_TO_LINEAR:
						AND		EDX,0FFFFH
						AND		EAX,0FFFFH
						SHL		EDX,4
						ADD		EDX,EAX
						RET
