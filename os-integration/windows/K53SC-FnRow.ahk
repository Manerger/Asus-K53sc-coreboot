#Requires AutoHotkey v2.0
#SingleInstance Force
;
; ASUS K53SC - function row behaviour, Windows equivalent of the Linux setup.
;
; The media row is the DEFAULT (the keys carry those icons); tapping Fn on its
; own flips the whole row to real F1-F12 and back.
;
; Why a script is needed at all
; -----------------------------
; This unit's EC adjusts brightness privately through its own LCD_BL_PWM output
; and never raises the ACPI queries the DSDT declares for it - they are
; vestigial on this machine. So no OS gets told about Fn+F5/F6, on Windows or
; Linux. The keypress does reach the OS as a plain function key, which is what
; this remaps.
;
; Scancodes measured on the hardware (Linux MSC_SCAN == set-1 scancodes):
;   F1 sc03B  F2 sc03C  F3 sc03D  F4 sc03E  F5 sc03F  F6 sc040
;   F7 sc041  F8 sc042  F9 sc043  F10 sc044 F11 sc057 F12 sc058
;   Fn tapped alone -> sc050 then sc051, ~5 ms apart, no keycode of its own
;   Fn+F5 and Fn+F6 -> sc023 then sc014, IDENTICAL to each other, so the Fn
;                      layer can never address those two keys individually
;
; F1/F2 are deliberately NOT remapped: sleep and wifi-kill are destructive if
; hit by accident. On Linux they remain on Fn+F1/Fn+F2 via the EC's own ACPI
; path; on Windows the ASUS ATK driver handles them the same way if installed.
;
; CAVEAT worth checking on your machine: sc050/sc051 are also Numpad2/Numpad3
; in set-1. If the Fn tap misfires while using the numeric keypad, raise
; PAIR_WINDOW_MS or drop the Fn-tap toggle and bind ToggleRow() to a spare key.

global MediaMode := true            ; start in media mode, like the Linux hwdb
global FnFirstSeen := 0
PAIR_WINDOW_MS := 60                ; sc050 -> sc051 arrive ~5 ms apart
SETTLE_MS      := 300               ; a combo's action follows within ~190 ms

; ---------------------------------------------------------------- brightness
GetBrightness() {
    for m in ComObjGet("winmgmts:\\.\root\WMI").ExecQuery("SELECT * FROM WmiMonitorBrightness")
        return m.CurrentBrightness
    return -1
}
SetBrightness(pct) {
    pct := Max(0, Min(100, pct))
    for m in ComObjGet("winmgmts:\\.\root\WMI").ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods")
        m.WmiSetBrightness(1, pct)
}
StepBrightness(delta) {
    cur := GetBrightness()
    if (cur < 0) {
        ToolTip "Brightness not exposed via WMI on this panel"
        SetTimer () => ToolTip(), -1500
        return
    }
    SetBrightness(cur + delta)
}

; ------------------------------------------------------------ display on/off
global SavedBrightness := 0
ToggleDisplay() {
    global SavedBrightness
    cur := GetBrightness()
    if (cur > 0) {
        SavedBrightness := cur
        SetBrightness(0)
    } else {
        SetBrightness(SavedBrightness > 0 ? SavedBrightness : 60)
    }
}

; ------------------------------------------------------------------ the row
ToggleRow() {
    global MediaMode
    MediaMode := !MediaMode
    ToolTip(MediaMode ? "Function row: media" : "Function row: F1-F12")
    SetTimer () => ToolTip(), -1200
}

; Fn tap detection: the pair, followed by nothing at all
FnSettled() {
    global FnFirstSeen
    FnFirstSeen := 0
    ToggleRow()
}
*sc050:: {
    global FnFirstSeen
    FnFirstSeen := A_TickCount
}
*sc051:: {
    global FnFirstSeen, PAIR_WINDOW_MS, SETTLE_MS
    if (FnFirstSeen && A_TickCount - FnFirstSeen < PAIR_WINDOW_MS)
        SetTimer FnSettled, -SETTLE_MS      ; any other key cancels it below
    else
        FnFirstSeen := 0
}
CancelFn() {
    SetTimer FnSettled, 0
    global FnFirstSeen
    FnFirstSeen := 0
}

; ------------------------------------------------------------- the F-row map
; Each key: if in media mode do the media action, else pass the real F-key.
Row(fkey, action) {
    CancelFn()                       ; a real keypress means Fn was a modifier
    if (MediaMode)
        action.Call()
    else
        Send "{" fkey "}"
}

sc03F::Row("F5", () => StepBrightness(-10))
sc040::Row("F6", () => StepBrightness(+10))
sc041::Row("F7", ToggleDisplay)
sc042::Row("F8", () => Send("#p"))                 ; projector / display switch
sc043::Row("F9", () => ToolTip("Touchpad toggle: use Windows settings"))
sc044::Row("F10", () => Send("{Volume_Mute}"))
sc057::Row("F11", () => Send("{Volume_Down}"))
sc058::Row("F12", () => Send("{Volume_Up}"))

; F1-F4 pass through untouched (F1/F2 deliberately, F3/F4 unlabelled here)
