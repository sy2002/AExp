; ****************************************************************************
; Amiga for Mega65 (AExp) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
;
; The execution starts at the label START_FIRMWARE.
;
; done by sy2002 in 2026 and licensed under GPL v3
; ****************************************************************************

; NOTE on comment style: this file is fed to the C preprocessor (see the asm
; wrapper in M2M/QNICE/assembler, which runs cc -xc -E), so an apostrophe or a
; double-quote is tokenized even inside a ; comment. So, in comments:
;   * avoid genitive apostrophes; use an of-construction instead (the
;     sub-activity of the menu selection, not the possessive apostrophe-s form);
;   * never split a double-quoted string across two lines (keep it on one line;
;     a balanced pair on ONE line is fine).
; Either slip only yields a harmless missing-terminating preprocessor warning.

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

                ; Run the Shell and before that, initialize:
                ; a) ADF write-back state. It cannot live in PREP_START, as
                ;    HANDLE_CORE_IO can already be reached during boot
                ;    (HANDLE_IO is polled from boot-time wait loops), and RAM
                ;    variables are undefined at power-on.
                ; b) Screen-centering feature
                ; c) Real-Time-Clock connector
                ; d) Live Hardware Floppy status line
START_FIRMWARE  RSUB    ADF_WB_INIT, 1
                RSUB    SCR_INIT, 1
                RSUB    RTC_INIT, 1
                RSUB    HWF_OSM_INIT, 1
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
                MOVE    R8, R1                  ; R1: keep the directory entry
                MOVE    R11, R8                 ; one of the three mount items?
                RSUB    IS_ADF_GROUP, 1         ; (branch on C before anything
                RBRA    _FFILES_ADF, C          ; else can touch the flags)
                MOVE    R1, R8
                RBRA    _FFILES_RET_0, 1
_FFILES_ADF     MOVE    R1, R8                  ; restore the directory entry

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
                MOVE    R8, R5                  ; R5: keep the new file handle
                MOVE    R10, R8                 ; one of the three mount items?
                RSUB    IS_ADF_GROUP, 1         ; (branch on C before anything
                RBRA    _PREP_LI_ADF, C         ; else can touch the flags)
                MOVE    R5, R8
                RBRA    _PREP_LI_OK, 1
_PREP_LI_ADF    MOVE    R9, R6                  ; R6: the drive 0..2 behind the
                MOVE    R5, R8                  ; group id; restore the handle

                ; Every gate below is PER DRIVE. The flush and the disarm act
                ; on the drive that is being (re)loaded, the size gate keeps an
                ; oversized file from streaming past the HyperRAM pool of that
                ; drive, and the duplicate gate keeps the same file out of two
                ; drives at once.
                ;
                ; BEFORE anything else, force-flush all unsaved writes of the
                ; disk currently in THIS drive - the streaming that follows
                ; overwrites its HyperRAM image, and the Shell has already
                ; re-opened HNDL_RM_FILES[drive] for the NEW file (which is
                ; exactly why the flush works from the own FDH snapshot of that
                ; drive, see FLUSH_ADF_STEP). Bounded to >4 full disks of
                ; chunks so an Amiga that re-dirties tracks forever cannot
                ; starve the OSM; in that case we bail out with a friendly,
                ; non-fatal message (the Shell re-opens the file browser).
                MOVE    R8, R3                  ; R3: handle of the new file
                MOVE    8192, R4                ; R4: chunk budget
_PREP_LI_FL     MOVE    1, R8                   ; forced step (ignore the
                MOVE    R6, R9                  ; anti-thrashing gate)
                RSUB    FLUSH_ADF_STEP, 1
                CMP     ADF_FL_IDLE, R8         ; clean and idle?
                RBRA    _PREP_LI_FLD, Z
                SUB     1, R4
                RBRA    _PREP_LI_FL, !Z
                MOVE    1, R8                   ; budget exhausted: bail out
                MOVE    WRN_ADF_BUSY, R9
                DECRB
                RET

                ; The mount flow OWNS the arm state: disarm the write-back of
                ; THIS drive here and let the PARSEST=READY of the NEW mount
                ; re-arm it with a fresh handle snapshot. HANDLE_CORE_IO alone
                ; cannot do that: the whole load runs without HANDLE_IO
                ; polling, so the READY -> LOADING -> READY transient of a
                ; re-mount is invisible to it - without this disarm, flushes
                ; after a disk swap would write the new disk into the OLD file.
_PREP_LI_FLD    MOVE    R6, R8
                RSUB    ADF_DISARM, 1           ; WR_EN := 0 until the new
                MOVE    R3, R8                  ; mount is complete; restore
                                                ; the file handle

_PREP_LI_SIZE   MOVE    R8, R0                  ; R0: file size low word
                MOVE    R8, R1                  ; R1: file size high word
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    @R0, R0
                ADD     FAT32$FDH_SIZE_HI, R1
                MOVE    @R1, R1

                ; Valid range: C_ADF_MIN_SIZE .. C_ADF_MAX_SIZE from
                ; globals.vhd, scraped into globals.asm by make_rom.sh so this
                ; gate can never drift from the HyperRAM map and the track
                ; engine geometry. A plain unsigned 32-bit range compare,
                ; high word first: QNICE CMP sets N for an unsigned src > dst
                ; (V is the signed one).
                CMP     ADF_MIN_SIZE_HI, R1     ; minimum > file: too small
                RBRA    _PREP_LI_BAD, N
                RBRA    _PREP_LI_MAX, !Z        ; minimum < file: minimum met
                CMP     ADF_MIN_SIZE_LO, R0     ; equal high word: compare low
                RBRA    _PREP_LI_BAD, N

_PREP_LI_MAX    CMP     R1, ADF_MAX_SIZE_HI     ; file > maximum: too big
                RBRA    _PREP_LI_BAD, N
                RBRA    _PREP_LI_DUP, !Z        ; file < maximum: maximum met
                CMP     R0, ADF_MAX_SIZE_LO     ; equal high word: compare low
                RBRA    _PREP_LI_BAD, N

                ; The same image file may not sit in two drives at once. Each
                ; drive holds its OWN copy of the image in HyperRAM, so both
                ; would collect their own writes and the drive that flushes
                ; last would silently overwrite what the other one saved. We
                ; refuse the second mount rather than let that happen: the
                ; drive simply stays empty (the Shell has already unmounted it
                ; with ST_LDNG) and the user gets the file browser back.
_PREP_LI_DUP    MOVE    R6, R9
                RSUB    ADF_DUP_CHECK, 1        ; (branch on C before anything
                RBRA    _PREP_LI_DUPE, C        ; else can touch the flags)

_PREP_LI_OK     XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                DECRB
                RET

_PREP_LI_BAD    MOVE    1, R8                   ; error: invalid size
                MOVE    WRN_ADF_SIZE, R9
                DECRB
                RET

_PREP_LI_DUPE   MOVE    1, R8                   ; error: already in a drive
                MOVE    WRN_ADF_DUP, R9
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

                ; Apply the screen-centering offsets (HDMI ascal window) from
                ; /amiga/aexp_screen.cfg (zeros if absent) before the core
                ; un-resets so the first frame is already positioned.
                RSUB    LOAD_SCREEN_OFFSETS, 1

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

                ; issue #16: the sub-activity of the menu selection (file
                ; browser / help viewer) has returned - drop the gate-4 flag so
                ; SPACE-unmount works again. Reached on EVERY non-fatal path out
                ; of OPTM_CB_SEL (incl. the CLOSE early-out via _OPTMCB_RET), so
                ; the flag can never stick at 1. R8 (the selected group, used
                ; below) is untouched: R0 is bank-local after the INCRB.
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    0, @R0

                ; HDMI Filter selection changed: re-push the matching (H, V)
                ; coefficient pair into the ascal polyphase RAM. NO core
                ; reset -- only the coefficient RAM content changes; the
                ; Amiga keeps running. The user sees the new filter from the
                ; next frame.
                CMP     AEXP_OPTM_G_FILTER, R8
                RBRA    _OSM_SP_DRV, !Z
                RSUB    LOAD_HDMI_FILTER, 1
                RBRA    _OSM_SEL_POST_R, 1

                ; "Reload Screen Config" pressed. This is a MOMENTARY action,
                ; not an on/off toggle (issue #19): show <Loading Screen Config>
                ; on the line of the item for the ~1-2 s the SD re-mount +
                ; reload takes -- the OSM is frozen meanwhile because QNICE
                ; serves the menu synchronously -- then repaint the original
                ; label with no "=" checkmark left behind.
                ; Drive Settings: keep the "Drives" count radio and the three
                ; per-drive mode radios consistent. The HDL decode is defensive
                ; about an inconsistent combination, but the MENU must not show
                ; one: a drive beyond the count has to sit on its "Off" item,
                ; because that item is what the count radio swaps in (menu
                ; dependency), and it is also what hides the two lines of that drive
                ; in the main menu. And only one physical mechanism exists, so
                ; "Hardware Floppy" has to be stolen from the other drives.
                ; Everything else - the Amiga cold boot, the twin-line
                ; visibility, the live redraw - happens in the HDL and in the
                ; framework; this is purely about the model staying sane.
_OSM_SP_DRV     CMP     AEXP_OPTM_G_DRIVES, R8
                RBRA    _OSM_SP_DRVM, !Z
                RSUB    DRV_ENFORCE_COUNT, 1
                RSUB    DRV_EJECT_GONE, 1
                RBRA    _OSM_SEL_POST_R, 1

_OSM_SP_DRVM    CMP     AEXP_OPTM_G_DF0MODE, R8
                RBRA    _OSM_SP_DRVM1, !Z
                XOR     R8, R8                    ; R8: the drive that changed
                RBRA    _OSM_SP_DRVS, 1
_OSM_SP_DRVM1   CMP     AEXP_OPTM_G_DF1MODE, R8
                RBRA    _OSM_SP_DRVM2, !Z
                MOVE    1, R8
                RBRA    _OSM_SP_DRVS, 1
_OSM_SP_DRVM2   CMP     AEXP_OPTM_G_DF2MODE, R8
                RBRA    _OSM_SP_SCR, !Z
                MOVE    2, R8
_OSM_SP_DRVS    RSUB    DRV_STEAL_HW, 1
                RSUB    DRV_EJECT_GONE, 1
                RBRA    _OSM_SEL_POST_R, 1

_OSM_SP_SCR     CMP     AEXP_OPTM_G_SCRRELOAD, R8
                RBRA    _OSM_SEL_POST_R, !Z

                ; Paint the "loading" label. OPTM_CUR_SEL is the flat index of
                ; the highlighted item; the menu is flat-indexed but on-screen
                ; rows collapse submenus, so translate to the visible row first
                ; (_OPTM_R_F2M_O is the same "from the outside" helper OPTM_SET
                ; / OPTM_SELECT use). Then print across the full content width
                ; at the left edge (x = OPTM_X+1, y = OPTM_Y+row+1).
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_F_MS_SLCT, R9      ; fatal-context (unused on OK)
                RSUB    _OPTM_R_F2M_O, 1        ; R8 = row; C=1 -> off this level
                RBRA    _OSP_SCR_RM, C          ; (defensive) skip paint if so
                MOVE    OPTM_Y, R10
                MOVE    @R10, R10
                ADD     R8, R10
                ADD     1, R10                  ; R10 = screen y (+1 for frame)
                MOVE    OPTM_X, R9
                MOVE    @R9, R9
                ADD     1, R9                   ; R9 = screen x (+1 for frame)
                MOVE    SCR_LOADING_STR, R8
                RSUB    SCR$PRINTSTRXY, 1

                ; The user may have pulled the SD card to write a new file with
                ; the python tool; the shared SD controller is then de-negotiated
                ; until a re-mount runs SD$RESET (and a same-slot tray swap does
                ; NOT reliably raise SD_CHANGED on R3, so we cannot gate on it).
                ; Re-mount CONFIG_DEVH here, mirroring the remount of the file
                ; browser, so the reload reads the CURRENT card and not the
                ; stale boot mount. Safe for config-save: write-back is gated on
                ; CONFIG_FILE (untouched), and re-mounting keeps the bookkeeping
                ; of CONFIG_DEVH consistent with the freshly reset controller.
_OSP_SCR_RM     MOVE    CONFIG_DEVH, R8
                CMP     0, @R8                  ; any SD device mounted at all?
                RBRA    _OSP_SCR_LOAD, Z        ; none -> let LOAD zero the table
                RSUB    WAIT1SEC, 1             ; debounce a just-reinserted card
                MOVE    CONFIG_DEVH, R8
                MOVE    1, R9                   ; partition #1 (framework-wide)
                SYSCALL(f32_mnt_sd, 1)          ; SD$RESET + re-read geometry;
                                                ; LOAD then re-checks status
_OSP_SCR_LOAD   RSUB    LOAD_SCREEN_OFFSETS, 1

                ; Momentary reset: clear the single-select state everywhere so
                ; no "=" ever sticks. M2M$FORCE_MENU clears the QNICE setting
                ; register bit AND the in-memory selection of the menu (and
                ; erases the on-screen marker); OPTM_SHOW then repaints every
                ; label (ours reverts to "Reload Screen Config", markerless) and
                ; OPTM_SELECT restores the cursor highlight. OPTM_CUR_SEL is
                ; untouched by these calls, so it still points at our item.
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                XOR     R9, R9                  ; 0 = unselected
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1
                RBRA    _OSM_SEL_POST_R, 1

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

                ; issue #16: a sub-activity of a menu selection is about to run
                ; (the file browser, its SD-mount retry / "press Space"
                ; acknowledgments, or the WHS help viewer) and it polls
                ; HANDLE_IO. Raise the gate-4 flag so HANDLE_UNMOUNT_KEY does
                ; not mistake a SPACE inside one of those sub-screens - e.g.
                ; Return-to-replace on the still-mounted ' ADF:' line - for an
                ; unmount request. Cleared again in OSM_SEL_POST, which brackets
                ; the whole select-callback body (options.asm OPTM_CB_SEL).
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    1, @R0

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
; a dirty bitmap behind window ADF_WBC_4KWIN of device AEXP_DEV_ADF0 and runs
; the vdrives-style anti-thrashing countdown. The firmware side below mirrors
; the proven C64MEGA65 vdrives discipline (background flushing driven from
; HANDLE_IO, chunked to stay responsive, still-open FAT32 handle, errors are
; fatal) against our non-vdrives device. Full design:
; doc/developers/floppy-adf.md
;
; SCOPE: every one of the three simulated drives has its own write-back. The
; hardware is already per drive - each adf_mount_wrapper instance carries its
; own WBC (WR_EN, dirty bitmap, anti-thrash countdown) behind its own device id
; - so the firmware only has to address the right device and keep its own state
; per drive. All of it is therefore an array indexed by the Amiga drive unit
; 0..2, which is also the manual CRT/ROM id and thus the index into the
; HANDLE_RM_FILE handles of the Shell: drive n loads through HNDL_RM_FILES[n].
; The three tables ADF_DEV_TAB / ADF_FDH_TAB / ADF_GRP_TAB are the only place
; that knows how a drive maps to a device, a handle snapshot and a menu group.
;
; The three consequences that make this safe (see also the section 5a arm-state
; invariant of .research/INTEGRATION-SPEC-floppy-adf-write.md, which now has to
; hold PER DRIVE):
;
;   * Each drive keeps its OWN FDH snapshot. A flush of drive n can only ever
;     reach the file that was mounted into drive n - this is what stops the
;     cross-drive corruption of one drive being written into the file of
;     another, which a single shared handle would produce the moment a second
;     drive is armed.
;   * The arming is bound to the drive whose device CSR reported the mount, and
;     the disarm to the drive whose menu group triggered PREP_LOAD_IMAGE.
;   * The same image file may not be mounted into two drives at once: both
;     drives would hold their own HyperRAM copy and the later flush of one
;     would silently overwrite what the other wrote. PREP_LOAD_IMAGE rejects
;     the second mount (see ADF_DUP_CHECK).
;
; The background flush serves ONE drive per time slice, round-robin, so three
; armed drives cost exactly as much main-loop time as one did.
; ----------------------------------------------------------------------------

; ADF_SEL_WBC: point the RAMROM window at the write-back CSR of one drive.
;
; Input:  R8: drive 0..2
; Output: none; all registers preserved (the RAMROM selection is changed -
;         every caller either owns it or restores it, see HANDLE_CORE_IO)
ADF_SEL_WBC     INCRB
                MOVE    ADF_DEV_TAB, R0
                ADD     R8, R0
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    @R0, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    ADF_WBC_4KWIN, @R1
                DECRB
                RET

; ADF_WIPE_DIRTY: drop the whole dirty bitmap of one drive (write-1-to-clear).
;
; Used whenever the retained file handle of that drive became unusable: the
; tracks can no longer be written anywhere sensible, and leaving the bits set
; would make a LATER mount flush them into a different file.
;
; Input:  R8: drive 0..2
; Output: none; all registers preserved
ADF_WIPE_DIRTY  INCRB
                RSUB    ADF_SEL_WBC, 1
                MOVE    ADF_WBC_DIRTY0, R0
                MOVE    ADF_WBC_DIRTY_W, R1
_AWD_L          MOVE    0xFFFF, @R0++
                SUB     1, R1
                RBRA    _AWD_L, !Z
                DECRB
                RET

; ADF_DISARM: disarm the write-back of one drive.
;
; Invalidates the handle snapshot, aborts a running flush session, re-opens the
; arming edge for the next mount and takes WR_EN away so the track engine
; announces that unit write-protected again. Does NOT touch the dirty bitmap -
; the callers decide whether the pending tracks are still flushable (mount and
; eject flush first) or have to be dropped (ADF_WIPE_DIRTY).
;
; Input:  R8: drive 0..2
; Output: none; all registers preserved
ADF_DISARM      INCRB
                MOVE    ADF_FDH_VALID, R0
                ADD     R8, R0
                MOVE    0, @R0
                MOVE    ADF_MOUNT_SEEN, R0      ; 0: a fresh READY may arm
                ADD     R8, R0
                MOVE    0, @R0
                MOVE    ADF_FL_STATE, R0
                ADD     R8, R0
                MOVE    0, @R0
                RSUB    ADF_SEL_WBC, 1
                MOVE    ADF_WBC_CTRL, R0
                MOVE    0, @R0
                DECRB
                RET

; ADF_DUP_CHECK: is the file behind a fresh file handle already mounted into
; ANOTHER drive?
;
; Two drives holding the same image file is a silent data-loss trap: each drive
; streams its OWN copy into its OWN HyperRAM pool, both collect Amiga writes
; independently, and whichever drive flushes last overwrites what the other one
; saved. The file is identified by its FAT32 start cluster, which is unique per
; file on a card. Comparing that alone is enough because every ARMED drive was
; verified to sit on the currently active SD slot by the guards of
; HANDLE_CORE_IO, and the fresh handle was just opened on that same slot. A
; drive whose write-back is not armed cannot write and is therefore skipped -
; its file identity is not retained anywhere either.
;
; Input:  R8: the fresh file handle
;         R9: the drive that is being loaded (it is skipped)
; Output: C=1 and R9 = the other drive, if that drive holds the same file;
;         C=0 otherwise. R8 preserved.
ADF_DUP_CHECK   INCRB
                MOVE    R8, R0                  ; R0: the fresh handle
                MOVE    R9, R1                  ; R1: the drive being loaded
                MOVE    R0, R6
                ADD     FAT32$FDH_START_CLUS_LO, R6
                MOVE    @R6, R2                 ; R2/R3: its start cluster
                MOVE    R0, R6
                ADD     FAT32$FDH_START_CLUS_HI, R6
                MOVE    @R6, R3
                MOVE    @R0, R7                 ; R7: its device handle

                MOVE    R2, R6                  ; start cluster 0 means an
                OR      R3, R6                  ; empty file and is not a
                RBRA    _ADC_NO, Z              ; usable identity (an ADF never
                                                ; gets here - the size gate ran
                                                ; first - but 0 == 0 must not
                                                ; be read as "the same file")

                XOR     R4, R4                  ; R4: drive under inspection
_ADC_D          CMP     R4, R1
                RBRA    _ADC_N, Z               ; skip the drive being loaded
                MOVE    ADF_FDH_VALID, R5
                ADD     R4, R5
                CMP     0, @R5
                RBRA    _ADC_N, Z               ; not armed: cannot write, and
                                                ; no file identity is retained
                MOVE    ADF_FDH_TAB, R5
                ADD     R4, R5
                MOVE    @R5, R5                 ; R5: the own FDH of that drive
                CMP     @R5, R7                 ; same device handle?
                RBRA    _ADC_N, !Z
                MOVE    R5, R6
                ADD     FAT32$FDH_START_CLUS_LO, R6
                CMP     @R6, R2
                RBRA    _ADC_N, !Z
                MOVE    R5, R6
                ADD     FAT32$FDH_START_CLUS_HI, R6
                CMP     @R6, R3
                RBRA    _ADC_N, !Z
                MOVE    R4, R9                  ; the very same file
                MOVE    R0, R8                  ; (R8 unchanged for the caller)
                OR      0x0004, SR              ; set Carry
                DECRB
                RET

_ADC_N          ADD     1, R4
                CMP     ADF_DRIVES, R4
                RBRA    _ADC_D, !Z
_ADC_NO         MOVE    R0, R8                  ; (R8 unchanged for the caller)
                AND     0xFFFB, SR              ; clear Carry: not a duplicate
                DECRB
                RET

; ADF_WB_INIT: called once from START_FIRMWARE, before the Shell starts.
; Zero-initializes the write-back state of all three drives and loads
; VD_ANTI_THRASHING_DELAY from config.vhd into each WBC hardware countdown
; register (mirrors the vdrives VD_INIT pattern, M2M/rom/vdrives.asm).
ADF_WB_INIT     INCRB

                MOVE    M2M$RAMROM_DEV, R0      ; anti-thrashing delay (ms)
                MOVE    M2M$CONFIG, @R0         ; from config.vhd
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    M2M$CFG_GENERAL, @R0
                MOVE    M2M$CFG_VD_AT_DELAY, R0
                MOVE    @R0, R1                 ; R1: the delay, in ms

                XOR     R2, R2                  ; R2: drive 0..2
_AWBI_D         MOVE    ADF_FDH_VALID, R3
                ADD     R2, R3
                MOVE    0, @R3
                MOVE    ADF_MOUNT_SEEN, R3
                ADD     R2, R3
                MOVE    0, @R3
                MOVE    ADF_FL_STATE, R3
                ADD     R2, R3
                MOVE    0, @R3

                MOVE    R2, R8                  ; ... into the WBC register of
                RSUB    ADF_SEL_WBC, 1          ; this drive
                MOVE    ADF_WBC_ATDELAY, R3
                MOVE    R1, @R3

                ADD     1, R2
                CMP     ADF_DRIVES, R2
                RBRA    _AWBI_D, !Z

                MOVE    ADF_FL_RR, R0           ; round-robin flush pointer
                MOVE    0, @R0

                ; issue #16 unmount state: no SPACE seen yet and no menu
                ; sub-activity running. Seeded here (like the rest of the ADF
                ; state) because HANDLE_IO can poll HANDLE_UNMOUNT_KEY during
                ; boot wait loops, before RAM is otherwise written.
                MOVE    ADF_UNMNT_PREV, R0
                MOVE    0, @R0
                MOVE    OSM_SUB_ACTIVE, R0
                MOVE    0, @R0

                DECRB
                RET

; SCR_INIT: called once from START_FIRMWARE, before the Shell starts. Puts the
; screen-centering runtime state (issue #5) into a safe boot state, so a
; DETECT_SCREEN_MODE poll from a boot-time wait loop (HANDLE_IO is polled before
; PREP_START runs LOAD_SCREEN_OFFSETS, and RAM is undefined at power-on) can never
; act on undefined state: the debounce latch says "nothing applied", and the table
; is inert (0,0,0,0 = no centering) until LOAD_SCREEN_OFFSETS reads the SD file.
SCR_INIT        INCRB
                MOVE    SCR_APPLIED_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0
                MOVE    SCR_TICK, R0
                MOVE    0, @R0
                MOVE    SCR_TABLE, R0
                MOVE    SCR_TABLE_WORDS, R1
_SCR_INIT_L     MOVE    0, @R0++
                SUB     1, R1
                RBRA    _SCR_INIT_L, !Z
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
; is the MiSTer "HPS resend once per minute" cadence.
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
;   1. SD guards: a swapped card invalidates every retained file handle, and an
;      active-slot switch invalidates the handles snapshotted on the other slot
;      - disable those drives and discard their dirty state (the
;      ROSM_INTEGRITY precedent: never write to a card we did not open on).
;   2. Mount tracking: when a mount of drive n reaches PARSEST=READY, snapshot
;      the Shell handle HNDL_RM_FILES[n] into that drive OWN FDH (the Shell
;      re-opens that struct for the NEXT load before PREP_LOAD_IMAGE even
;      runs!) and arm the write-back of that drive: WBC WR_EN=1 makes the track
;      engine announce that unit as writable to the Amiga.
;   3. One background flush step (respects the anti-thrashing gate), handed to
;      ONE drive per poll in round-robin order.
;
; Input/Output: none; all registers are preserved
HANDLE_CORE_IO  SYSCALL(enter, 1)

                ; ADF unmount with SPACE (issue #16): must run FIRST and on
                ; EVERY poll. HANDLE_IO calls us at the top of every OSM
                ; key-wait iteration, before the KEYB$SCAN of that loop - the
                ; ordering that lets us both suppress the SPACE of the menu (so
                ; it never becomes a mount) and, on a fresh press over the
                ; highlighted ' ADF:' line, eject the disk. Cheap in the common
                ; path (OSM closed) and RAMROM-transparent.
                RSUB    HANDLE_UNMOUNT_KEY, 1

                ; screen centering (issue #5): throttle the mode detector. A mode
                ; change only needs to be reacted to within a few ms, so run
                ; DETECT_SCREEN_MODE once every SCR_TICK_MASK+1 poll-loop
                ; iterations instead of every one -- the detector is ~80 instr
                ; and this callback is polled in the tightest loops (incl. the
                ; ADF write-back below). Skipped iterations pay only this
                ; ~4-instruction counter. On a change the detector re-centers
                ; within (SCR_DEBOUNCE+2) detects, i.e. a few tens of ms.
                MOVE    SCR_TICK, R4
                ADD     1, @R4
                MOVE    @R4, R5
                AND     SCR_TICK_MASK, R5
                RBRA    _HCIO_NODET, !Z
                RSUB    DETECT_SCREEN_MODE, 1     ; detect + apply on a mode change

                ; be transparent about the active RAMROM device selection
_HCIO_NODET     MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R1
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3

                ; --- 1. SD guards, per drive. A shell-detected card change
                ;        tears EVERY drive down. An active-slot switch tears
                ;        down exactly the drives whose handle was snapshotted
                ;        on the other slot: the file browser F1/F3 switch
                ;        updates SD_ACTIVE WITHOUT raising SD_CHANGED, and
                ;        every FDH points at the ONE shared device handle,
                ;        which after the switch describes the other card - so a
                ;        flush through it would write into whatever file
                ;        happens to live at those clusters over there.
                ;        Drives armed on the slot that is now active survive;
                ;        with two cards in use, df0 from slot 1 and df1 from
                ;        slot 2 are independent and only one of them dies.
                XOR     R6, R6                  ; R6: 1 = tear every drive down
                MOVE    SD_CHANGED, R4
                CMP     1, @R4
                RBRA    _HCIO_SD1, !Z
                MOVE    1, R6
_HCIO_SD1       MOVE    M2M$CSR, R4
                MOVE    @R4, R4
                AND     M2M$CSR_SD_ACTIVE, R4   ; R4: the active SD slot
                XOR     R5, R5                  ; R5: drive
_HCIO_SDD       MOVE    ADF_FDH_VALID, R7
                ADD     R5, R7
                CMP     0, @R7
                RBRA    _HCIO_SDN, Z            ; not armed: nothing to tear
                CMP     1, R6
                RBRA    _HCIO_SDK, Z            ; card swapped: tear it down
                MOVE    ADF_SD_SLOT, R7
                ADD     R5, R7
                CMP     @R7, R4                 ; snapshot slot == active slot?
                RBRA    _HCIO_SDN, Z            ; yes: this drive stays armed
_HCIO_SDK       MOVE    R5, R8                  ; the retained handle is dead:
                RSUB    ADF_WIPE_DIRTY, 1       ; the dirty tracks can no
                RSUB    ADF_DISARM, 1           ; longer be written anywhere
                MOVE    ADF_MOUNT_SEEN, R7      ; 1: BLOCK re-arming from the
                ADD     R5, R7                  ; STALE PARSEST=READY of the
                MOVE    1, @R7                  ; old mount - only the next
                                                ; real ADF load, through
                                                ; PREP_LOAD_IMAGE, opens the
                                                ; arming again
_HCIO_SDN       ADD     1, R5
                CMP     ADF_DRIVES, R5
                RBRA    _HCIO_SDD, !Z
                CMP     1, R6                   ; on a card change, skip the
                RBRA    _HCIO_RTC, Z            ; ADF work for this poll - but
                                                ; only the ADF work. SD_CHANGED
                                                ; is a LATCH, cleared only by
                                                ; the mount/browse flow, so
                                                ; returning outright here would
                                                ; starve the battery-clock
                                                ; reseed and the live status
                                                ; line for as long as the user
                                                ; does not open a file browser.

                ; --- 2. mount tracking (PARSEST=READY rising edge), per drive
_HCIO_MOUNT     XOR     R5, R5                  ; R5: drive
_HCIO_MD        MOVE    ADF_DEV_TAB, R6
                ADD     R5, R6
                MOVE    @R6, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1         ; R10: parse status
                MOVE    ADF_MOUNT_SEEN, R7
                ADD     R5, R7
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _HCIO_NOMNT, !Z
                CMP     1, @R7
                RBRA    _HCIO_MN, Z             ; this mount is already armed
                MOVE    1, @R7
                MOVE    HNDL_RM_FILES, R8       ; snapshot the Shell handle of
                ADD     R5, R8                  ; THIS drive: manual CRT/ROM id
                MOVE    @R8, R8                 ; n is drive n (the mount lines
                MOVE    ADF_FDH_TAB, R9         ; sit in that order in the
                ADD     R5, R9                  ; static config array)
                MOVE    @R9, R9
                MOVE    FAT32$FDH_STRUCT_SIZE, R10
                SYSCALL(memcpy, 1)
                ADD     FAT32$FDH_FLAGS, R9     ; the snapshot must never start
                MOVE    0, @R9                  ; out DIRTY: the ONE hardware
                                                ; sector buffer is tracked by
                                                ; the ADDRESS of the handle
                                                ; that filled it, so a copy
                                                ; that claims to be dirty while
                                                ; not owning the buffer would
                                                ; make the next FAT32$FLUSH
                                                ; write foreign bytes to the
                                                ; sector of this drive. The
                                                ; Shell only ever reads through
                                                ; that handle, so this is
                                                ; belt-and-braces
                MOVE    ADF_FDH_VALID, R6
                ADD     R5, R6
                MOVE    1, @R6
                MOVE    ADF_FL_STATE, R6
                ADD     R5, R6
                MOVE    0, @R6
                MOVE    M2M$CSR, R6             ; remember the active SD slot
                MOVE    @R6, R6                 ; the snapshot was taken on
                AND     M2M$CSR_SD_ACTIVE, R6   ; (see the SD guards above)
                MOVE    ADF_SD_SLOT, R7
                ADD     R5, R7
                MOVE    R6, @R7
                MOVE    R5, R8                  ; WR_EN := 1: the track engine
                RSUB    ADF_SEL_WBC, 1          ; announces THIS unit writable
                MOVE    ADF_WBC_CTRL, R6
                MOVE    1, @R6
                RBRA    _HCIO_MN, 1

_HCIO_NOMNT     MOVE    0, @R7                  ; re-arm the edge detection
                                                ; for the next mount
_HCIO_MN        ADD     1, R5
                CMP     ADF_DRIVES, R5
                RBRA    _HCIO_MD, !Z

                ; --- 3. one background flush step, round-robin over the
                ;        drives. At most ONE drive does I/O per poll, so three
                ;        armed drives cost the main loop exactly what one did,
                ;        and handing the next slice to the next drive keeps a
                ;        continuously re-dirtied drive from starving the others.
                ;        A drive that is idle or sitting behind its
                ;        anti-thrashing gate does not consume the slice - the
                ;        scan simply moves on to the next one.
                MOVE    ADF_FL_RR, R4
                MOVE    @R4, R5                 ; R5: drive to try first
                MOVE    ADF_DRIVES, R6          ; R6: drives left to try
_HCIO_FL        XOR     R8, R8                  ; 0 = respect anti-thrashing
                MOVE    R5, R9
                RSUB    FLUSH_ADF_STEP, 1
                MOVE    R5, R7                  ; R7: the drive after this one
                ADD     1, R7
                CMP     ADF_DRIVES, R7
                RBRA    _HCIO_FLR, !Z
                XOR     R7, R7
_HCIO_FLR       CMP     ADF_FL_DID, R8          ; slice consumed?
                RBRA    _HCIO_FLD, Z
                MOVE    R7, R5                  ; no: try the next drive within
                SUB     1, R6                   ; this same poll
                RBRA    _HCIO_FL, !Z
                RBRA    _HCIO_RTC, 1            ; nothing to flush at all

                ; The drive that was served keeps the slice until its TRACK is
                ; finished, and only then does the rotation move on. Rotating
                ; after every chunk would flip the owner of the one shared FAT32
                ; sector buffer on every poll, and FAT32$READ_FDH answers an
                ; owner change with a full 512-byte READ of the sector it is
                ; about to overwrite completely - a wasted SD read per chunk.
                ; Per track instead of per chunk makes that at most one per 11.
                ; Fairness stays bounded: a drive can hold the slice for one
                ; track at most, and its anti-thrashing gate applies again at
                ; the next session start.
_HCIO_FLD       MOVE    ADF_FL_STATE, R6
                ADD     R5, R6
                CMP     0, @R6                  ; session still open?
                RBRA    _HCIO_FLK, !Z           ; yes: this drive keeps it
                MOVE    R7, @R4                 ; no: hand it to the next drive
                RBRA    _HCIO_RTC, 1
_HCIO_FLK       MOVE    R5, @R4

                ; keep the Amiga battery clock live (issue #13): re-issue the
                ; framework RTC read once per minute so the Minimig $DC0000 clock
                ; advances instead of freezing after the boot seed
_HCIO_RTC       RSUB    RTC_STEP, 1

                ; live Hardware Floppy status line in the main menu. Four RAM
                ; reads and out while the OSM is closed, which is the case in
                ; the tightest loops.
                RSUB    HWF_STATUS_STEP, 1

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
; With three drives that same per-chunk flush is what makes INTERLEAVED
; sessions safe: drive 0 and drive 1 can each have an open track session, and
; the poll that serves one of them always finds the shared sector buffer clean.
; FAT32 errors are fatal - the C64MEGA65 FLUSH_CACHE policy; SD removal is
; pre-guarded by the SD-change check in HANDLE_CORE_IO.
;
; Expects the caller to tolerate a changed RAMROM device selection.
;
; Input:
;   R8: 0=respect the anti-thrashing gate (background), 1=force (flush now)
;   R9: drive 0..2
; Output:
;   R8: ADF_FL_IDLE  = clean and idle, nothing left to do
;       ADF_FL_DID   = work remains AND this call consumed a time slice
;       ADF_FL_GATED = work remains but the anti-thrashing gate is closed,
;                      so nothing was done (cannot happen when forced)
;   R9: clobbered; R10..R12 preserved
FLUSH_ADF_STEP  INCRB
                MOVE    R10, R1                 ; preserve R10..R12
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R8, R4                  ; R4: force flag
                MOVE    R9, R0                  ; R0: drive, live to the end

                MOVE    R0, R8                  ; select the WBC window of
                RSUB    ADF_SEL_WBC, 1          ; THIS drive

                MOVE    ADF_FL_STATE, R8        ; session active?
                ADD     R0, R8
                CMP     1, @R8
                RBRA    _FADF_CHUNK, Z

                MOVE    ADF_WBC_STAT, R8        ; idle: any dirty tracks?
                MOVE    @R8, R8
                AND     1, R8
                RBRA    _FADF_RET0, Z           ; clean and idle: done

                MOVE    ADF_FDH_VALID, R8       ; without a handle we can
                ADD     R0, R8                  ; never flush: discard (only
                CMP     1, @R8                  ; reachable defensively)
                RBRA    _FADF_DISCARD, !Z

                CMP     1, R4                   ; forced?
                RBRA    _FADF_PICK, Z
                MOVE    ADF_WBC_STAT, R8        ; anti-thrashing gate: only
                MOVE    @R8, R8                 ; start a track after the
                AND     2, R8                   ; hardware countdown expired
                RBRA    _FADF_RET2, Z           ; gated: work remains, but this
                                                ; call did nothing

                ; pick the lowest dirty track: first non-zero bitmap word,
                ; then its lowest set bit
_FADF_PICK      MOVE    ADF_WBC_DIRTY0, R5      ; R5: bitmap word address
                XOR     R6, R6                  ; R6: word index 0..10
_FADF_FWORD     CMP     0, @R5
                RBRA    _FADF_FBIT, !Z
                ADD     1, R5
                ADD     1, R6
                CMP     ADF_WBC_DIRTY_W, R6
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
                ADD     R0, R8
                MOVE    R11, @R8
                MOVE    ADF_FL_BADDR_HI, R8
                ADD     R0, R8
                MOVE    R12, @R8
                MOVE    ADF_FL_REMAIN, R8
                ADD     R0, R8
                MOVE    ADF_TRACK_BYTES, @R8
                MOVE    ADF_FDH_TAB, R8         ; seek to the track start, in
                ADD     R0, R8                  ; the file of THIS drive
                MOVE    @R8, R8                 ; (file offset = image offset)
                MOVE    R11, R9
                MOVE    R12, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                MOVE    ADF_FL_STATE, R8
                ADD     R0, R8
                MOVE    1, @R8
                RBRA    _FADF_RET1, 1           ; chunks stream on later calls

                ; active session: stream one chunk. window = byte addr >> 12,
                ; offset = byte addr & 0xFFF (one file byte per window word)
_FADF_CHUNK     MOVE    ADF_FL_BADDR_HI, R8
                ADD     R0, R8
                MOVE    @R8, R5
                AND     0xFFFD, SR              ; clear X: shift in zeros
                SHL     4, R5
                MOVE    ADF_FL_BADDR_LO, R8
                ADD     R0, R8
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
                MOVE    ADF_FDH_TAB, R6         ; R6: the FDH of THIS drive,
                ADD     R0, R6                  ; hoisted out of the byte loop
                MOVE    @R6, R6
                MOVE    ADF_FLUSH_CHUNK, R5     ; R5: byte countdown
_FADF_WLOOP     MOVE    R6, R8
                MOVE    @R7++, R9               ; one file byte per word
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z
                SUB     1, R5
                RBRA    _FADF_WLOOP, !Z

                ; persist the chunk NOW: the FAT32 hardware sector buffer is
                ; shared with every other SD user (e.g. the OSM settings
                ; save, and the track session of another drive) - a dirty
                ; buffered sector left across time slices would be clobbered
                ; by them. This costs nothing: the chunk is exactly one
                ; sector, which gets written exactly once either way - just
                ; earlier.
                MOVE    R6, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _FADF_FATAL, !Z

                ; Advance the 32-bit byte address. Both variable addresses are
                ; resolved FIRST: the per-drive indexing is itself an ADD, and
                ; an ADD between the low-word addition and the ADDC that
                ; consumes its carry would overwrite that carry - the high word
                ; would then never increment and every chunk past a 64 KB
                ; boundary would be written 64 KB too low in the file.
                MOVE    ADF_FL_BADDR_HI, R7
                ADD     R0, R7
                MOVE    ADF_FL_BADDR_LO, R8
                ADD     R0, R8
                ADD     ADF_FLUSH_CHUNK, @R8
                ADDC    0, @R7
                MOVE    ADF_FL_REMAIN, R8
                ADD     R0, R8
                SUB     ADF_FLUSH_CHUNK, @R8
                RBRA    _FADF_RET1, !Z          ; track not finished yet

                ; Track done: close the session and report that this call DID
                ; consume its time slice - it just wrote and flushed a full
                ; 512-byte sector. Reporting "clean and idle" here instead
                ; would be read by the round-robin scan of HANDLE_CORE_IO as
                ; "this drive did nothing", and it would hand the same poll to
                ; the next drive, so a poll could do three chunk writes instead
                ; of one. Whether anything is left to do is answered for free
                ; by the next call, from the top of this routine, at no I/O
                ; cost. The forced-flush loops of PREP_LOAD_IMAGE and
                ; ADF_UNMOUNT spin until ADF_FL_IDLE and simply take one more
                ; cheap iteration.
                MOVE    ADF_FL_STATE, R8
                ADD     R0, R8
                MOVE    0, @R8
                RBRA    _FADF_RET1, 1

_FADF_DISCARD   MOVE    ADF_WBC_DIRTY0, R5      ; drop unflushable dirty bits
                MOVE    ADF_WBC_DIRTY_W, R6
_FADF_DISC1     MOVE    0xFFFF, @R5++
                SUB     1, R6
                RBRA    _FADF_DISC1, !Z
                RBRA    _FADF_RET0, 1

_FADF_RET0      MOVE    ADF_FL_IDLE, R8
                RBRA    _FADF_RET, 1
_FADF_RET2      MOVE    ADF_FL_GATED, R8
                RBRA    _FADF_RET, 1
_FADF_RET1      MOVE    ADF_FL_DID, R8
_FADF_RET       MOVE    R1, R10                 ; restore R10..R12
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

_FADF_FATAL     MOVE    ERR_ADF_FLUSH, R8       ; R9 holds the FAT32 error
                RBRA    FATAL, 1

; ----------------------------------------------------------------------------
; ADF unmount with SPACE (issue #16)
;
; Mirrors the C64 gesture: with the OSM open and the cursor on the ' ADF:'
; line, SPACE ejects the disk (df0 goes empty, the menu label reverts to
; "<Load>"). The framework has NO unmount path for CRT/ROM devices
; (HANDLE_MOUNTING always opens the browser for CRT/ROM mode, shell.asm) and
; M2M must not be modified, so we intercept the key core-side. HANDLE_IO calls
; HANDLE_CORE_IO - and thus HANDLE_UNMOUNT_KEY - at the TOP of every OSM
; key-wait iteration, BEFORE the KEYB$SCAN of that loop (options.asm). That
; ordering lets us both suppress the SPACE of the menu (so it never becomes a
; mount) and fire the eject ourselves. Full design + adversarial review:
; .research/INTEGRATION-SPEC-adf-unmount.md
;
; Five gates must all hold to act:
;   1  OSM open            M2M$CSR bit M2M$CSR_OSM (else SPACE is for the Amiga)
;   4  not a sub-activity  OSM_SUB_ACTIVE == 0 (the browser/help set it; this
;                          is what keeps a SPACE on a browser "press Space"
;                          screen reached via Return-to-replace from ejecting)
;   2  ' ADF:' highlighted OPTM_CUR_SEL == the flat menu index of the ADF item
;   3  ADF mounted         PARSEST == PT_OK (else let SPACE fall through and
;                          mount, matching the SPACE-on-empty-drive of the C64)
;   5  fresh SPACE edge    via the ADF_UNMNT_PREV latch (one act per press)
;
; Gates 1+4 read only absolute MMIO / RAM (no device window), so the common path
; (OSM closed) is cheap and leaves the RAMROM selection untouched. Only once we
; pass gate 4 do we snapshot RAMROM (R6/R7) and switch devices for gates 2/3 and
; the eject; _HUK_RET restores it so HANDLE_CORE_IO stays transparent to its
; caller. While gates 1-4 hold we suppress the SPACE of the menu EVERY iteration
; (race-free vs. the edge detector of KEYB$SCAN) and eject only on the gate-5
; rising edge.
;
; Input/Output: none. Bank-local R0-R7; clobbers global R8-R10 (HANDLE_CORE_IO
; has no live upper registers at its top and reloads them at first use).
; ----------------------------------------------------------------------------
HANDLE_UNMOUNT_KEY INCRB

                ; read current SPACE state (M2M$KEYBOARD is low-active) and
                ; update the edge latch UNCONDITIONALLY every call (OSM open or
                ; closed), so opening the OSM with SPACE held cannot fake an edge
                MOVE    M2M$KEYBOARD, R0
                MOVE    @R0, R0
                NOT     R0, R0                  ; low-active -> high-active
                AND     M2M$KEY_SPACE, R0
                MOVE    R0, R4                  ; R4 = 0x20 pressed / 0 released
                MOVE    ADF_UNMNT_PREV, R1
                MOVE    @R1, R5                 ; R5 = SPACE state last poll
                MOVE    R4, @R1                 ; latch := current

                ; --- gate 1: OSM open? (closed -> SPACE belongs to the Amiga)
                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_OSM, R0
                RBRA    _HUK_RET_NS, Z

                ; --- gate 4: inside a menu-item sub-activity (browser/help)? ---
                MOVE    OSM_SUB_ACTIVE, R0
                CMP     0, @R0
                RBRA    _HUK_RET_NS, !Z

                ; from here on we switch the RAMROM device; snapshot it first
                ; so _HUK_RET can hand HANDLE_CORE_IO back the selection intact
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R6
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    @R0, R7

                ; --- gate 2: is one of the three mount lines highlighted? ---
                ; The flat menu index of each mount line is a BUILD-TIME
                ; constant (AEXP_OSM_DF*_MOUNT_LN, scraped from mega65.vhd by
                ; make_rom.sh and cross-checked against the text of that line
                ; by .research/check_osm_menu.py), and OPTM_CUR_SEL is the live
                ; highlight in the same flat coordinate - so this gate is three
                ; compares. Asking CRTROM_M_GI once per drive instead would
                ; rescan the whole 146-line menu three times on EVERY key-wait
                ; poll. The scan needs no visibility test of its own: a mount
                ; line hidden by a menu dependency can never carry the cursor.
                MOVE    OPTM_CUR_SEL, R0
                MOVE    @R0, R0                 ; R0: highlighted flat index
                MOVE    ADF_MNT_LN_TAB, R1
                XOR     R2, R2                  ; R2: drive under inspection
_HUK_G2         CMP     @R1++, R0
                RBRA    _HUK_G3, Z
                ADD     1, R2
                CMP     ADF_DRIVES, R2
                RBRA    _HUK_G2, !Z
                RBRA    _HUK_RET, 1             ; some other line -> bail

                ; --- gate 3: is a disk in THAT drive? PARSEST == PT_OK ---
_HUK_G3         MOVE    ADF_DEV_TAB, R8
                ADD     R2, R8
                MOVE    @R8, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1         ; R10 = parse status
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _HUK_RET, !Z            ; empty drive -> let SPACE mount

                ; in context: suppress the SPACE of the menu this iteration,
                ; BEFORE KEYB$SCAN runs. The rising edge of KEYB$SCAN is
                ; (pressed AND NOT KEYB_PRESSED), so pre-setting the SPACE bit
                ; kills the edge -> KEYB$GETKEY never returns SPACE ->
                ; OPTM_CB_SEL / HANDLE_MOUNTING never fire for it. Done on every
                ; in-context poll (not only our own edge), so it is immune to
                ; the read skew between our M2M$KEYBOARD read and the menu read.
                MOVE    KEYB_PRESSED, R0
                OR      M2M$KEY_SPACE, @R0

                ; --- gate 5: act once per physical press (rising edge) ---
                CMP     0, R4                   ; SPACE pressed now?
                RBRA    _HUK_RET, Z
                CMP     0, R5                   ; ..released last poll?
                RBRA    _HUK_RET, !Z            ; still held -> already handled
                MOVE    R2, R8                  ; eject + flush + disarm THAT
                RSUB    ADF_UNMOUNT, 1          ; drive

_HUK_RET        MOVE    M2M$RAMROM_DEV, R0      ; restore the RAMROM selection
                MOVE    R6, @R0                 ; (keeps HANDLE_CORE_IO
                MOVE    M2M$RAMROM_4KWIN, R0    ;  transparent to its caller)
                MOVE    R7, @R0
_HUK_RET_NS     DECRB
                RET

; ADF_UNMOUNT: eject the ADF of ONE drive, then flush + disarm its write-back.
;
; Order matters: eject FIRST so the Amiga sees that unit vanish and stops
; writing to it, THEN flush the already-committed dirty tracks (the eject
; leaves the HyperRAM image intact), THEN disarm. This mirrors the flush +
; disarm of PREP_LOAD_IMAGE and now shares ADF_DISARM with it. Only the drive
; that is passed in is touched: a session or dirty bitmap of another drive
; keeps running untouched. Switches the RAMROM device; the caller
; (HANDLE_UNMOUNT_KEY) restores it.
;
; Input:  R8: drive 0..2
; Output: none. Bank-local R0-R2; clobbers global R8-R10.
ADF_UNMOUNT     INCRB
                MOVE    R8, R2                  ; R2: the drive, live to the end

                ; 1. eject: STATUS := ST_IDLE on the device of that drive. The
                ; validator (adf_mount_wrapper.vhd p_validate, VS_DONE) sees
                ; req_status /= REQ_OK and drops disk_mounted; the track engine
                ; announces that unit empty within ~1 ms. STATUS/PARSEST ->
                ; IDLE also makes the Shell revert the menu label of that drive
                ; for free via CRTROM_MLST_GET (same mechanism as ST_LDNG at
                ; the start of every load).
                MOVE    ADF_DEV_TAB, R8
                ADD     R2, R8
                MOVE    @R8, R8
                MOVE    CRTROM_CSR_STATUS, R9
                MOVE    CRTROM_CSR_ST_IDLE, R10
                RSUB    CRTROM_CSR_W, 1

                ; 2. force-flush all dirty tracks of that drive (bounded,
                ;    ignore the anti-thrashing gate). FLUSH_ADF_STEP streams
                ;    from the own FDH snapshot of the drive and does not depend
                ;    on disk_mounted, so it still works after the eject. On a
                ;    clean/unarmed disk (the common read-only case) the first
                ;    step returns idle at once. On budget exhaustion we leave
                ;    armed and let the background flush finish later (benign:
                ;    the drive already shows empty).
                ;
                ; First apply the SAME card-change guard that the SD guard of
                ; HANDLE_CORE_IO uses (SD_CHANGED, or an active-slot switch
                ; while armed): a swapped/pulled card makes the retained FDH
                ; stale, and flushing to it would write the old disk into the
                ; new card (the ROSM_INTEGRITY rule) - and the FAT32 errors of
                ; FLUSH_ADF_STEP are FATAL. We run BEFORE that SD guard (RSUB-ed
                ; first in HANDLE_CORE_IO), so an eject in the card-change
                ; window would otherwise crash. On a change, DISCARD the dirty
                ; bitmap (mirrors _HCIO_SDK) instead of flushing, then disarm.
                MOVE    SD_CHANGED, R0
                CMP     1, @R0
                RBRA    _ADF_UM_DROP, Z
                MOVE    ADF_FDH_VALID, R0       ; slot check only when armed
                ADD     R2, R0
                CMP     1, @R0
                RBRA    _ADF_UM_FLUSH, !Z       ; not armed -> flush is a no-op
                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_SD_ACTIVE, R0
                MOVE    ADF_SD_SLOT, R1
                ADD     R2, R1
                CMP     @R1, R0
                RBRA    _ADF_UM_FLUSH, Z        ; same slot -> safe to flush

_ADF_UM_DROP    MOVE    R2, R8                  ; card changed: drop the dirty
                RSUB    ADF_WIPE_DIRTY, 1       ; bitmap so a later mount cannot
                RBRA    _ADF_UM_DIS, 1          ; flush stale tracks into the
                                                ; new file, then disarm

_ADF_UM_FLUSH   MOVE    8192, R0                ; chunk budget (> 4 full disks)
_ADF_UM_FL      MOVE    1, R8                   ; forced step
                MOVE    R2, R9
                RSUB    FLUSH_ADF_STEP, 1
                CMP     ADF_FL_IDLE, R8         ; clean and idle?
                RBRA    _ADF_UM_DIS, Z
                SUB     1, R0
                RBRA    _ADF_UM_FL, !Z
                RBRA    _ADF_UM_RET, 1          ; budget gone: leave armed

                ; 3. disarm the write-back (mirrors PREP_LOAD_IMAGE): the
                ; PARSEST=READY of a later genuine mount re-arms it with a fresh
                ; handle snapshot. PARSEST is IDLE now, so _HCIO_MOUNT will not
                ; re-arm regardless; ADF_MOUNT_SEEN:=0 is the correct clean
                ; state for the next mount.
_ADF_UM_DIS     MOVE    R2, R8
                RSUB    ADF_DISARM, 1

_ADF_UM_RET     DECRB
                RET


; ----------------------------------------------------------------------------
; Live Hardware Floppy status in the main menu
;
; Every drive owns a twin pair of main-menu lines: the mount line, shown while
; that drive is a Disk Image, and a fixed-width TEXT line
; " dfN:Hardware Floppy   " shown while it is the Hardware Floppy (the menu
; dependency layer swaps them). That TEXT line is exactly OPTM_DX characters:
; one selection-marker column plus a HWF_LABEL_LEN-wide field, so the field can
; be patched in place while the menu is on screen. This is the C64MEGA65
; "8:Internal 1581" pattern, and it uses the same framework helper
; (OPTM_LIVE_TEXT, M2M-UPSTREAM live-text), which updates the writable menu-heap
; copy of the item string AND repaints just those characters.
;
; Three coarse states are shown. The idle label is byte-identical to the static
; config.vhd text, so painting it is a visual no-op:
;
;   idle    dfN:Hardware Floppy      the mechanism is not spinning
;   motor   dfN:HW Floppy: Motor     the motor runs, no data reaching Paula
;   read    dfN:HW Floppy: Reading   decoded words are streaming into Paula
;
; The classification needs no new hardware: bit 2 of the front-end status word
; is the motor line, and diag register 0x1B counts the data words the track
; engine served into Paula, so a moving counter IS a running read.
;
; Cost discipline, in the order the gates are applied: the whole routine is
; four RAM reads while the menu is closed - which is most of the time, and it
; is polled from every wait loop. Only once all four visibility gates pass does
; it look at the timer, and only once per about 10 ms does it touch the
; diagnostic device. The screen is written solely on an actual state change.
; ----------------------------------------------------------------------------

; HWF_OSM_INIT: called once from START_FIRMWARE, before the Shell starts (RAM
; is undefined at power-on and HANDLE_IO is polled from boot-time wait loops).
HWF_OSM_INIT    INCRB
                MOVE    HWF_OSM_LAST, R0
                MOVE    HWF_OS_INVALID, @R0
                MOVE    HWF_OSM_LDRV, R0
                MOVE    HWF_DRV_NONE, @R0
                MOVE    HWF_LAST_CNT, R0
                MOVE    0, @R0
                MOVE    IO$CYC_MID, R0
                MOVE    HWF_OSM_TICK, R1
                MOVE    @R0, @R1
                DECRB
                RET

; HWF_STATUS_STEP: one poll of the live Hardware Floppy status line.
;
; Expects the caller to tolerate a changed RAMROM device selection
; (HANDLE_CORE_IO saves and restores it around this call). Input/Output: none.
HWF_STATUS_STEP INCRB

                ; --- gate 1: is the OSM on screen at all? ---
                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_OSM, R0
                RBRA    _HWF_HIDE, Z

                ; --- gate 2: is a sub-activity showing instead? ---
                ; The file browser and the help viewer own the screen while
                ; they run, and they poll HANDLE_IO. OSM_SUB_ACTIVE is the flag
                ; that OSM_SEL_PRE/OSM_SEL_POST bracket them with (issue #16),
                ; and it is what stands in for the OPTM_FOREGROUND of the
                ; C64MEGA65 framework - see the contract of OPTM_LIVE_TEXT.
                MOVE    OSM_SUB_ACTIVE, R0
                CMP     0, @R0
                RBRA    _HWF_HIDE, !Z

                ; --- gate 3: the twin lines live in the MAIN menu ---
                MOVE    OPTM_MENULEVEL, R0
                CMP     0, @R0
                RBRA    _HWF_HIDE, !Z

                ; --- gate 4: which drive IS the Hardware Floppy? ---
                ; The selected-state array of the menu is plain QNICE RAM and
                ; therefore much cheaper than M2M$GET_SETTING, which would have
                ; to select the config device. Only one drive can claim the
                ; single mechanism (DRV_STEAL_HW enforces it), so the first hit
                ; wins; if nobody claims it, all three TEXT lines are hidden by
                ; their dependencies and there is nothing to show.
                MOVE    OPTM_DATA, R0
                MOVE    @R0, R0
                CMP     0, R0
                RBRA    _HWF_HIDE, Z
                ADD     OPTM_IR_STDSEL, R0
                MOVE    @R0, R0                 ; R0: selected-state array
                CMP     0, R0
                RBRA    _HWF_HIDE, Z
                MOVE    DRV_MODE_TAB, R1        ; R1: the Hardware Floppy item
                ADD     1, R1                   ; of drive 0
                XOR     R2, R2                  ; R2: drive
_HWF_D          MOVE    @R1, R3
                ADD     R0, R3
                CMP     0, @R3
                RBRA    _HWF_FOUND, !Z
                ADD     3, R1                   ; three words per drive
                ADD     1, R2
                CMP     ADF_DRIVES, R2
                RBRA    _HWF_D, !Z
                RBRA    _HWF_HIDE, 1            ; nobody claims the mechanism

                ; The drive that owns the mechanism changed: the cached state
                ; belongs to the line of the OTHER drive, so invalidate it and
                ; let the new line repaint at once.
_HWF_FOUND      MOVE    HWF_OSM_LDRV, R0
                CMP     @R0, R2
                RBRA    _HWF_TMR, Z
                MOVE    R2, @R0
                MOVE    HWF_OSM_LAST, R0
                MOVE    HWF_OS_INVALID, @R0

                ; --- throttle --- IO$CYC_MID advances at about 763 Hz, so
                ; polling once per eight changes is about 95 Hz. An invalidated
                ; cache bypasses the timer, so opening the menu or returning to
                ; it from a submenu updates immediately.
_HWF_TMR        MOVE    HWF_OSM_LAST, R0
                CMP     HWF_OS_INVALID, @R0
                RBRA    _HWF_POLL, Z
                MOVE    IO$CYC_MID, R0
                MOVE    @R0, R1
                MOVE    HWF_OSM_TICK, R0
                CMP     @R0, R1
                RBRA    _HWF_RET, Z             ; same timer slice
                MOVE    R1, @R0
                AND     HWF_OSM_POLL_MASK, R1
                RBRA    _HWF_RET, !Z

_HWF_POLL       MOVE    IO$CYC_MID, R0
                MOVE    @R0, R1
                MOVE    HWF_OSM_TICK, R0
                MOVE    R1, @R0

                ; one device selection and two word reads
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    AEXP_DEV_FDD, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0                  ; the bank decodes addr[5:0]
                MOVE    HWF_DIAG_STAT, R0
                MOVE    @R0, R3                 ; R3: front-end status word
                MOVE    HWF_DIAG_SERVED, R0
                MOVE    @R0, R4                 ; R4: words served into Paula

                MOVE    HWF_LAST_CNT, R0        ; did that counter move since
                MOVE    @R0, R5                 ; the previous poll?
                MOVE    R4, @R0

                MOVE    HWF_OS_IDLE, R6         ; classify, cheapest first
                MOVE    R3, R7
                AND     HWF_ST_MOTOR, R7
                RBRA    _HWF_CLS, Z             ; motor off: idle
                MOVE    HWF_OS_MOTOR, R6
                CMP     R5, R4
                RBRA    _HWF_CLS, Z             ; spinning, but nothing served
                MOVE    HWF_OS_READ, R6         ; words are reaching Paula

_HWF_CLS        MOVE    HWF_OSM_LAST, R0        ; coarse state unchanged?
                CMP     @R0, R6
                RBRA    _HWF_RET, Z             ; then do not touch the screen
                MOVE    R6, @R0

                ; Build the label: the state template with the drive digit
                ; patched in, so three templates cover all three drives.
                MOVE    HWF_OSM_STR, R0
                ADD     R6, R0
                MOVE    @R0, R8
                MOVE    HWF_LABEL, R9
                SYSCALL(strcpy, 1)
                MOVE    HWF_LABEL, R0
                ADD     HWF_LABEL_DIGIT, R0
                MOVE    R2, R1
                ADD     HWF_ASCII_ZERO, R1
                MOVE    R1, @R0

                MOVE    ADF_HW_LN_TAB, R0       ; the TEXT twin of that drive
                ADD     R2, R0
                MOVE    @R0, R8
                MOVE    1, R9                   ; skip the selection marker
                MOVE    HWF_LABEL, R10
                MOVE    HWF_LABEL_LEN, R11
                RSUB    OPTM_LIVE_TEXT, 1
                RBRA    _HWF_RET, 1

                ; Not visible. Invalidate so the first visible poll repaints:
                ; HELP_MENU re-copies the item string from config.vhd on every
                ; OSM opening, so the heap always reverts to the static text
                ; and a cached "the screen already shows this" would be wrong.
_HWF_HIDE       MOVE    HWF_OSM_LAST, R0
                CMP     HWF_OS_INVALID, @R0
                RBRA    _HWF_RET, Z
                MOVE    HWF_OS_INVALID, @R0
                MOVE    HWF_OSM_LDRV, R0
                MOVE    HWF_DRV_NONE, @R0

_HWF_RET        DECRB
                RET

; ----------------------------------------------------------------------------
; Drive Settings: keep the drive count and the per-drive modes consistent
; ----------------------------------------------------------------------------

; IS_ADF_GROUP: is this menu group id one of the three ADF mount items?
;
; The Shell hands the plain group id to FILTER_FILES and PREP_LOAD_IMAGE, and
; every drive needs its OWN mount group (a manual CRT/ROM line is bound to its
; id by its position in the static array). Both callbacks have to accept all
; three, otherwise the extension filter and the file-size guard silently apply
; to df0 only - and an oversized file streamed into df1 would run past the
; HyperRAM pool of that drive.
;
; Input:  R8: menu group id
; Output: C=1 if it is a df0/df1/df2 mount item, C=0 otherwise.
;         All registers preserved.
IS_ADF_GROUP    INCRB
                MOVE    ADF_GRP_TAB, R0
                XOR     R1, R1                  ; R1: drive under inspection
_IAG_D          CMP     @R0++, R8
                RBRA    _IAG_YES, Z
                ADD     1, R1
                CMP     ADF_DRIVES, R1
                RBRA    _IAG_D, !Z
                AND     0xFFFB, SR              ; clear Carry: not a mount item
                DECRB
                RET
_IAG_YES        MOVE    R1, R9                  ; the drive behind the group id
                OR      0x0004, SR              ; set Carry
                DECRB
                RET

; Menu line of each mode item, three words per drive: Disk Image, Hardware
; Floppy, Off. df0 always exists and therefore has no Off item - 0xFFFF marks
; that, and every loop below skips it.
DRV_MODE_TAB    .DW AEXP_OSM_DF0_IMG, AEXP_OSM_DF0_HW, 0xFFFF
                .DW AEXP_OSM_DF1_IMG, AEXP_OSM_DF1_HW, AEXP_OSM_DF1_OFF
                .DW AEXP_OSM_DF2_IMG, AEXP_OSM_DF2_HW, AEXP_OSM_DF2_OFF

; DRV_ENFORCE_COUNT: called after the "Drives" radio changed.
;
; A drive that the new count does not cover must sit on its Off item, and a
; drive that just came back must leave it. The Off item is the one the count
; radio swaps in through the menu dependency, so this is what makes the drive
; appear in and disappear from the main menu. Note that we cannot simply hide
; the mode radio instead: the main-menu twin lines depend on the MODE, not on
; the count, and a dependent line may name only one mother group.
;
; Input:  none    Output: none    All registers preserved.
DRV_ENFORCE_COUNT SYSCALL(enter, 1)

                MOVE    1, R0                   ; R0: number of drives
                MOVE    AEXP_OSM_DRIVES_2, R8
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVEC_C3, Z
                MOVE    2, R0
                RBRA    _DRVEC_L, 1
_DRVEC_C3       MOVE    AEXP_OSM_DRIVES_3, R8
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVEC_L, Z
                MOVE    3, R0

_DRVEC_L        MOVE    1, R1                   ; R1: drive under inspection
                                                ; (df0 always exists)
_DRVEC_D        CMP     3, R1                   ; all drives done?
                RBRA    _DRVEC_RET, Z
                MOVE    DRV_MODE_TAB, R2        ; R2: &tab[drive]
                MOVE    R1, R3
                ADD     R3, R3                  ; three words per drive
                ADD     R1, R3
                ADD     R3, R2

                ; QNICE CMP sets N for an unsigned src > dst, so this asks
                ; "count > drive index", i.e. "the count still covers it"
                CMP     R0, R1
                RBRA    _DRVEC_OFF, !N          ; no: the drive is gone

                ; the drive exists: leave Off if it is still selected
                MOVE    R2, R4
                ADD     2, R4
                MOVE    @R4, R8                 ; Off item of this drive
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVEC_N, Z             ; not on Off: nothing to do
                MOVE    @R2, R8                 ; select Disk Image instead
                MOVE    1, R9
                RSUB    M2M$FORCE_MENU, 1
                RBRA    _DRVEC_N, 1

                ; the drive does not exist any more: force it to Off - but only
                ; if it is not already there. OPTM_SET goes FATAL when it is
                ; asked to select the item of a menu group that is ALREADY the
                ; selected one: its "unselect the other member" scan then finds
                ; nothing and falls through into OPTM_F_MENUGRP.
_DRVEC_OFF      MOVE    R2, R4
                ADD     2, R4
                MOVE    @R4, R8
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVEC_N, !Z            ; already Off: nothing to do
                MOVE    1, R9
                RSUB    M2M$FORCE_MENU, 1

_DRVEC_N        ADD     1, R1
                RBRA    _DRVEC_D, 1

_DRVEC_RET      SYSCALL(leave, 1)
                RET

; DRV_STEAL_HW: called after the mode radio of one drive changed.
;
; There is exactly one physical mechanism in a MEGA65, so if the drive that
; just changed took "Hardware Floppy", every other drive that still claims it
; has to fall back to "Disk Image" (clear-before-set, the C64MEGA65
; _OSM_PRE_STEAL pattern). If it took something else, nothing is stolen.
;
; Input:  R8: the drive whose mode changed (0..2)
; Output: R8/R9 undefined; all other registers preserved.
DRV_STEAL_HW    SYSCALL(enter, 1)

                MOVE    R8, R0                  ; R0: the drive that changed
                MOVE    DRV_MODE_TAB, R1
                MOVE    R0, R2
                ADD     R2, R2
                ADD     R0, R2
                ADD     R2, R1                  ; R1: &tab[changed drive]
                MOVE    R1, R3
                ADD     1, R3
                MOVE    @R3, R8                 ; its Hardware Floppy item
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVSH_RET, Z           ; not the hardware drive: done

                XOR     R4, R4                  ; R4: drive to check
_DRVSH_D        CMP     3, R4
                RBRA    _DRVSH_RET, Z
                CMP     R4, R0                  ; skip the drive that changed
                RBRA    _DRVSH_N, Z
                MOVE    DRV_MODE_TAB, R5
                MOVE    R4, R6
                ADD     R6, R6
                ADD     R4, R6
                ADD     R6, R5                  ; R5: &tab[drive]
                MOVE    R5, R6
                ADD     1, R6
                MOVE    @R6, R8                 ; its Hardware Floppy item
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DRVSH_N, Z             ; does not claim it: leave alone
                MOVE    @R5, R8                 ; hand it back a disk image
                MOVE    1, R9
                RSUB    M2M$FORCE_MENU, 1
_DRVSH_N        ADD     1, R4
                RBRA    _DRVSH_D, 1

_DRVSH_RET      SYSCALL(leave, 1)
                RET

; DRV_EJECT_GONE: eject the disk of every drive that is no longer a Disk Image.
;
; A drive that the user switches to "Hardware Floppy" or to "Off" would
; otherwise keep its ADF in HyperRAM and its write-back armed while losing every
; way of getting rid of it again: the mount line of that drive is hidden by the
; menu dependency, so the SPACE eject cannot reach it, and no other unmount path
; exists. That stranded mount would also hold its file against every other
; drive, because ADF_DUP_CHECK compares the fresh file against the armed drives -
; so taking a disk out of df1 by turning df1 off would make that same disk
; unmountable in df0. Leaving Disk Image mode therefore ejects, through the very
; routine the SPACE gesture uses: flush what is pending into the right file
; first, then disarm.
;
; Called from OSM_SEL_POST after the two consistency helpers have settled the
; model, so every mode item already carries its final value.
;
; Input:  none    Output: none    All registers preserved.
DRV_EJECT_GONE  SYSCALL(enter, 1)

                MOVE    M2M$RAMROM_DEV, R0      ; ADF_UNMOUNT switches devices
                MOVE    @R0, R1                 ; and does not restore them
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3

                XOR     R4, R4                  ; R4: drive
_DEG_D          MOVE    DRV_MODE_TAB, R5        ; R5: &tab[drive]
                MOVE    R4, R6
                ADD     R6, R6                  ; three words per drive
                ADD     R4, R6
                ADD     R6, R5
                MOVE    @R5, R8                 ; its Disk Image item
                RSUB    M2M$GET_SETTING, 1
                CMP     0, R9
                RBRA    _DEG_N, !Z              ; still a Disk Image: keep it

                MOVE    ADF_DEV_TAB, R5         ; is anything mounted in it?
                ADD     R4, R5
                MOVE    @R5, R8
                MOVE    CRTROM_CSR_PARSEST, R9
                RSUB    CRTROM_CSR_R, 1
                CMP     CRTROM_CSR_PT_OK, R10
                RBRA    _DEG_N, !Z              ; empty: nothing to eject

                MOVE    R4, R8
                RSUB    ADF_UNMOUNT, 1          ; eject + flush + disarm

_DEG_N          ADD     1, R4
                CMP     ADF_DRIVES, R4
                RBRA    _DEG_D, !Z

                MOVE    R1, @R0                 ; restore RAMROM selection
                MOVE    R3, @R2
                SYSCALL(leave, 1)
                RET

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
; LOAD_SCREEN_OFFSETS: screen adjustment (issue #5). Reads the per-Amiga-mode
; table of signed screen offsets (HDMI crop, analog overscan, analog pan) from
; /amiga/aexp_screen.cfg into RAM (SCR_TABLE). It does NOT push anything
; itself; DETECT_SCREEN_MODE (called from HANDLE_CORE_IO) watches the
; ascal-measured geometry + interlace flag, picks the matching row, and pushes
; it into the CFD gp_reg: HDMI crop to words 4..7 (ascal input crop
; himin/himax/vimin/vimax), analog overscan to words 0..3 (soft-blank) and
; analog pan to words 8..9 (analog_positioner sync phase), all M2M-UPSTREAM.
; On a missing/invalid file the table is zeroed (all 0 = no adjustment).
; Loading (re)arms the detector so the row of the current mode is re-pushed.
; Called from PREP_START (boot, before the core un-resets) and from
; OSM_SEL_POST on the "Reload screen cfg" item (live, no core reset / no
; re-synth -- the point of the SD-file tuning loop).
;
; File /amiga/aexp_screen.cfg (big-endian 16-bit words): "A","X", ver, count=4,
; then 4 rows in the fixed order lores-progressive, hires-progressive,
; lores-interlaced, hires-interlaced. A v4 row has 10 signed words:
; (himin_off, himax_off, vimin_off, vimax_off,   <- HDMI ascal input crop
;  os_l, os_r, os_t, os_b,                       <- analog overscan soft-blank
;  pan_x, pan_y)                                 <- analog position
; A legacy v3 row has only the first 8 words; the two pan words are zeroed on
; load, so existing v3 files keep working as overscan-only. The overscan four
; bias the analog soft-blank window; the pan pair drives the analog_positioner
; sync-phase shift (both M2M-UPSTREAM screen-center, applied in the framework
; av_pipeline). Only the low 12 bits of each word reach the core.
;
; Input:  None      Output: R8 = 0, R9 = 0
; ----------------------------------------------------------------------------
LOAD_SCREEN_OFFSETS INCRB

                MOVE    CONFIG_DEVH, R8         ; reuse the config device handle
                CMP     0, @R8                  ; valid? (set by HELP_MENU_INIT)
                RBRA    _LSO_ZERO, Z            ; no SD device -> zero table

                MOVE    SCR_FDH, R9        ; empty file handle struct
                MOVE    SCR_FILE_NAME, R10      ; "/amiga/aexp_screen.cfg"
                XOR     R11, R11                ; "/" path separator
                SYSCALL(f32_fopen, 1)
                CMP     0, R10                  ; open OK?
                RBRA    _LSO_ZERO, !Z           ; no -> zero table

                RSUB    _LSO_RDBYTE, 1          ; header byte 0: 'A'
                CMP     0, R10
                RBRA    _LSO_ZERO, !Z
                CMP     0x0041, R8
                RBRA    _LSO_ZERO, !Z
                RSUB    _LSO_RDBYTE, 1          ; header byte 1: 'X'
                CMP     0x0058, R8
                RBRA    _LSO_ZERO, !Z
                RSUB    _LSO_RDBYTE, 1          ; header byte 2: version 3 or 4
                MOVE    R8, R7                  ; R7: file version (banked reg)
                CMP     SCR_VER_V3, R8
                RBRA    _LSO_VEROK, Z
                CMP     SCR_VER_V4, R8
                RBRA    _LSO_ZERO, !Z
_LSO_VEROK      RSUB    _LSO_RDBYTE, 1          ; header byte 3: count = 4 modes
                CMP     SCR_MODES, R8
                RBRA    _LSO_ZERO, !Z

                MOVE    SCR_TABLE, R0           ; R0: table destination
                MOVE    SCR_MODES, R2           ; R2: row counter
_LSO_ROWLOOP    MOVE    SCR_V3_WORDS, R1        ; 8 words: HDMI + overscan
_LSO_RDLOOP     RSUB    _LSO_RDWORD, 1          ; R8 = 16-bit value, R10 status
                CMP     0, R10                  ; full word read?
                RBRA    _LSO_ZERO, !Z           ; truncated -> zero table
                MOVE    R8, @R0++               ; store into the RAM table
                SUB     1, R1
                RBRA    _LSO_RDLOOP, !Z
                CMP     SCR_VER_V4, R7          ; v4: two pan words follow
                RBRA    _LSO_PANZ, !Z
                MOVE    SCR_PAN_WORDS, R1
_LSO_PANLOOP    RSUB    _LSO_RDWORD, 1
                CMP     0, R10
                RBRA    _LSO_ZERO, !Z
                MOVE    R8, @R0++
                SUB     1, R1
                RBRA    _LSO_PANLOOP, !Z
                RBRA    _LSO_NXROW, 1
_LSO_PANZ       MOVE    0, @R0++                ; v3: pan_x = pan_y = 0
                MOVE    0, @R0++
_LSO_NXROW      SUB     1, R2
                RBRA    _LSO_ROWLOOP, !Z
                RBRA    _LSO_ARM, 1

_LSO_ZERO       MOVE    SCR_TABLE, R0      ; no/invalid file -> all zeros
                MOVE    SCR_TABLE_WORDS, R1      ; (0,0,0,0 = no centering)
_LSO_ZLOOP      MOVE    0, @R0++
                SUB     1, R1
                RBRA    _LSO_ZLOOP, !Z

                ; force the mode detector to (re-)push the row of the current
                ; mode by invalidating the applied-mode latch and restarting the
                ; debounce
_LSO_ARM        MOVE    SCR_APPLIED_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_MODE, R0
                MOVE    SCR_MODE_NONE, @R0
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0

                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; read one byte from SCR_FDH -> R8 = byte, R10 = status (0 = OK). Shares the
; register bank of the caller (touches only R8/R9/R10).
_LSO_RDBYTE     MOVE    SCR_FDH, R8
                SYSCALL(f32_fread, 1)           ; R9 = byte, R10 = status
                MOVE    R9, R8
                RET

; read a big-endian 16-bit word -> R8 = value, R10 = status (0 = OK only if
; both bytes were read). Combines (hi << 8) | lo via SWAP.
_LSO_RDWORD     INCRB
                RSUB    _LSO_RDBYTE, 1          ; R8 = hi byte
                CMP     0, R10
                RBRA    _LSO_RDW_ERR, !Z
                MOVE    R8, R0
                SWAP    R0, R0                  ; R0 = hi << 8
                RSUB    _LSO_RDBYTE, 1          ; R8 = lo byte
                CMP     0, R10
                RBRA    _LSO_RDW_ERR, !Z
                OR      R8, R0
                MOVE    R0, R8                  ; R8 = (hi << 8) | lo
                XOR     R10, R10                ; status = OK
_LSO_RDW_RET    DECRB
                RET
_LSO_RDW_ERR    MOVE    1, R10                  ; status = error
                RBRA    _LSO_RDW_RET, 1

; push value R8 into CFD gp_reg word R9 (0..15). Fresh bank for the scratch.
_LSO_CFDW       INCRB
                MOVE    M2M$CFD_ADDR, R0
                MOVE    R9, @R0                 ; select 16-bit window
                MOVE    M2M$CFD_DATA, R0
                MOVE    R8, @R0                 ; write value into the window
                DECRB
                RET

; ----------------------------------------------------------------------------
; DETECT_SCREEN_MODE: screen adjustment (issue #5), the runtime half. Called
; from HANDLE_CORE_IO every main-loop / wait-loop iteration. Reads the
; ascal-measured input geometry (SYS_CORE_X/Y) and the interlace flag
; (SYS_CORE_FLAGS bit 0, M2M-UPSTREAM screen-center), classifies the Amiga
; graphics mode, debounces it, and on a stable CHANGE pushes the matching
; SCR_TABLE row into CFD gp_reg: HDMI crop into words 4..7, analog overscan
; into words 0..3, analog pan into words 8..9, and logs a MiSTer-style
; two-line (HDMI + Analog) trace to the serial UART. A mode outside the table
; (unexpected geometry) applies all zeros and logs "unsupported". Fully
; self-contained: own enter/leave and RAMROM device/window save/restore.
;
; Input/Output: none; all registers preserved
; ----------------------------------------------------------------------------
DETECT_SCREEN_MODE SYSCALL(enter, 1)

                ; --- read SYS_CORE geometry + interlace flag, transparently
                ; restoring the RAMROM device/window selection of the caller ---
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    @R0, R1
                MOVE    M2M$RAMROM_4KWIN, R2
                MOVE    @R2, R3
                MOVE    M2M$SYS_INFO, @R0
                MOVE    M2M$SYS_CORE, @R2
                MOVE    M2M$SYS_CORE_X, R4
                MOVE    @R4, R4                 ; R4 = hdmax (measured + 1)
                MOVE    M2M$SYS_CORE_Y, R5
                MOVE    @R5, R5                 ; R5 = vdmax
                MOVE    M2M$SYS_CORE_FLAGS, R6
                MOVE    @R6, R6                 ; R6 = flags (bit 0 = interlaced)
                MOVE    R1, @R0                 ; restore RAMROM selection
                MOVE    R3, @R2

                ; --- classify hdmax (OCS PAL is bimodal; the in_range_u syscall
                ;     tests the half-open window R9 <= R8 < R10) ---
                CMP     SCR_HDMAX_NOSIG, R4     ; hdmax < 200 -> no video yet
                RBRA    _DSM_RET, N             ;   (boot / mode change) -> skip
                MOVE    R4, R8                  ; R8 = hdmax for the range checks
                MOVE    SCR_LORES_LO, R9        ; lores window [367, 388)
                MOVE    SCR_LORES_HI, R10
                SYSCALL(in_range_u, 1)
                RBRA    _DSM_LORES, C
                MOVE    SCR_HIRES_LO, R9        ; hires window [744, 765)
                MOVE    SCR_HIRES_HI, R10       ; (R8 still = hdmax)
                SYSCALL(in_range_u, 1)
                RBRA    _DSM_HIRES, C
                RBRA    _DSM_UNK, 1             ; present but unrecognised

_DSM_LORES      XOR     R7, R7                  ; horizontal bit 0 = lores
                RBRA    _DSM_SCAN, 1
_DSM_HIRES      MOVE    SCR_HIRES_BIT, R7       ; horizontal bit 1 = hires
_DSM_SCAN       MOVE    R6, R0                  ; interlaced -> rows 2/3
                AND     M2M$SYS_CORE_FL_INT, R0
                RBRA    _DSM_DEB, Z
                ADD     SCR_LACE_ADD, R7
                RBRA    _DSM_DEB, 1
_DSM_UNK        MOVE    SCR_MODE_UNKNOWN, R7    ; = 4

                ; --- debounce: SCR_DEBOUNCE stable reads before acting ---
_DSM_DEB        MOVE    SCR_CAND_MODE, R0
                CMP     @R0, R7                 ; same as the candidate?
                RBRA    _DSM_SAME, Z
                MOVE    R7, @R0                 ; no: restart the candidate
                MOVE    SCR_CAND_CNT, R0
                MOVE    0, @R0
                RBRA    _DSM_RET, 1
_DSM_SAME       MOVE    SCR_CAND_CNT, R0
                CMP     SCR_DEBOUNCE, @R0       ; count < DEBOUNCE -> settling
                RBRA    _DSM_SETTLE, N
                MOVE    SCR_APPLIED_MODE, R0
                CMP     @R0, R7                 ; already the applied mode?
                RBRA    _DSM_RET, Z
                MOVE    R7, @R0                 ; latch the newly applied mode
                RBRA    _DSM_APPLY, 1
_DSM_SETTLE     MOVE    SCR_CAND_CNT, R0
                ADD     1, @R0
                RBRA    _DSM_RET, 1

                ; --- apply mode R7: push offsets to the CFD, then log ---
_DSM_APPLY      CMP     SCR_MODE_UNKNOWN, R7
                RBRA    _DSM_KNOWN, !Z
                MOVE    SCR_ROW_WORDS, R2       ; unknown: push 10 zeros = all off
                MOVE    SCR_CFD_VGA, R9         ; CFD words 0..9 (overscan 0..3,
_DSM_ZLOOP      XOR     R8, R8                  ;  HDMI 4..7, pan 8..9)
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_ZLOOP, !Z
                MOVE    MSG_SCR_UNSUP, R8
                SYSCALL(puts, 1)
                RBRA    _DSM_LOGGEO, 1

_DSM_KNOWN      MOVE    R7, R0                  ; row offset = mode * SCR_ROW_WORDS
                ADD     R0, R0                  ; (= *10: *2, keep, *8, add)
                MOVE    R0, R1                  ; R1 = mode * 2
                ADD     R0, R0
                ADD     R0, R0                  ; R0 = mode * 8
                ADD     R1, R0                  ; R0 = mode * 10
                ADD     SCR_TABLE, R0           ; R0 -> table row (10 words)
                MOVE    R0, R3                  ; keep the row ptr for the log
                ; push the HDMI half (row words 0..3) -> CFD words 4..7
                MOVE    SCR_HALF_WORDS, R2
                MOVE    SCR_CFD_HDMI, R9
_DSM_PLOOPH     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPH, !Z
                ; push the overscan half (row words 4..7) -> CFD words 0..3
                MOVE    SCR_HALF_WORDS, R2      ; R0 now points at the overscan half
                MOVE    SCR_CFD_VGA, R9
_DSM_PLOOPV     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPV, !Z
                ; push the pan pair (row words 8..9) -> CFD words 8..9
                MOVE    SCR_PAN_WORDS, R2
                MOVE    SCR_CFD_PAN, R9
_DSM_PLOOPP     MOVE    @R0++, R8
                RSUB    _LSO_CFDW, 1
                ADD     1, R9
                SUB     1, R2
                RBRA    _DSM_PLOOPP, !Z
                MOVE    MSG_SCR_PFX, R8         ; "Screen: Amiga mode "
                SYSCALL(puts, 1)
                MOVE    R7, R0                  ; LORES / HIRES
                AND     SCR_HIRES_BIT, R0
                RBRA    _DSM_LHIR, !Z
                MOVE    MSG_SCR_LORES, R8
                RBRA    _DSM_LHPUT, 1
_DSM_LHIR       MOVE    MSG_SCR_HIRES, R8
_DSM_LHPUT      SYSCALL(puts, 1)
                MOVE    R6, R0                  ; PROGRESSIVE / INTERLACED
                AND     M2M$SYS_CORE_FL_INT, R0
                RBRA    _DSM_LLAC, !Z
                MOVE    MSG_SCR_PROG, R8
                RBRA    _DSM_LSPUT, 1
_DSM_LLAC       MOVE    MSG_SCR_LACE, R8
_DSM_LSPUT      SYSCALL(puts, 1)

_DSM_LOGGEO     MOVE    MSG_SCR_GEO1, R8        ; "  (hdmax="
                SYSCALL(puts, 1)
                MOVE    R4, R8
                RSUB    _SCR_LOGDEC, 1
                MOVE    MSG_SCR_GEO2, R8        ; " vdmax="
                SYSCALL(puts, 1)
                MOVE    R5, R8
                RSUB    _SCR_LOGDEC, 1
                MOVE    MSG_SCR_GEO3, R8        ; ")"
                SYSCALL(puts, 1)
                SYSCALL(crlf, 1)
                CMP     SCR_MODE_UNKNOWN, R7    ; unknown: no offset lines
                RBRA    _DSM_RET, Z
                MOVE    R3, R0                  ; row ptr -> HDMI half then VGA half
                ; --- line "HDMI:": ascal input-crop offsets (row words 0..3) ---
                MOVE    MSG_SCR_HDMI, R8        ; "HDMI: himin="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF2, R8        ; " himax="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF3, R8        ; " vimin="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_OFF4, R8        ; " vimax="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                SYSCALL(crlf, 1)
                ; --- line "Analog:": overscan (row words 4..7) + pan (8..9) ---
                MOVE    MSG_SCR_VGA, R8         ; "Analog: os_l="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF2, R8        ; " os_r="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF3, R8        ; " os_t="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF4, R8        ; " os_b="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF5, R8        ; " pan_x="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                MOVE    MSG_SCR_VOF6, R8        ; " pan_y="
                SYSCALL(puts, 1)
                MOVE    @R0++, R8
                RSUB    _SCR_LOGSDEC, 1
                SYSCALL(crlf, 1)

_DSM_RET        SYSCALL(leave, 1)
                RET

; log the unsigned value in R8 as decimal on the serial UART
_SCR_LOGDEC     SYSCALL(enter, 1)
                XOR     R9, R9                  ; high word = 0
                SUB     11, SP                  ; scratch decimal-string buffer
                MOVE    SP, R10
                SYSCALL(h2dstr, 1)              ; R11 -> decimal string
                MOVE    R11, R8
                SYSCALL(puts, 1)
                ADD     11, SP
                SYSCALL(leave, 1)
                RET

; log the signed value in R8 as decimal with an explicit +/- sign
_SCR_LOGSDEC    SYSCALL(enter, 1)
                MOVE    R8, R0                  ; keep the value
                AND     0x8000, R8              ; negative?
                RBRA    _SLS_NEG, !Z
                MOVE    0x002B, R8              ; '+'
                SYSCALL(putc, 1)
                MOVE    R0, R8
                RBRA    _SLS_MAG, 1
_SLS_NEG        MOVE    0x002D, R8              ; '-'
                SYSCALL(putc, 1)
                MOVE    R0, R8
                XOR     0xFFFF, R8              ; magnitude = -value
                ADD     1, R8
_SLS_MAG        RSUB    _SCR_LOGDEC, 1
                SYSCALL(leave, 1)
                RET

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

; OSM menu constants are autogenerated by make_rom.sh (like in C64MEGA65):
; the AEXP_OSM_* line numbers are scraped from the C_MENU_* constants in
; ../vhdl/mega65.vhd and the AEXP_OPTM_G_* group ids from the OPTM_G_*
; constants in ../vhdl/config.vhd -- no hardcoded menu indexes here.
#include "osm_const.asm"

; ADF file extension (needs to be upper case)
ADF_FILE_EXT    .ASCII_W ".ADF"

; ADF write-back CSR (WBC): one instance per simulated drive, behind the device
; of that drive (AEXP_DEV_ADF0/1/2, autogenerated into osm_const.asm from
; globals.vhd), 4k window 0xFFFE - register map defined in
; CORE/vhdl/adf_mount_wrapper.vhd (keep in sync!). The register OFFSETS are the
; same for every drive; only the device id differs, which is what ADF_SEL_WBC
; encapsulates.
ADF_WBC_4KWIN   .EQU    0xFFFE              ; the write-back CSR window
ADF_WBC_CTRL    .EQU    0x7000              ; bit 0: WR_EN (this unit writable)
ADF_WBC_STAT    .EQU    0x7001              ; bit 0: any_dirty  bit 1: flush_start
ADF_WBC_ATDELAY .EQU    0x7002              ; anti-thrashing delay in ms
ADF_WBC_DIRTY0  .EQU    0x7010              ; ..0x701A: dirty bitmap, W1C
ADF_WBC_DIRTY_W .EQU    11                  ; bitmap words (166 tracks -> 11)
ADF_TRACK_BYTES .EQU    5632                ; 11 sectors x 512 bytes
ADF_FLUSH_CHUNK .EQU    512                 ; bytes per background time slice

; Number of simulated Amiga drive units. The index 0..2 is at the same time the
; Amiga unit (df0/df1/df2), the manual CRT/ROM id of the Shell - and therefore
; the index into HNDL_RM_FILES - and the index into the three tables below.
; This identity is what the whole per-drive write-back rests on; it holds
; because the three OPTM_G_LOAD_ROM mount lines sit in that order in the static
; OPTM_GROUPS array of config.vhd (a manual CRT/ROM line is bound to its id by
; POSITION, and hiding a line through a menu dependency does not renumber the
; others).
ADF_DRIVES      .EQU    3

; Return codes of FLUSH_ADF_STEP
ADF_FL_IDLE     .EQU    0                   ; clean and idle, nothing left
ADF_FL_DID      .EQU    1                   ; work remains, slice consumed
ADF_FL_GATED    .EQU    2                   ; work remains, anti-thrash gate shut

; Per-drive tables, indexed by the drive 0..2. The only place in the firmware
; that knows how a drive maps to a QNICE device, to its own retained file
; handle and to its mount menu group.
ADF_DEV_TAB     .DW AEXP_DEV_ADF0, AEXP_DEV_ADF1, AEXP_DEV_ADF2
ADF_FDH_TAB     .DW ADF_FDH0, ADF_FDH1, ADF_FDH2
ADF_GRP_TAB     .DW AEXP_OPTM_G_ADF0, AEXP_OPTM_G_ADF1, AEXP_OPTM_G_ADF2

; Flat main-menu indexes of the twin lines of each drive, scraped from the
; C_MENU_*_LN constants of mega65.vhd - the mount line and its Hardware Floppy
; TEXT twin. Cross-checked against the item text by check_osm_menu.py.
ADF_MNT_LN_TAB  .DW AEXP_OSM_DF0_MOUNT_LN, AEXP_OSM_DF1_MOUNT_LN, AEXP_OSM_DF2_MOUNT_LN
ADF_HW_LN_TAB   .DW AEXP_OSM_DF0_HW_LN, AEXP_OSM_DF1_HW_LN, AEXP_OSM_DF2_HW_LN

; Hardware Floppy diagnostics: device C_DEV_AMIGA_FDD (globals.vhd), a read-only
; register bank in CORE/vhdl/physical_fdd/physical_fdd_diag.vhd. It decodes
; addr[5:0] only, so the 4k window is irrelevant and the register number is the
; offset into the data window. Only the two registers the status line needs are
; named here; the full map lives in the header of that file (keep in sync!).
AEXP_DEV_FDD    .EQU    0x0104              ; the diagnostics bank
HWF_DIAG_STAT   .EQU    0x7002              ; front-end status word
HWF_DIAG_SERVED .EQU    0x701B              ; words served into Paula (0x1B)
HWF_ST_MOTOR    .EQU    0x0004              ; status bit 2: the motor runs

; Live status line states. The order is the index into HWF_OSM_STR.
HWF_OS_IDLE     .EQU    0
HWF_OS_MOTOR    .EQU    1
HWF_OS_READ     .EQU    2
HWF_OS_INVALID  .EQU    0xFFFF              ; nothing painted; repaint at once
HWF_DRV_NONE    .EQU    0xFFFF              ; no drive owns the mechanism

HWF_OSM_POLL_MASK .EQU  0x0007              ; 763 Hz / 8 = about 95 Hz
HWF_LABEL_LEN   .EQU    22                  ; characters after the marker
HWF_LABEL_DIGIT .EQU    2                   ; the N of "dfN:" in the label
HWF_ASCII_ZERO  .EQU    0x0030

; The three status labels, each EXACTLY HWF_LABEL_LEN characters so that the
; previous text is always fully erased. The idle label is byte-identical to the
; static line in config.vhd, which makes painting it a visual no-op. The drive
; digit is patched in at runtime (HWF_LABEL_DIGIT), so one set covers all three
; drives.
HWF_OSM_STR     .DW HWF_OSM_IDLE, HWF_OSM_MOTOR, HWF_OSM_READ
HWF_OSM_IDLE    .ASCII_W "df0:Hardware Floppy   "
HWF_OSM_MOTOR   .ASCII_W "df0:HW Floppy: Motor  "
HWF_OSM_READ    .ASCII_W "df0:HW Floppy: Reading"

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

; Mount warnings, returned by PREP_LOAD_IMAGE as error message strings. The
; Shell prints them after "Error code: <code>" and then appends its own
; "Press Space to continue." prompt (_HM_SDMOUNTED5S in M2M/rom/shell.asm),
; so the strings must not contain such a prompt themselves. The trailing
; newline leaves one empty line between the message and the Shell prompt.

; Warning: file size out of the valid ADF range
WRN_ADF_SIZE    .ASCII_P "\n\nThis is not a valid ADF disk image:\n"
                .ASCII_P "the file size must be 901,120 bytes\n"
                .ASCII_P "(880 KB standard ADF; 81..83-track over-\n"
                .ASCII_W "dumps up to 934,912 bytes are accepted).\n"

; Warning: could not write back the current disk before mounting a new one
WRN_ADF_BUSY    .ASCII_P "\n\nUnsaved changes on the current disk\n"
                .ASCII_P "could not be written back because the\n"
                .ASCII_P "Amiga keeps writing to the drive.\n"
                .ASCII_W "Stop the disk activity, then try again.\n"

; Warning: the same image file is already mounted in another drive
WRN_ADF_DUP     .ASCII_P "\n\nThis disk image is already in another\n"
                .ASCII_P "drive. One file cannot serve two drives\n"
                .ASCII_P "at once: each drive collects its own\n"
                .ASCII_P "changes and would save them over the\n"
                .ASCII_W "changes of the other one.\n"

; Fatal: SD card write failed during the ADF write-back
ERR_ADF_FLUSH   .ASCII_W "ADF write-back: writing to the SD card failed.\n"

; Screen centering (issue #5): per-Amiga-mode HDMI input-crop + VGA soft-blank table.
; File name, table geometry, mode indices and the serial-log strings. The four
; rows (lores-prog, hires-prog, lores-lace, hires-lace) default to all zeros
; (no centering) until /amiga/aexp_screen.cfg provides tuned values.
SCR_FILE_NAME     .ASCII_W "/amiga/aexp_screen.cfg"

; Momentary "Reload Screen Config" busy label (issue #19). SCR$PRINTSTR renders
; the < > as the arrow glyphs of the framework (same look as <Mount>/<Load>). It
; is exactly OPTM_DX (23) characters, so printed at the left edge of the content
; it fills the whole width; it is shown while the SD re-mount + reload runs and
; then OPTM_SHOW repaints it away.
SCR_LOADING_STR   .ASCII_W "<Loading Screen Config>"

SCR_MODES         .EQU 4                  ; table rows (file "count" byte)
SCR_TABLE_WORDS   .EQU 40                 ; 4 rows x 10 words (HDMI 4 + overscan 4 + pan 2)
SCR_MODE_UNKNOWN  .EQU 4                  ; detected mode outside the table
SCR_MODE_NONE     .EQU 0xFFFF             ; "nothing applied yet" latch value
SCR_DEBOUNCE      .EQU 3                  ; stable detects before a mode change
                                          ; (detect is throttled, so these span
                                          ; frames -- keep it small)
SCR_TICK_MASK     .EQU 0x00FF             ; run DETECT_SCREEN_MODE every 256th poll

SCR_CFD_HDMI      .EQU 4                  ; HDMI-offset CFD gp_reg words (4..7)
SCR_CFD_VGA       .EQU 0                  ; analog-overscan CFD gp_reg words (0..3)
SCR_CFD_PAN       .EQU 8                  ; analog-pan CFD gp_reg words (8..9)
SCR_ROW_WORDS     .EQU 10                 ; words per mode row (HDMI 4 + overscan 4 + pan 2)
SCR_HALF_WORDS    .EQU 4                  ; edge offsets per output group
SCR_V3_WORDS      .EQU 8                  ; row words shared by v3 and v4 (before pan)
SCR_PAN_WORDS     .EQU 2                  ; pan words per row (v4 only)
SCR_VER_V3        .EQU 3                  ; legacy file: no pan words (pan = 0)
SCR_VER_V4        .EQU 4                  ; current file: overscan + pan per row
SCR_HIRES_BIT     .EQU 1                  ; mode bit 0: 1 = hires horizontal
SCR_LACE_ADD      .EQU 2                  ; mode += 2 when interlaced (rows 2/3)

; hdmax (ascal-measured, +1) classification. OCS PAL geometry is deterministic
; (fixed Agnus beam constants: lores ~377/378, hires ~754/755, only +/-1..2
; ce-phase rounding), so the windows are tight (+/-~10 px). An unexpected geometry
; (a genuinely new/unknown mode) is thus flagged "unsupported" rather than forced
; into lores/hires. The raw hdmax is always logged, so if a board ever measures
; outside a window it is a one-line retune (the logged value +/-10). Windows are
; half-open [lo, hi) to match MTH$IN_RANGE_U.
SCR_HDMAX_NOSIG   .EQU 200                ; hdmax < 200: no video yet -> skip
SCR_LORES_LO      .EQU 367                ; lores hdmax window [367, 388) (~377/378)
SCR_LORES_HI      .EQU 388
SCR_HIRES_LO      .EQU 744                ; hires hdmax window [744, 765) (~754/755)
SCR_HIRES_HI      .EQU 765

; serial-terminal (UART) log strings, MiSTer-style "new mode detected" trace
MSG_SCR_PFX       .ASCII_W "Screen: Amiga mode "
MSG_SCR_LORES     .ASCII_W "LORES"
MSG_SCR_HIRES     .ASCII_W "HIRES"
MSG_SCR_PROG      .ASCII_W " PROGRESSIVE"
MSG_SCR_LACE      .ASCII_W " INTERLACED"
MSG_SCR_GEO1      .ASCII_W "  (hdmax="
MSG_SCR_GEO2      .ASCII_W " vdmax="
MSG_SCR_GEO3      .ASCII_W ")"
MSG_SCR_HDMI      .ASCII_W "  HDMI: himin="
MSG_SCR_OFF2      .ASCII_W " himax="
MSG_SCR_OFF3      .ASCII_W " vimin="
MSG_SCR_OFF4      .ASCII_W " vimax="
MSG_SCR_VGA       .ASCII_W "  Analog: os_l="
MSG_SCR_VOF2      .ASCII_W " os_r="
MSG_SCR_VOF3      .ASCII_W " os_t="
MSG_SCR_VOF4      .ASCII_W " os_b="
MSG_SCR_VOF5      .ASCII_W " pan_x="
MSG_SCR_VOF6      .ASCII_W " pan_y="
MSG_SCR_UNSUP     .ASCII_W "screen: unsupported mode, adjustments disabled"

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

; ADF write-back state (see HANDLE_CORE_IO / FLUSH_ADF_STEP). Everything here
; is PER DRIVE: the scalars are three-word arrays indexed by the drive 0..2,
; and each drive owns a full file-handle snapshot of its own. That per-drive
; handle is the whole point - a single shared handle plus a second armed drive
; would flush the tracks of one drive into the file of another.
ADF_FDH0        .BLOCK FAT32$FDH_STRUCT_SIZE    ; our own snapshot of the file
ADF_FDH1        .BLOCK FAT32$FDH_STRUCT_SIZE    ; handle mounted into each
ADF_FDH2        .BLOCK FAT32$FDH_STRUCT_SIZE    ; drive: HNDL_RM_FILES[n] is
                                                ; re-opened by the Shell for
                                                ; the NEXT load, our snapshot
                                                ; stays valid until the card
                                                ; or the SD slot changes
                                                ; (reached via ADF_FDH_TAB)
ADF_FDH_VALID   .BLOCK ADF_DRIVES               ; 1: the FDH of that drive is
                                                ; usable, i.e. armed
ADF_SD_SLOT     .BLOCK ADF_DRIVES               ; active SD slot at arm time
ADF_MOUNT_SEEN  .BLOCK ADF_DRIVES               ; 1: armed or blocked; 0: a
                                                ; fresh PARSEST=READY may arm
ADF_FL_STATE    .BLOCK ADF_DRIVES               ; 0: idle  1: track session
ADF_FL_REMAIN   .BLOCK ADF_DRIVES               ; bytes left in session track
ADF_FL_BADDR_LO .BLOCK ADF_DRIVES               ; session byte address within
ADF_FL_BADDR_HI .BLOCK ADF_DRIVES               ; image and file (32 bit)
ADF_FL_RR       .BLOCK 1                        ; drive that gets the next
                                                ; background flush time slice

; ADF unmount-with-SPACE state (issue #16, see HANDLE_UNMOUNT_KEY)
ADF_UNMNT_PREV  .BLOCK 1                        ; SPACE state last poll (edge)
OSM_SUB_ACTIVE  .BLOCK 1                        ; 1 while the sub-activity of a
                                                ; menu selection (browser/help)
                                                ; runs: gate 4 for the unmount

; Screen adjustment (issue #5): file handle for /amiga/aexp_screen.cfg
SCR_FDH    .BLOCK FAT32$FDH_STRUCT_SIZE
; per-Amiga-mode table (loaded by LOAD_SCREEN_OFFSETS, applied by
; DETECT_SCREEN_MODE): 4 rows x 10 signed words = HDMI crop
; (himin,himax,vimin,vimax), analog overscan (os_l,os_r,os_t,os_b),
; analog pan (pan_x,pan_y)
SCR_TABLE        .BLOCK 40                       ; 4 mode rows x 10 words (HDMI 4 + overscan 4 + pan 2)
SCR_APPLIED_MODE .BLOCK 1                        ; 0..3 row / 4 unknown / NONE
SCR_CAND_MODE    .BLOCK 1                        ; debounce candidate mode
SCR_CAND_CNT     .BLOCK 1                        ; debounce counter
SCR_TICK         .BLOCK 1                        ; detector throttle counter

; Live Hardware Floppy status line (see HANDLE_CORE_IO / HWF_STATUS_STEP)
HWF_OSM_LAST    .BLOCK 1                        ; last painted coarse state,
                                                ; HWF_OS_INVALID = none
HWF_OSM_LDRV    .BLOCK 1                        ; drive whose line was painted
                                                ; last, HWF_DRV_NONE = none
HWF_OSM_TICK    .BLOCK 1                        ; last IO$CYC_MID value seen
HWF_LAST_CNT    .BLOCK 1                        ; served-word count last poll
HWF_LABEL       .BLOCK 23                       ; the built label: 22 chars
                                                ; plus the terminator

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
; Example: If your HEAP_SIZE would be 30208, then you write 30208-1920=28288
; instead, but when doing the sanity check calculations, you use 30208
;
; Budget (HELP_MENU in M2M/rom/options.asm, checked at runtime by LOG_HEAP1/
; LOG_HEAP2): the 146 menu items are a 1392-character string plus the 20-word
; menu structure plus FOUR per-item arrays = 20 + 1392 + 1 + 4 x 146 + 1 =
; 1998 words; on top of that, OPTM_HEAP needs one (OPTM_DX + 2)-wide buffer
; per submenu (8), manual ROM (3) and vdrive (0) plus one scratch buffer =
; 12 x 25 = 300 words. Total demand is 2298 words, rounded up to the next
; 128-word boundary: 2304 words, leaving 6 words headroom. Do not reserve a
; large safety margin here: every word is taken directly from the file-browser
; heap. Whenever OPTM_SIZE, OPTM_ITEMS, OPTM_DX, or the submenu/drive/
; manual-ROM counts grow, recalculate both budgets and rebalance the
; HEAP_SIZE constants below by the same delta.
; .research/check_osm_menu.py recomputes all of this from config.vhd.
;
; HELP_MENU_INIT additionally borrows 20 + 3 x 146 = 458 words of this region
; as transient scratch for the boot-time dependency validation (_HLP_DEPVAL in
; M2M/rom/options.asm) - far below the permanent demand, so it never binds.
;
; The fourth per-item array and the 19th->20th structure word are the menu
; dependency feature (M2M-UPSTREAM osm-deps); the manual-ROM count grew from
; 1 to 3 with the second and third simulated floppy drive.
MENU_HEAP_SIZE  .EQU 2304

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
; The combined total (HEAP_SIZE + MENU_HEAP_SIZE) was lowered from the C64
; figure of 30208 to 30080 words when the per-drive write-back and the live
; Hardware Floppy status line added 66 words of firmware VARIABLES: those sit
; below the heap, so they push HEAP up and eat directly into the space that is
; left for the stack between the end of the heap and VAR$STACK_START. Check it
; the way hard rule 11 of AGENTS.md describes, in the assembled m2m-rom.lis:
; HEAP 0x8280 + 30080 = 0xF800, VAR$STACK_START 0xFEE0, so 1760 words remain
; for a STACK_SIZE of 1536 - a 224-word margin, slightly better than the 1728
; words the 30208 total used to leave.
HEAP_SIZE       .EQU 4736                       ; 7040 - 2304 = 4736
HEAP            .BLOCK 1

; in RELEASE mode: 27.125k of heap for folders with many files
#else

HEAP_SIZE       .EQU 27776                      ; 30080 - 2304 = 27776
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 30208 words to HEAP which
; is currently 0x8220 and subtract the result from 0xFEE0. This yields
; 1728 stack words, 192 more than STACK_SIZE. Recheck the HEAP and
; VAR$STACK_START addresses in m2m-rom.lis whenever variables are added.

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
