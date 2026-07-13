# The Keyboard: Typing on the Amiga with your MEGA65

The MEGA65 and the Amiga 500 have almost the same keyboard — but not quite.
Both are classic full-travel keyboards with a similar layout, yet the keys are
lettered a little differently and a few caps sit in different places. AExp
bridges that gap for you, and it even lets you choose **how** it bridges it.

This guide explains, in plain terms, how the MEGA65 keyboard drives the Amiga,
how to type every Amiga character, and how to change the mapping to suit the way
you think about the keyboard.

If you only remember one sentence, make it this one:

> **In the default mode, you get the character printed on the MEGA65 keycap.**
> Press the key that shows `@`, and the Amiga receives `@`.

---

## Two ways to map the keyboard

AExp offers **two keyboard modes**, and you pick the one that matches how you
think or how the software you are working with expects the keyboard to react.
Some games (for example Pinball Dreams) do not like our function key mapping.
Switch to the Amiga mode and enjoy the game. You can switch between the keyboard
modes in real-time.

### MEGA65 mode — "the cap is law" (default)

This is the friendly default. **Whatever is printed on the MEGA65 key, that is
what the Amiga gets.** The MEGA65 keycaps carry up to three legends:

* the **main** legend (what you get on its own),
* the **upper** legend (what you get with <kbd>Shift</kbd>),
* the small **front-face** legend on the slanted front of the cap (what you get
  with the <kbd>MEGA</kbd> key — the Commodore/`C=` key).

AExp reproduces all three. So if the cap shows `{` on its front face, then
<kbd>MEGA</kbd> + that key types `{` on the Amiga — even though the Amiga's own
keyboard would make `{` a completely different way. You never have to learn the
Amiga's keyboard: you just read your MEGA65 caps.

This mode is the right choice for almost everyone, and especially if the MEGA65
is the keyboard you know.

### Amiga mode — "same position as a real Amiga"

This mode is **positional**. Each MEGA65 key sends the Amiga key code of the key
that sits in the **same place** on a real Amiga keyboard. The characters then
follow the *Amiga's* own labelling, not the MEGA65's.

The practical difference shows up on the shifted number row and a handful of
punctuation keys. On a real Amiga, <kbd>Shift</kbd>+<kbd>2</kbd> is `@` (not
`"`), <kbd>Shift</kbd>+<kbd>6</kbd> is `^`, <kbd>Shift</kbd>+<kbd>7</kbd> is `&`,
and so on. In Amiga mode you get those Amiga characters, because your fingers are
"standing on" the Amiga keys.

Choose this mode if you grew up on an Amiga and your muscle memory expects the
Amiga layout, or if you are following instructions written for a real Amiga
(some demos and old manuals assume the Amiga's own keymap) or if you run into
trouble with the MEGA65 mode in some games (see above, example Pinball Dreams).

The reference for Amiga mode is
[deft's "custom caps" layout (click here to see it)](assets/keyboard.png)
drawn from a British Amiga A600. A couple of its keys are *functions*, not
letters — notably <kbd>CLR/HOME</kbd>, which is the Amiga <kbd>&larr;</kbd>
(Backspace) key: it deletes to the left. The "←" printed on that reference
cap is the Backspace symbol, not a character you can print.

The function-key row, the modifier keys, the right mouse button and Caps/Shift
Lock all work differently in this mode — see **Amiga mode in detail**, below, for
the full picture.

> **The Amiga's keymap has the final say — including on the pound sign.** AExp
> only sends the Amiga raw key codes; which *character* each one becomes is chosen
> by the keymap the Amiga has loaded. Out of the box that is the **US keymap**
> built into Kickstart 1.3, so <kbd>Shift</kbd>+<kbd>3</kbd> = `#` and there is
> **no `£`** — it isn't on the US layout at all (the glyph lives in the Amiga
> font, but nothing on the US keyboard types it). deft's layout, though, is a
> British Amiga (`£` on the `3` key). To reproduce it exactly — `£` on
> <kbd>Shift</kbd>+<kbd>3</kbd>, `@` on <kbd>Shift</kbd>+<kbd>;</kbd> — load the
> British keymap on the Amiga side with **`SetMap gb`** (from a Workbench boot; it
> needs `DEVS:Keymaps/gb`). A game or demo that boots without Workbench stays on
> the US keymap. AExp can't pick the keymap for you — on a real Amiga that was
> always the software's job.

---

## Typing every symbol in MEGA65 mode

Because MEGA65 mode is the default and the one most people use, here is the
complete "how do I type that?" table. Read it as: *press these MEGA65 keys, get
this Amiga character.* Letters and the plain digits work exactly as printed, so
they are not repeated here.

### The shifted number row

| You press                                   | Amiga gets |
|---------------------------------------------|:----------:|
| <kbd>Shift</kbd>+<kbd>1</kbd>               | `!`        |
| <kbd>Shift</kbd>+<kbd>2</kbd>               | `"`        |
| <kbd>Shift</kbd>+<kbd>3</kbd>               | `#`        |
| <kbd>Shift</kbd>+<kbd>4</kbd>               | `$`        |
| <kbd>Shift</kbd>+<kbd>5</kbd>               | `%`        |
| <kbd>Shift</kbd>+<kbd>6</kbd>               | `&`        |
| <kbd>Shift</kbd>+<kbd>7</kbd>               | `'`        |
| <kbd>Shift</kbd>+<kbd>8</kbd>               | `(`        |
| <kbd>Shift</kbd>+<kbd>9</kbd>               | `)`        |

Every one of these is simply the symbol printed on the top of the MEGA65 key.
The cap is law.

### The punctuation and symbol keys

Several MEGA65 keys carry a front-face symbol. Hold <kbd>MEGA</kbd> to type it.

| MEGA65 key            | On its own | With <kbd>Shift</kbd> | With <kbd>MEGA</kbd> |
|-----------------------|:----------:|:---------------------:|:--------------------:|
| <kbd>,</kbd>          | `,`        | `<`                   | `~`                  |
| <kbd>.</kbd>          | `.`        | `>`                   | <code>&#124;</code>  |
| <kbd>/</kbd>          | `/`        | `?`                   | `\`                  |
| <kbd>:</kbd>          | `:`        | `[`                   | `{`                  |
| <kbd>;</kbd>          | `;`        | `]`                   | `}`                  |
| <kbd>=</kbd>          | `=`        | `_`                   | `_`                  |
| <kbd>@</kbd>          | `@`        | —                     | `@`                  |
| <kbd>&larr;</kbd> (top-left) | `_` | <code>&#96;</code>    | <code>&#96;</code>   |
| <kbd>&uarr;</kbd>     | `^`        | —                     | —                    |
| <kbd>*</kbd>          | `*`        | —                     | —                    |
| <kbd>+</kbd>          | `+`        |                       |                      |
| <kbd>&minus;</kbd>    | `-`        |                       |                      |
| <kbd>&pound;</kbd>    | `\`        |                       |                      |

A few friendly notes on this table:

* **Curly braces** are `{` = <kbd>MEGA</kbd>+<kbd>:</kbd> and `}` =
  <kbd>MEGA</kbd>+<kbd>;</kbd>, exactly as the little front-face legends show.
  **Square brackets** are the <kbd>Shift</kbd> legends on the same two keys:
  `[` = <kbd>Shift</kbd>+<kbd>:</kbd> and `]` = <kbd>Shift</kbd>+<kbd>;</kbd>.
* The **backslash** `\` can be typed two ways: <kbd>MEGA</kbd>+<kbd>/</kbd> (the
  front-face legend) or the dedicated <kbd>&pound;</kbd> key. Both give `\`,
  because the Amiga's US keymap has no `£`.
* The **underscore** `_` is <kbd>Shift</kbd>+<kbd>=</kbd> or
  <kbd>MEGA</kbd>+<kbd>=</kbd>, and it is also what the top-left
  <kbd>&larr;</kbd> key types on its own.
* The back-tick <code>&#96;</code> lives on the <kbd>&larr;</kbd> key
  (with <kbd>Shift</kbd> or <kbd>MEGA</kbd>).
* **A few of the MEGA65's own symbols simply aren't on the Amiga at all.** The
  Amiga's character set has no printable left-arrow and no `π`, so the
  <kbd>&larr;</kbd> key sends `_` (its ASCII legend) instead of an arrow, and
  <kbd>MEGA</kbd>+<kbd>&uarr;</kbd> sends nothing — there is no such character on
  the Amiga to send. (`£` is the same story from the other side: the glyph exists
  in the Amiga font but not on its US keyboard layout, so the <kbd>&pound;</kbd>
  key sends `\`; see the keymap note under *Amiga mode*, above.)
* A dash `—` means the MEGA65 cap shows a graphic symbol there that the Amiga has
  no character for, so nothing is sent. A blank cell means the key has no such
  legend.

### The keys that were given a helpful job

A handful of MEGA65 keys have no exact Amiga twin, so AExp assigns them the most
natural Amiga meaning:

| MEGA65 key          | Amiga meaning        |
|---------------------|----------------------|
| <kbd>INST/DEL</kbd> | Backspace            |
| <kbd>CLR/HOME</kbd> | Delete               |
| <kbd>&pound;</kbd>  | `\` (backslash)      |
| <kbd>&uarr;</kbd>   | `^` (caret)          |

---

## Amiga mode in detail

In **Amiga mode** the mapping is positional: every key stands where the same key
stands on a real Amiga, following deft's "custom caps" A600 layout. Most of the
keyboard is identical to MEGA65 mode — the visible differences are the shifted
number row, the `: ; @` punctuation (which follow the Amiga's labels), and the
special keys below.

### The function-key row

The MEGA65's top row is longer than the Amiga's, so it maps across positionally:
the five keys to the left of <kbd>F1</kbd> fill in the Amiga's <kbd>Esc</kbd> and
<kbd>F1</kbd>–<kbd>F4</kbd>, and the printed F-keys slide right by two.

| MEGA65 key            | Amiga key |
|-----------------------|-----------|
| <kbd>Run/Stop</kbd>   | **Esc**   |
| <kbd>Esc</kbd>        | F1        |
| <kbd>Alt</kbd>        | F2        |
| <kbd>Caps Lock</kbd>  | F3        |
| <kbd>No Scroll</kbd>  | F4        |
| <kbd>F1</kbd>         | F5        |
| <kbd>F3</kbd>         | F6        |
| <kbd>F5</kbd>         | F7        |
| <kbd>F7</kbd>         | F8        |
| <kbd>F9</kbd>         | F9        |
| <kbd>F11</kbd>        | F10       |
| <kbd>Help</kbd>       | Help      |
| <kbd>F13</kbd>        | Left Alt  |

All ten Amiga function keys are directly reachable, so — unlike MEGA65 mode — you
do **not** use <kbd>Shift</kbd>+F-key for the even ones.

### The modifier keys

All four Amiga modifier keys are reachable in Amiga mode:

| MEGA65 key         | Amiga key   |
|--------------------|-------------|
| <kbd>MEGA</kbd>    | Left Amiga  |
| <kbd>=</kbd>       | Right Amiga |
| <kbd>F13</kbd>     | Left Alt    |
| <kbd>RESTORE</kbd> | Right Alt   |

### Right mouse button, Caps Lock and Shift Lock

Three keys behave specially in Amiga mode, and it is worth knowing why:

* **The right mouse button moves to the <kbd>&uarr;</kbd> key** — the up-arrow
  *symbol* key just left of <kbd>RESTORE</kbd> (not a cursor key). Hold it to
  right-click. It has to move because <kbd>Run/Stop</kbd>, which is the right
  button in MEGA65 mode, is now the Amiga's <kbd>Esc</kbd>.
* **<kbd>Caps Lock</kbd> is F3**, and it acts as a normal momentary key — press
  and release, like any function key. Its keycap LED will still blink on and off
  as you press it; that LED is wired to the keyboard's own controller and cannot
  be switched off by the core. It is purely cosmetic and does nothing on the
  Amiga.
* **<kbd>Shift Lock</kbd> gives you a shift-lock** — it holds the Amiga's Left
  Shift down until you release it. It sits where the Amiga's Caps Lock is, and
  for typing capital letters it does the same job; the only difference is that it
  also shifts the number row. A *true* Amiga Caps Lock (letters only) is not
  separately available in Amiga mode, because the MEGA65 keyboard wires Shift Lock
  and the left <kbd>Shift</kbd> together as a single key. If you want the Amiga's
  own Caps Lock, use **MEGA65 mode**, where the top-row <kbd>Caps Lock</kbd> is
  exactly that.

> **Opening the menu in Amiga mode.** <kbd>F11</kbd> and <kbd>F13</kbd> now send
> Amiga keys too (F10 and Left Alt), so if you use one of them to open the menu it
> also reaches the Amiga. That is usually harmless, but if you want a menu key
> that never touches the Amiga, stay on <kbd>Help</kbd> — or switch to MEGA65
> mode, where <kbd>F11</kbd>/<kbd>F13</kbd> stay "clean".

---

## The special keys

Unless noted, these behave the same in both modes. The keys that **differ in
Amiga mode** — the top-row function keys, <kbd>Run/Stop</kbd>, <kbd>RESTORE</kbd>
and the right-mouse-button key — are covered in *Amiga mode in detail*, above.

| MEGA65 key                                            | Amiga function                          |
|-------------------------------------------------------|-----------------------------------------|
| <kbd>MEGA</kbd>                                       | **Left Amiga** key                      |
| <kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd>    | **Reset** (Ctrl+Left-Amiga+Right-Amiga) |
| <kbd>Ctrl</kbd>                                       | Ctrl                                     |
| <kbd>Tab</kbd>                                        | Tab                                     |
| Cursor keys                                           | Cursor keys                             |
| <kbd>RESTORE</kbd>                                    | Right Amiga · *Amiga mode:* Right Alt   |
| <kbd>Run/Stop</kbd>                                   | Right mouse button (hold) · *Amiga mode:* Esc |
| <kbd>Esc</kbd>                                        | Esc · *Amiga mode:* F1                  |
| <kbd>Caps Lock</kbd>                                  | Caps Lock · *Amiga mode:* F3            |
| <kbd>Alt</kbd>                                        | Left Alt · *Amiga mode:* F2             |
| <kbd>No Scroll</kbd>                                  | Right Alt · *Amiga mode:* F4            |

The famous Amiga three-finger salute — the warm reboot — is
<kbd>Ctrl</kbd>+<kbd>MEGA</kbd>+<kbd>RESTORE</kbd> here, which is exactly the
Amiga's <kbd>Ctrl</kbd>+<kbd>Left&nbsp;Amiga</kbd>+<kbd>Right&nbsp;Amiga</kbd>.

### Function keys

A real Amiga has ten function keys, <kbd>F1</kbd> to <kbd>F10</kbd>. In **MEGA65
mode** the keyboard prints only the odd ones and gets the even ones with
<kbd>Shift</kbd> — just as the MEGA65 caps show:

| You press                       | Amiga gets |
|---------------------------------|:----------:|
| <kbd>F1</kbd> … <kbd>F9</kbd> (odd) | F1, F3, F5, F7, F9 |
| <kbd>Shift</kbd>+<kbd>F1</kbd> … | F2, F4, F6, F8, F10 |

The MEGA65 keys past the Amiga's range — <kbd>F11</kbd> and <kbd>F13</kbd> — send
nothing to the Amiga in MEGA65 mode. That makes them handy for a job of their
own: opening the AExp menu (see below).

In **Amiga mode** the F-keys work differently — all ten are on their own keys and
you never need <kbd>Shift</kbd>. See the function-key table in *Amiga mode in
detail*, above.

### Amiga keys with no MEGA65 twin

The MEGA65 keyboard is a little shorter than an Amiga's on the right-hand side,
and it has no numeric keypad. In **MEGA65 mode** most of those Amiga-only keys
cannot be typed — the exception is **Right Alt**, which is on <kbd>No Scroll</kbd>
(<kbd>Alt</kbd> is Left Alt, and <kbd>No Scroll</kbd> sits just past it). In
**Amiga mode** the mapping is positional, so all four Amiga modifier keys become
reachable: <kbd>MEGA</kbd> = Left Amiga, <kbd>=</kbd> = Right Amiga, <kbd>F13</kbd>
= Left Alt, <kbd>RESTORE</kbd> = Right Alt.

---

## Opening the menu — and freeing the Help key

By default you open (and close) the AExp on-screen menu with the
<kbd>Help</kbd> key, exactly like every other MEGA65 core. That is the friendly,
familiar choice and it stays the default.

But on the Amiga, <kbd>Help</kbd> is a *real* key that Amiga software uses. If
you would rather send <kbd>Help</kbd> to the Amiga and open the menu another way,
AExp lets you choose. In the on-screen menu, under **Keyboard**, open the
**`OSM:`** submenu ("key to open the menu") and pick one of:

| Menu opens with          | Notes                                                         |
|--------------------------|--------------------------------------------------------------|
| <kbd>Help</kbd> (default)| The classic MEGA65 choice; <kbd>Help</kbd> also reaches the Amiga. |
| <kbd>F11</kbd>           | Clean: <kbd>F11</kbd> is not an Amiga key, so nothing leaks to the Amiga. |
| <kbd>F13</kbd>           | Clean, same as <kbd>F11</kbd>.                               |
| <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> | A two-key combo; see the caution below.          |

When you pick an alternative, **the <kbd>Help</kbd> key is freed** and goes
straight to the Amiga — which is the whole point. Your choice is saved with your
other settings, so it survives a restart.

<kbd>F11</kbd> and <kbd>F13</kbd> are the recommended alternatives: because they
have no meaning on the Amiga, using them to open the menu never disturbs the
running software. The <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> combo works too, but
both of those keys *are* live Amiga inputs (Left Amiga and the right mouse
button), so the Amiga briefly sees them as you reach for the menu, and the combo
can clash with genuine Amiga use. Prefer a function key unless you have a reason
not to.

However you open the menu, you can always **close** it with the same key — the
<kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> combo included — and <kbd>Run/Stop</kbd> also
steps back out of the menu on its own, so you can never lock yourself out.

---

## No mouse? Steer the pointer from the keyboard

Even without an Amiga mouse you can operate Workbench, because the Amiga's own
operating system can move the pointer from the keyboard. It works in Workbench
and other system-friendly programs (but not in games or demos that take over the
machine).

| Action                      | Keys                                                                   |
|-----------------------------|------------------------------------------------------------------------|
| Move the pointer            | <kbd>MEGA</kbd> + <kbd>&uarr;</kbd> <kbd>&darr;</kbd> <kbd>&larr;</kbd> <kbd>&rarr;</kbd> |
| Move the pointer **faster** | <kbd>MEGA</kbd> + <kbd>Shift</kbd> + arrows                             |
| **Left** mouse button       | <kbd>MEGA</kbd> + <kbd>Alt</kbd> — *Amiga mode:* <kbd>MEGA</kbd> + <kbd>F13</kbd> |
| **Right** mouse button      | <kbd>Run/Stop</kbd> — *Amiga mode:* <kbd>&uarr;</kbd> (the up-arrow symbol key) |

<kbd>MEGA</kbd> is the Amiga's Left Amiga key and <kbd>Alt</kbd> is its Left Alt,
so <kbd>MEGA</kbd>+<kbd>Alt</kbd> is exactly the Amiga's built-in "left click".
In **Amiga mode** the Left Alt key moves to <kbd>F13</kbd>, so the built-in left
click is <kbd>MEGA</kbd>+<kbd>F13</kbd> there, and the right button is the
<kbd>&uarr;</kbd> key (see *Amiga mode in detail*). The pointer keeps accelerating
the longer you hold an arrow, so tap for fine positioning and hold to cross the
screen. There is more about the mouse — and a simple DIY adapter for a real right
mouse button — in [mouse.md](mouse.md).

---

## Frequently asked

**Which mode should I use?** Leave it on **MEGA65 mode** unless you specifically
want the Amiga's own key positions. MEGA65 mode means you never have to think:
type what the cap shows.

**I switched modes and a key changed.** That is expected on the shifted number
row and the `: ; @` cluster — those are the keys where the MEGA65 and the Amiga
disagree, and the mode chooses whose labelling wins. Everything else is
identical in both modes.

**Can I change the mode while a program is running?** Yes. The change takes
effect for the next key you press; keys you are already holding are unaffected.

**A shifted symbol didn't come out right in an old diagnostic tool.** A tiny
number of characters are produced by having AExp briefly press
<kbd>Shift</kbd> for you. Normal Amiga software (anything that uses the Amiga's
`keyboard.device`, which is essentially everything) handles this perfectly.
Only a raw, low-level keyboard diagnostic that bypasses the operating system may
notice — and those tools are not what you type documents in.

---

*Under the hood: AExp turns MEGA65 key presses into the Amiga's raw key codes
in* `CORE/vhdl/keyboard.vhd`*, and the Amiga's Kickstart resolves those codes to
characters with its US keymap — exactly the path a real Amiga and every
PS/2-to-Amiga adapter use. The engineering details live in the project's design
notes.*
