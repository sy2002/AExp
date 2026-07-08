; ****************************************************************************
; YOUR-PROJECT-NAME (GITHUB-REPO-SHORTNAME) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by TODO-ADD-NAME-OF-VHDL-FILE-HERE.
;
; The execution starts at the label START_FIRMWARE.
;
; done by YOURNAME in YEAR and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
#include "../../M2M/rom/main.asm"

; Only include the Shell, if you want to use the pre-build core automation
; and user experience. If you build your own, then remove this include and
; also remove the include "shell_vars.asm" in the variables section below.
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

                ; Run the Shell: This is where you could put your own system
                ; instead of the shell.
                ; Before that: deterministic init of the ADF write-back state.
                ; It cannot live in PREP_START - HANDLE_CORE_IO can already be
                ; reached during boot (HANDLE_IO is polled from boot-time wait
                ; loops), and RAM variables are undefined at power-on.
START_FIRMWARE  RSUB    ADF_WB_INIT, 1
                RSUB    RTC_INIT, 1
                RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the
; browser is only showing valid files and directories.
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: Context (see CTX_* in sysdef.asm)
;  R11: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering FILTER_FILES
; Output:
;   R8: 0=do not filter file, i.e. show file
FILTER_FILES    INCRB
                MOVE    R9, R0

                CMP     1, R9                   ; do not filter directories
                RBRA    _FFILES_RET_0, Z

                CMP     CTX_LOAD_ROM, R10       ; only filter in the ADF
                RBRA    _FFILES_RET_0, !Z       ; load context
                CMP     OPTM_G_ADF, R11         ; menu item " ADF:%s"?
                RBRA    _FFILES_RET_0, !Z

                MOVE    ADF_FILE_EXT, R9        ; only show .adf files
                RSUB    M2M$CHK_EXT, 1          ; preserves R8/R9/R10
                RBRA    _FFILES_RET_0, C        ; extension matched: show it

                MOVE    1, R8                   ; no match: filter it
                RBRA    _FFILES_RET, 1

_FFILES_RET_0   XOR     R8, R8                  ; R8 = 0 = do not filter file

_FFILES_RET     MOVE    R0, R9
                DECRB
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; The ADF is streamed into the C_DEV_AMIGA_ADF device, which bridges into a
; 4 MB HyperRAM region (see globals.vhd). We range-guard the file size to
; 160..166 tracks x 5632 bytes = 901,120..934,912 bytes BEFORE streaming, so
; an absurd (renamed) file can never stream past the region. The exact
; multiple-of-5632 validation happens in the core-side CSR responder
; (adf_mount_wrapper.vhd), which reports "Invalid ADF size" to the OSM.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: Context (see CTX_* in sysdef.asm)
;  R10: Menu group id (see config.vhd) of the menu item that is responsible
;       for triggering PREP_LOAD_IMAGE
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to  error msg string
PREP_LOAD_IMAGE INCRB

                CMP     CTX_LOAD_ROM, R9        ; only guard the ADF load
                RBRA    _PREP_LI_OK, !Z
                CMP     OPTM_G_ADF, R10
                RBRA    _PREP_LI_OK, !Z

                ; ADF context confirmed: BEFORE anything else, force-flush all
                ; unsaved writes of the currently mounted disk - the streaming
                ; that follows overwrites the HyperRAM image, and the Shell
                ; has already re-opened HANDLE_RM_FILE1 for the NEW file
                ; (which is exactly why the flush works from our own FDH
                ; snapshot, see FLUSH_ADF_STEP). Bounded to >4 full disks of
                ; chunks so an Amiga that re-dirties tracks forever cannot
                ; starve the OSM; in that case we bail out with a friendly,
                ; non-fatal message (the Shell re-opens the file browser).
                MOVE    R8, R3                  ; R3: handle of the new file
                MOVE    8192, R4                ; R4: chunk budget
_PREP_LI_FL     MOVE    1, R8                   ; forced step (ignore the
                RSUB    FLUSH_ADF_STEP, 1       ; anti-thrashing gate)
                CMP     0, R8                   ; clean and idle?
                RBRA    _PREP_LI_FLD, Z
                SUB     1, R4
                RBRA    _PREP_LI_FL, !Z
                MOVE    1, R8                   ; budget exhausted: bail out
                MOVE    WRN_ADF_BUSY, R9
                DECRB
                RET

                ; The mount flow OWNS the arm state: disarm the write-back
                ; here and let the PARSEST=READY of the NEW mount re-arm it
                ; with a fresh handle snapshot. HANDLE_CORE_IO alone cannot
                ; do that: the whole load runs without HANDLE_IO polling, so
                ; the READY -> LOADING -> READY transient of a re-mount is
                ; invisible to it - without this disarm, flushes after a disk
                ; swap would write the new disk into the OLD file.
_PREP_LI_FLD    MOVE    ADF_FDH_VALID, R4
                MOVE    0, @R4
                MOVE    ADF_MOUNT_SEEN, R4
                MOVE    0, @R4                  ; 0: a fresh READY may arm
                MOVE    ADF_FL_STATE, R4
                MOVE    0, @R4
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 0 until the new
                MOVE    AEXP_DEV_ADF, @R4       ; mount is complete
                MOVE    M2M$RAMROM_4KWIN, R4
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    0, @R4

                MOVE    R3, R8                  ; restore the file handle

                MOVE    R8, R0                  ; R0: file size low word
                MOVE    R8, R1                  ; R1: file size high word
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R0
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R1

                ; valid range: 901,120 (0x000DC000) .. 934,912 (0x000E4400).
                ; QNICE CMP sets N for UNSIGNED src>dst (V is the signed one),
                ; so plain compares would work for any value; the bit masks
                ; below are used purely for clarity/symmetry.
                CMP     0x000D, R1              ; high word 0x000D?
                RBRA    _PREP_LI_HID, Z
                CMP     0x000E, R1              ; high word 0x000E?
                RBRA    _PREP_LI_BAD, !Z

                ; high word 0x000E: low word must be <= 0x4400
                MOVE    R0, R2
                AND     0x8000, R2              ; lo >= 0x8000 can never be ok
                RBRA    _PREP_LI_BAD, !Z
                CMP     0x4400, R0              ; both positive: exact compare
                RBRA    _PREP_LI_OK, N          ; lo <  0x4400: OK
                RBRA    _PREP_LI_OK, Z          ; lo == 0x4400: OK
                RBRA    _PREP_LI_BAD, 1         ; lo >  0x4400: too big

                ; high word 0x000D: low word must be >= 0xC000
_PREP_LI_HID    MOVE    R0, R2
                AND     0xC000, R2              ; >= 0xC000 iff bits 15+14 set
                CMP     0xC000, R2
                RBRA    _PREP_LI_BAD, !Z

_PREP_LI_OK     XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                DECRB
                RET

_PREP_LI_BAD    MOVE    1, R8                   ; error: invalid size
                MOVE    WRN_ADF_SIZE, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
PREP_START      INCRB

                ; Apply the saved HDMI Filter selection. At this point the
                ; framework has already loaded its own default into the
                ; ascal polyphase RAM (LANCZOS2_12 + SCAN_BR_110_80 via
                ; M2M/rom/filters.asm:LOAD_ASCAL_FLT), and HELP_MENU_INIT has
                ; populated M2M$CFM_DATA from the saved SD config. We now
                ; overwrite the framework default with whatever the user
                ; chose -- before the core un-resets and the first frame
                ; reaches HDMI, so no glitch is visible. The default
                ; selection in config.vhd is "Lanczos" (LANCZOS2_12 on both
                ; axes), so for first-time users (or anyone with an empty
                ; config) this replaces the Scanlines-look preload of the
                ; framework before it ever reaches the screen.
                RSUB    LOAD_HDMI_FILTER, 1

                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
OSM_SEL_POST    INCRB

                ; HDMI Filter selection changed: re-push the matching (H, V)
                ; coefficient pair into the ascal polyphase RAM. NO core
                ; reset -- only the coefficient RAM content changes; the
                ; Amiga keeps running. The user sees the new filter from the
                ; next frame.
                CMP     AEXP_OPTM_G_FILTER, R8
                RBRA    _OSM_SEL_POST_R, !Z
                RSUB    LOAD_HDMI_FILTER, 1

_OSM_SEL_POST_R XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
OSM_SEL_PRE     INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; ADF write-back: background flush of Amiga-written tracks to the SD card
;
; The track engine (CORE/vhdl/adf_track_engine.vhd) MFM-decodes Amiga writes
; and commits verified sectors into the ADF image in HyperRAM; the mount
; wrapper (CORE/vhdl/adf_mount_wrapper.vhd) collects the affected tracks in
; a dirty bitmap behind window ADF_WBC_4KWIN of device AEXP_DEV_ADF and runs
; the vdrives-style anti-thrashing countdown. The firmware side below mirrors
; the proven C64MEGA65 vdrives discipline (background flushing driven from
; HANDLE_IO, chunked to stay responsive, still-open FAT32 handle, errors are
; fatal) against our non-vdrives device. Full design:
; doc/floppy-adf.md
; ----------------------------------------------------------------------------

; ADF_WB_INIT: called once from START_FIRMWARE, before the Shell starts.
; Zero-initializes the write-back state and loads VD_ANTI_THRASHING_DELAY
; from config.vhd into the WBC hardware countdown register (mirrors the
; vdrives VD_INIT pattern, M2M/rom/vdrives.asm).
ADF_WB_INIT     INCRB

                MOVE    ADF_FDH_VALID, R0
                MOVE    0, @R0
                MOVE    ADF_MOUNT_SEEN, R0
                MOVE    0, @R0
                MOVE    ADF_FL_STATE, R0
                MOVE    0, @R0

                MOVE    M2M$RAMROM_DEV, R0      ; anti-thrashing delay (ms)
                MOVE    M2M$CONFIG, @R0         ; from config.vhd
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    M2M$CFG_GENERAL, @R0
                MOVE    M2M$CFG_VD_AT_DELAY, R0
                MOVE    @R0, R1

                MOVE    M2M$RAMROM_DEV, R0      ; ... into the WBC register
                MOVE    AEXP_DEV_ADF, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    ADF_WBC_4KWIN, @R0
                MOVE    ADF_WBC_ATDELAY, R0
                MOVE    R1, @R0

                DECRB
                RET

; RTC_INIT: called once from START_FIRMWARE, before the Shell starts (like
; ADF_WB_INIT - RAM variables are undefined at power-on). Primes the minute-edge
; detector with a sentinel so the first minute change reseeds the Amiga clock.
RTC_INIT        INCRB
                MOVE    RTC_LAST_MIN, R0
                MOVE    0xFFFF, @R0
                DECRB
                RET

; RTC_STEP: one non-blocking step of the battery-RTC reseed (issue #13).
;
; The Minimig $DC0000 clock (minimig.v) advances minutes/hours/date only when the
; framework flips the RTC "new value" toggle, which it does when an external I2C
; RTC read completes (M2M/vhdl/i2c/rtc_controller.vhd). The framework issues that
; read only at reset, so the Amiga clock would freeze ~1 minute after the boot
; seed (minimig free-runs its seconds field but never carries into minutes). This
; re-issues the read once per real minute - aligned to the :00 boundary by
; edge-detecting the free-running internal-minute register - which reseeds
; minimig with fresh time and restarts its in-FPGA seconds counter from 0. This
; is the MiSTer "HPS resend once per minute" cadence; see the reseed rationale in
; .research/INTEGRATION-SPEC-rtc.md.
;
; The minute register is read WITHOUT flipping the toggle (only a command-byte
; write does), so the common path is just a couple of cheap device reads. The
; command byte is accepted only while I2C is idle, so a still-running read (e.g.
; the boot read) simply defers to the next call.
;
; Expects the caller to tolerate a changed RAMROM device selection (HANDLE_CORE_IO
; saves and restores it around this call). Input/Output: none.
RTC_STEP        INCRB
                MOVE    M2M$RAMROM_DEV, R0      ; select the framework RTC device
                MOVE    AEXP_DEV_RTC, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    RTC_4KWIN, @R0

                MOVE    RTC_COMMAND, R0         ; defer while an I2C read runs
                MOVE    @R0, R1
                AND     1, R1
                RBRA    _RTC_RET, !Z

                MOVE    RTC_MINUTES, R0         ; free-running internal minute
                MOVE    @R0, R0                 ; (BCD, high byte already 0)
                MOVE    RTC_LAST_MIN, R1
                CMP     @R1, R0
                RBRA    _RTC_RET, Z             ; same minute: nothing to do

                MOVE    R0, @R1                 ; remember this minute
                MOVE    RTC_COMMAND, R0         ; reseed: stop, then read+restart
                MOVE    RTC_CMD_STOP, @R0       ; b3=0: stop the internal timer
                MOVE    RTC_CMD_RESYNC, @R0     ; b1=read + b3=run: the external
                                                ; read flips the toggle and
                                                ; minimig reseeds $DC0000

_RTC_RET        DECRB
                RET

; HANDLE_CORE_IO callback function:
;
; Called from HANDLE_IO in every iteration of the main loop and of all
; blocking wait loops - see the M2M-UPSTREAM core-io-hook contract in
; M2M/rom/shell.asm. AExp uses the time slice to run the ADF write-back:
;
;   1. SD-card-change guard: a swapped card invalidates the retained file
;      handle - disable write-back and discard the dirty state (the
;      ROSM_INTEGRITY precedent: never write to a card we did not open on).
;   2. Mount tracking: when a mount reaches PARSEST=READY, snapshot the
;      Shell handle HANDLE_RM_FILE1 into our own FDH (the Shell re-opens
;      that struct for the NEXT load before PREP_LOAD_IMAGE even runs!) and arm
;      the write-back: WBC WR_EN=1 makes the track engine announce df0 as
;      writable to the Amiga.
;   3. One background flush step (respects the anti-thrashing gate).
;
; Input/Output: none; all registers are preserved
HANDLE_CORE_IO  SYSCALL(enter, 1)

                ; be transparent about the active RAMROM device selection
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R1
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3

                ; --- 1. SD guards: a shell-detected card change OR an
                ;        active-slot switch. The file browser F1/F3 switch
                ;        updates SD_ACTIVE WITHOUT raising SD_CHANGED, so the
                ;        slot the handle was snapshotted on is compared, too.
                MOVE    SD_CHANGED, R4
                CMP     1, @R4
                RBRA    _HCIO_KILL, Z
                MOVE    ADF_FDH_VALID, R4       ; slot check only when armed
                CMP     1, @R4
                RBRA    _HCIO_MOUNT, !Z
                MOVE    M2M$CSR, R4
                MOVE    @R4, R4
                AND     M2M$CSR_SD_ACTIVE, R4
                MOVE    ADF_SD_SLOT, R5
                CMP     @R5, R4
                RBRA    _HCIO_MOUNT, Z

_HCIO_KILL      MOVE    ADF_FDH_VALID, R4       ; already disabled: done
                CMP     0, @R4
                RBRA    _HCIO_RET, Z
                MOVE    0, @R4                  ; invalidate the FDH snapshot
                MOVE    ADF_MOUNT_SEEN, R4      ; 1: BLOCK re-arming from the
                MOVE    1, @R4                  ; STALE PARSEST=READY of the
                                                ; old mount - the next ADF
                                                ; load (PREP_LOAD_IMAGE)
                                                ; re-enables arming
                MOVE    ADF_FL_STATE, R4        ; abort a running session
                MOVE    0, @R4
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 0 (df0 reverts to
                MOVE    AEXP_DEV_ADF, @R4       ; write-protected) and wipe
                MOVE    M2M$RAMROM_4KWIN, R4    ; the whole dirty bitmap
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    0, @R4
                MOVE    ADF_WBC_DIRTY0, R4
                MOVE    11, R5
_HCIO_WIPE      MOVE    0xFFFF, @R4++           ; write-1-to-clear
                SUB     1, R5
                RBRA    _HCIO_WIPE, !Z
                RBRA    _HCIO_RET, 1

                ; --- 2. mount tracking (PARSEST=READY rising edge) ---
_HCIO_MOUNT     MOVE    AEXP_DEV_ADF, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1         ; R10: parse status
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _HCIO_NOMNT, !Z
                MOVE    ADF_MOUNT_SEEN, R4
                CMP     1, @R4
                RBRA    _HCIO_FLUSH, Z          ; this mount is already armed
                MOVE    1, @R4
                MOVE    HANDLE_RM_FILE1, R8     ; snapshot the file handle
                MOVE    ADF_FDH, R9
                MOVE    FAT32$FDH_STRUCT_SIZE, R10
                SYSCALL(memcpy, 1)
                MOVE    ADF_FDH_VALID, R4
                MOVE    1, @R4
                MOVE    ADF_FL_STATE, R4
                MOVE    0, @R4
                MOVE    M2M$CSR, R4             ; remember the active SD slot
                MOVE    @R4, R4                 ; the snapshot was taken on
                AND     M2M$CSR_SD_ACTIVE, R4   ; (see the SD guards above)
                MOVE    ADF_SD_SLOT, R5
                MOVE    R4, @R5
                MOVE    M2M$RAMROM_DEV, R4      ; WR_EN := 1
                MOVE    AEXP_DEV_ADF, @R4
                MOVE    M2M$RAMROM_4KWIN, R4
                MOVE    ADF_WBC_4KWIN, @R4
                MOVE    ADF_WBC_CTRL, R4
                MOVE    1, @R4
                RBRA    _HCIO_FLUSH, 1

_HCIO_NOMNT     MOVE    ADF_MOUNT_SEEN, R4      ; re-arm the edge detection
                MOVE    0, @R4                  ; for the next mount

                ; --- 3. one background flush step ---
_HCIO_FLUSH     XOR     R8, R8                  ; 0 = respect anti-thrashing
                RSUB    FLUSH_ADF_STEP, 1

                ; keep the Amiga battery clock live (issue #13): re-issue the
                ; framework RTC read once per minute so the Minimig $DC0000 clock
                ; advances instead of freezing after the boot seed
                RSUB    RTC_STEP, 1

_HCIO_RET       MOVE    R1, @R0                 ; restore RAMROM selection
                MOVE    R3, @R2
                SYSCALL(leave, 1)
                RET

; FLUSH_ADF_STEP: one resumable step of the ADF write-back
;
; Cooperative multitasking, mirroring the vdrives FLUSH_CACHE discipline
; (M2M/rom/shell.asm): one call does at most one of
;   * idle, dirty tracks pending, gate open (or forced): pick the LOWEST
;     dirty track, clear its bit FIRST (write-1-to-clear; a concurrent
;     re-write by the Amiga re-sets it, so the track is re-flushed - torn
;     reads self-heal), f32_fseek the retained handle to track * 5632
;   * active session: stream ADF_FLUSH_CHUNK bytes from the ADF byte window
;     to f32_fwrite, then f32_fflush the chunk; at track end close the session
;
; The chunk is 512 bytes and every track start is 512-aligned, so chunks
; never cross a 4k device window and cover exactly one FAT32 sector - and
; each chunk is EXPLICITLY flushed before returning: the SD controller has a
; single hardware sector buffer shared with every other SD user (the OSM
; settings save runs from the very wait loops that also poll us!), so no
; dirty buffered sector may ever survive across time slices. The explicit
; flush costs nothing: the sector is written exactly once either way.
; FAT32 errors are fatal - the C64MEGA65 FLUSH_CACHE policy; SD removal is
; pre-guarded by the SD-change check in HANDLE_CORE_IO.
;
; Expects the caller to tolerate a changed RAMROM device selection.
;
; Input:
;   R8: 0=respect the anti-thrashing gate (background), 1=force (flush now)
; Output:
;   R8: 0=clean and idle (nothing left to do), 1=dirty work remains
FLUSH_ADF_STEP  INCRB
                MOVE    R9, R0                  ; preserve R9..R12
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R8, R4                  ; R4: force flag

                MOVE    M2M$RAMROM_DEV, R8      ; select the WBC window
                MOVE    AEXP_DEV_ADF, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    ADF_WBC_4KWIN, @R8

                MOVE    ADF_FL_STATE, R8        ; session active?
                CMP     1, @R8
                RBRA    _FADF_CHUNK, Z

                MOVE    ADF_WBC_STAT, R8        ; idle: any dirty tracks?
                MOVE    @R8, R8
                AND     1, R8
                RBRA    _FADF_RET0, Z           ; clean and idle: done

                MOVE    ADF_FDH_VALID, R8       ; without a handle we can
                CMP     1, @R8                  ; never flush: discard (only
                RBRA    _FADF_DISCARD, !Z       ; reachable defensively)

                CMP     1, R4                   ; forced?
                RBRA    _FADF_PICK, Z
                MOVE    ADF_WBC_STAT, R8        ; anti-thrashing gate: only
                MOVE    @R8, R8                 ; start a track after the
                AND     2, R8                   ; hardware countdown expired
                RBRA    _FADF_RET1, Z           ; gated: work remains

                ; pick the lowest dirty track: first non-zero bitmap word,
                ; then its lowest set bit
_FADF_PICK      MOVE    ADF_WBC_DIRTY0, R5      ; R5: bitmap word address
                XOR     R6, R6                  ; R6: word index 0..10
_FADF_FWORD     CMP     0, @R5
                RBRA    _FADF_FBIT, !Z
                ADD     1, R5
                ADD     1, R6
                CMP     11, R6
                RBRA    _FADF_FWORD, !Z
                RBRA    _FADF_RET0, 1           ; raced to clean: done

_FADF_FBIT      MOVE    @R5, R7                 ; R7: bitmap word value
                MOVE    1, R8                   ; R8: bit mask
                XOR     R9, R9                  ; R9: bit index
_FADF_FBIT1     MOVE    R7, R10
                AND     R8, R10
                RBRA    _FADF_FOUND, !Z
                AND     0xFFFD, SR              ; clear X: shift in zeros
                SHL     1, R8
                ADD     1, R9
                RBRA    _FADF_FBIT1, 1

_FADF_FOUND     MOVE    R8, @R5                 ; W1C the bit FIRST
                MOVE    R6, R10                 ; track = word * 16 + bit
                AND     0xFFFD, SR
                SHL     4, R10
                ADD     R9, R10                 ; R10: track number

                XOR     R11, R11                ; byte addr = track * 5632
                XOR     R12, R12                ; (32 bit, iterative add -
                CMP     0, R10                  ; QNICE has no multiplier;
                RBRA    _FADF_SEEK, Z           ; <= 165 iterations)
_FADF_MUL       ADD     ADF_TRACK_BYTES, R11
                ADDC    0, R12
                SUB     1, R10
                RBRA    _FADF_MUL, !Z

_FADF_SEEK      MOVE    ADF_FL_BADDR_LO, R8     ; open the session
                MOVE    R11, @R8
                MOVE    ADF_FL_BADDR_HI, R8
                MOVE    R12, @R8
                MOVE    ADF_FL_REMAIN, R8
                MOVE    ADF_TRACK_BYTES, @R8
                MOVE    ADF_FDH, R8             ; seek to the track start
                MOVE    R11, R9                 ; (file offset = image offset)
                MOVE    R12, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                MOVE    ADF_FL_STATE, R8
                MOVE    1, @R8
                RBRA    _FADF_RET1, 1           ; chunks stream on later calls

                ; active session: stream one chunk. window = byte addr >> 12,
                ; offset = byte addr & 0xFFF (one file byte per window word)
_FADF_CHUNK     MOVE    ADF_FL_BADDR_HI, R8
                MOVE    @R8, R5
                AND     0xFFFD, SR              ; clear X: shift in zeros
                SHL     4, R5
                MOVE    ADF_FL_BADDR_LO, R8
                MOVE    @R8, R6                 ; R6: byte addr, low word
                MOVE    R6, R7
                AND     0xFFFB, SR              ; clear C: shift in zeros
                SHR     12, R7
                OR      R7, R5                  ; R5: 4k window number
                MOVE    M2M$RAMROM_4KWIN, R8    ; (device already selected)
                MOVE    R5, @R8
                MOVE    R6, R7
                AND     0x0FFF, R7
                ADD     M2M$RAMROM_DATA, R7     ; R7: source pointer
                MOVE    ADF_FLUSH_CHUNK, R5     ; R5: byte countdown
_FADF_WLOOP     MOVE    ADF_FDH, R8
                MOVE    @R7++, R9               ; one file byte per word
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                SUB     1, R5
                RBRA    _FADF_WLOOP, !Z

                ; persist the chunk NOW: the FAT32 hardware sector buffer is
                ; shared with every other SD user (e.g. the OSM settings
                ; save) - a dirty buffered sector left across time slices
                ; would be clobbered by them. This costs nothing: the chunk
                ; is exactly one sector, which gets written exactly once
                ; either way - just earlier.
                MOVE    ADF_FDH, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z

                MOVE    ADF_FL_BADDR_LO, R8     ; advance the byte address
                ADD     ADF_FLUSH_CHUNK, @R8
                MOVE    ADF_FL_BADDR_HI, R8
                ADDC    0, @R8
                MOVE    ADF_FL_REMAIN, R8
                SUB     ADF_FLUSH_CHUNK, @R8
                RBRA    _FADF_RET1, !Z          ; track not finished yet

                MOVE    ADF_FL_STATE, R8        ; track done: session closed
                MOVE    0, @R8
                MOVE    M2M$RAMROM_4KWIN, R8    ; more dirty tracks?
                MOVE    ADF_WBC_4KWIN, @R8
                MOVE    ADF_WBC_STAT, R8
                MOVE    @R8, R8
                AND     1, R8
                RBRA    _FADF_RET0, Z
                RBRA    _FADF_RET1, 1

_FADF_DISCARD   MOVE    ADF_WBC_DIRTY0, R5      ; drop unflushable dirty bits
                MOVE    11, R6
_FADF_DISC1     MOVE    0xFFFF, @R5++
                SUB     1, R6
                RBRA    _FADF_DISC1, !Z
                RBRA    _FADF_RET0, 1

_FADF_RET0      XOR     R8, R8
                RBRA    _FADF_RET, 1
_FADF_RET1      MOVE    1, R8
_FADF_RET       MOVE    R0, R9                  ; restore R9..R12
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

_FADF_FATAL     MOVE    ERR_ADF_FLUSH, R8       ; R9 holds the FAT32 error
                RBRA    FATAL, 1

; ----------------------------------------------------------------------------
; HDMI Filter dispatch
; (ported from C64MEGA65 V6, CORE/m2m-rom/m2m-rom.asm)
; ----------------------------------------------------------------------------

; LOAD_HDMI_FILTER: Read the saved HDMI Filter selection from M2M$CFM_DATA
; and configure ascal accordingly. Called from PREP_START (boot) and
; OSM_SEL_POST (runtime). Eight options, single-select: exactly one of the
; AEXP_OSM_FLT_* bits is set at any time -- OPTM_G_STDSEL in config.vhd
; guarantees a default ("Lanczos") if the saved SD config file is missing
; or empty.
;
; Two execution shapes, both encoded in HDMI_FLT_TABLE rows
; (OSM_bit, ASCAL_MODE_word, H_label, V_label):
;
;   * Native modes (No Filter / Sharp Bilinear / Bicubic) -> write the
;                  matching mode word (NEAREST / SBILINEAR / BICUBIC) to
;                  M2M$ASCAL_MODE. The H/V labels are 0 sentinels: we skip
;                  the polyphase RAM write entirely and let ascal run its
;                  built-in scaler datapath.
;   * Polyphase modes (Smooth / Lanczos / Scanlines / CRT (S-Video) /
;                  CRT (Composite)) -> write POLYPHASE then push the
;                  (H_label, V_label) pair into the ascal polyphase RAM
;                  via M2M$LOAD_POLYPHASE.
;
; This routine assumes ASCAL_USAGE=1 (AUSE_CUSTOM) in config.vhd: ASCAL_INIT
; in M2M/rom/gencfg.asm always clears the M2M$CSR ascal-autosync bit first
; and only re-sets it for AUSE_AUTO, so with AUSE_CUSTOM the M2M$ASCAL_MODE
; register stays firmware-writable. If a future core sets ASCAL_USAGE back
; to 2 (AUSE_AUTO), the mode writes below silently no-op.
;
; Input:  None
; Output: R8 = 0, R9 = 0 on success
LOAD_HDMI_FILTER INCRB
                MOVE    HDMI_FLT_TABLE, R0
                MOVE    8, R1                   ; option count

_LHF_LOOP       MOVE    @R0++, R8               ; R8 = OSM bit for this option
                RSUB    M2M$GET_SETTING, 1
                CMP     1, R9                   ; selected?
                RBRA    _LHF_FOUND, Z           ; yes -> apply this row
                ADD     3, R0                   ; no -> skip MODE, H, V
                SUB     1, R1
                RBRA    _LHF_LOOP, !Z

                ; Defensive fallback: no bit set. Force the Lanczos preset
                ; (polyphase mode + Lanczos2_12 on both axes), matching the
                ; config.vhd OPTM_G_STDSEL default.
                MOVE    M2M$ASCAL_MODE, R2
                MOVE    M2M$ASCAL_POLYPHASE, @R2
                MOVE    LANCZOS2_12,    R8
                MOVE    LANCZOS2_12,    R9
                RSUB    M2M$LOAD_POLYPHASE, 1
                RBRA    _LHF_RET, 1

_LHF_FOUND      MOVE    @R0++, R3               ; R3 = ASCAL_MODE word
                MOVE    M2M$ASCAL_MODE, R2
                MOVE    R3, @R2                 ; write mode register
                MOVE    @R0++, R8               ; R8 = H label (0 = sentinel)
                MOVE    @R0,   R9               ; R9 = V label (0 = sentinel)
                CMP     0, R8                   ; native-mode sentinel?
                RBRA    _LHF_RET, Z             ; yes -> done, no RAM write
                RSUB    M2M$LOAD_POLYPHASE, 1

_LHF_RET        XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; Filter table: (OSM_bit, ASCAL_MODE_word, H_label, V_label) per option, in
; OPTM_ITEMS display order. The first three rows use ascal native modes
; (NEAREST / SBILINEAR / BICUBIC); their H and V are 0 sentinels so the
; dispatcher skips the polyphase RAM write for them. The remaining five
; rows all select polyphase (mode 100) and provide real coefficient table
; labels.
;
; See CORE/m2m-rom/video_filters/README.md for per-blob notes and
; CORE/vhdl/config.vhd for the OPTM_ITEMS / OPTM_GROUPS structure.
HDMI_FLT_TABLE  .DW AEXP_OSM_FLT_NO_FILTER,     M2M$ASCAL_NEAREST,   0,                   0
                .DW AEXP_OSM_FLT_SHARP,         M2M$ASCAL_SBILINEAR, 0,                   0
                .DW AEXP_OSM_FLT_BICUBIC,       M2M$ASCAL_BICUBIC,   0,                   0
                .DW AEXP_OSM_FLT_SMOOTH,        M2M$ASCAL_POLYPHASE, GS_SHARPNESS_050,    GS_SHARPNESS_050
                .DW AEXP_OSM_FLT_LANCZOS,       M2M$ASCAL_POLYPHASE, LANCZOS2_12,         LANCZOS2_12
                .DW AEXP_OSM_FLT_SCANLINES,     M2M$ASCAL_POLYPHASE, LANCZOS2_12,         SCAN_BR_110_80

                ; Both CRT rows reuse SCAN_BR_110_80 as the V file (same as
                ; Scanlines mode). CRT_Sim_*_V is a deep ~40% mid-phase
                ; plateau designed to be combined with the MiSTer gamma LUT
                ; + shadow mask; M2M supports neither, so standalone the
                ; plateau crushes bright content into a dark band. The
                ; Composite vs S-Video character lives entirely in the H
                ; file (Composite has heavy horizontal blur, S-Video has
                ; mild softening), so swapping only the V file preserves the
                ; perceptual distinction while restoring near-unity mean
                ; brightness.
                .DW AEXP_OSM_FLT_CRT_SVIDEO,    M2M$ASCAL_POLYPHASE, CRT_SIM_SVIDEO_H,    SCAN_BR_110_80
                .DW AEXP_OSM_FLT_CRT_COMPOSITE, M2M$ASCAL_POLYPHASE, CRT_SIM_COMPOSITE_H, SCAN_BR_110_80

; ----------------------------------------------------------------------------
; M2M$LOAD_POLYPHASE  Load a (horizontal, vertical) filter pair into the
;                    ascal polyphase coefficient RAM. ASCAL_FILTER_LEN
;                    (= 0x100, defined in M2M/rom/filters.asm) words are
;                    copied into the H slot at M2M$ASCAL_PP_HORIZ and another
;                    0x100 words into the V slot at M2M$ASCAL_PP_VERT,
;                    through QNICE device M2M$ASCAL_PPHASE.
;
;                    Safe to call at boot or at runtime from a core OSM
;                    callback. Does NOT touch ascal mode bits, does NOT reset
;                    the core.
;
;                    BACKPORT from M2M V2.1 (M2M/rom/tools.asm): our M2M
;                    V2.0.1 framework does not ship this routine and M2M/rom
;                    firmware stays unmodified in this repo, so it lives here
;                    (the only sanctioned M2M/ change is the VHDL interlace
;                    feature, tagged M2M-UPSTREAM interlace). When the
;                    framework is upgraded to V2.1+, delete this copy -- the
;                    assembler will flag the duplicate label -- and re-apply
;                    or upstream the M2M-UPSTREAM interlace patch.
;
; Input:  R8 = pointer to a 256-word horizontal coefficient table
;         R9 = pointer to a 256-word vertical   coefficient table
; Output: -
; ----------------------------------------------------------------------------

M2M$LOAD_POLYPHASE  SYSCALL(enter, 1)

                ; select the ascal Polyphase RAM device
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    M2M$ASCAL_PPHASE, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0

                MOVE    ASCAL_FILTER_LEN, R10

                ; copy horizontal filter (R8 already = H label) to PP_HORIZ
                MOVE    R9, R0                  ; stash V pointer
                MOVE    M2M$RAMROM_DATA, R9
                ADD     M2M$ASCAL_PP_HORIZ, R9
                SYSCALL(memcpy, 1)

                ; copy vertical filter (R0 = stashed V label) to PP_VERT.
                MOVE    R0, R8
                MOVE    M2M$RAMROM_DATA, R9
                ADD     M2M$ASCAL_PP_VERT, R9
                SYSCALL(memcpy, 1)

                SYSCALL(leave, 1)
                RET

; Filter coefficient blobs for the polyphase-based options that the M2M
; framework does not already link: LANCZOS2_12 and SCAN_BR_110_80 come in
; via M2M/rom/filters.asm (included from M2M/rom/shell.asm); the three blobs
; below are core-local copies from C64MEGA65 V6 (see video_filters/README.md).
#include "video_filters/GS_Sharpness_050.asm"
#include "video_filters/CRT_Sim_Composite_H.asm"
#include "video_filters/CRT_Sim_SVideo_H.asm"

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; Menu group id of the " ADF:%s" mount item - MUST match OPTM_G_ADF in
; config.vhd (the Shell passes the plain group id to the callbacks)
OPTM_G_ADF      .EQU    1

; OSM menu constants are autogenerated by make_rom.sh (like in C64MEGA65):
; the AEXP_OSM_* line numbers are scraped from the C_MENU_* constants in
; ../vhdl/mega65.vhd and the AEXP_OPTM_G_* group ids from the OPTM_G_*
; constants in ../vhdl/config.vhd -- no hardcoded menu indexes here.
#include "osm_const.asm"

; ADF file extension (needs to be upper case)
ADF_FILE_EXT    .ASCII_W ".ADF"

; ADF write-back CSR (WBC): device AEXP_DEV_ADF (autogenerated into
; osm_const.asm from globals.vhd), 4k window 0xFFFE - register map defined
; in CORE/vhdl/adf_mount_wrapper.vhd (keep in sync!)
ADF_WBC_4KWIN   .EQU    0xFFFE              ; the write-back CSR window
ADF_WBC_CTRL    .EQU    0x7000              ; bit 0: WR_EN (df0 writable)
ADF_WBC_STAT    .EQU    0x7001              ; bit 0: any_dirty  bit 1: flush_start
ADF_WBC_ATDELAY .EQU    0x7002              ; anti-thrashing delay in ms
ADF_WBC_DIRTY0  .EQU    0x7010              ; ..0x701A: dirty bitmap, W1C
ADF_TRACK_BYTES .EQU    5632                ; 11 sectors x 512 bytes
ADF_FLUSH_CHUNK .EQU    512                 ; bytes per background time slice

; MEGA65 battery RTC (issue #13): framework device C_DEV_RTC (qnice_wrapper.vhd)
; exposing the QNICE date/time interface of M2M/vhdl/i2c/rtc_controller.vhd. The
; core reads the same time at $DC0000 (Minimig MSM6242B). The window offset
; equals the register address (keep in sync with rtc_controller.vhd).
AEXP_DEV_RTC    .EQU    0x0006              ; framework RTC device (C_DEV_RTC)
RTC_4KWIN       .EQU    0x0000              ; RTC decodes addr[7:0] only
RTC_MINUTES     .EQU    0x7002              ; internal timer: minutes (BCD, RO)
RTC_COMMAND     .EQU    0x7008              ; b0 busy(RO) b1 read b2 write b3 running
RTC_CMD_STOP    .EQU    0x0000              ; stop the internal timer
RTC_CMD_RESYNC  .EQU    0x000A              ; b1 read RTC->internal + b3 keep running

; Warning: file size out of the valid ADF range
WRN_ADF_SIZE    .ASCII_P "\n\nThis is not a valid ADF disk image:\n"
                .ASCII_P "the file size must be 901,120 bytes\n"
                .ASCII_P "(880 KB standard ADF; 81..83-track over-\n"
                .ASCII_P "dumps up to 934,912 bytes are accepted)."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; Warning: could not write back the current disk before mounting a new one
WRN_ADF_BUSY    .ASCII_P "\n\nUnsaved changes on the current disk\n"
                .ASCII_P "could not be written back because the\n"
                .ASCII_P "Amiga keeps writing to the drive.\n"
                .ASCII_P "Stop the disk activity, then try again."
                .ASCII_W "\n\nPress SPACE to continue.\n"

; Fatal: SD card write failed during the ADF write-back
ERR_ADF_FLUSH   .ASCII_W "ADF write-back: writing to the SD card failed.\n"

; This needs to be the last thing before the "Variables" sections starts
END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

;
; add your own variables here
;

; ADF write-back state (see HANDLE_CORE_IO / FLUSH_ADF_STEP)
ADF_FDH         .BLOCK FAT32$FDH_STRUCT_SIZE    ; our own snapshot of the
                                                ; mounted ADF file handle:
                                                ; HANDLE_RM_FILE1 is re-opened
                                                ; by the Shell for the NEXT
                                                ; load, the snapshot stays
                                                ; valid until SD-card change
ADF_FDH_VALID   .BLOCK 1                        ; 1: ADF_FDH is usable
ADF_SD_SLOT     .BLOCK 1                        ; active SD slot at arm time
ADF_MOUNT_SEEN  .BLOCK 1                        ; 1: armed or blocked; 0: a
                                                ; fresh PARSEST=READY may arm
ADF_FL_STATE    .BLOCK 1                        ; 0: idle  1: track session
ADF_FL_REMAIN   .BLOCK 1                        ; bytes left in session track
ADF_FL_BADDR_LO .BLOCK 1                        ; session byte address within
ADF_FL_BADDR_HI .BLOCK 1                        ; image and file (32 bit)

; Battery-RTC reseed state (see HANDLE_CORE_IO / RTC_STEP, issue #13)
RTC_LAST_MIN    .BLOCK 1                        ; last internal minute seen by
                                                ; RTC_STEP; 0xFFFF = none yet

; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 29696, then you write 29696-1024=28672
; instead, but when doing the sanity check calculations, you use 29696
MENU_HEAP_SIZE  .EQU 1024

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 6144                       ; 7168 - 1024 = 6144
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 28672                      ; 29696 - 1024 = 28672
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 29696 words to HEAP which
; is currently 0xXXXX and subtract the result from 0xFEE0. This yields
; currently a stack size of more than 1.5k words, which is sufficient
; for this program.

                .ORG    0xFEE0                  ; TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
