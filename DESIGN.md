---
name: Dragonex
description: Mesa de D&D 5e con DM por IA, vestida de mazmorra de 16 bits a la luz de las antorchas.
colors:
  abyss: "#110c1a"
  stone: "#251d38"
  stone-2: "#2f2645"
  stone-3: "#4a3f68"
  stone-4: "#6b5d92"
  edge: "#07050b"
  well: "#120d1b"
  pit: "#0d0914"
  torch: "#ff8a1f"
  torch-hi: "#ffb35c"
  ember: "#c2410c"
  torch-ink: "#2a1004"
  gold: "#ffd23f"
  gold-dim: "#a8801f"
  gold-ink: "#2b1f00"
  blood: "#e03a3a"
  blood-dim: "#7c1a22"
  arcane: "#46e0c8"
  arcane-dim: "#1d6f6c"
  moss: "#7bd389"
  moss-dim: "#265c3b"
  parch: "#ead2a0"
  parch-rim: "#c79f5f"
  parch-edge: "#3b2412"
  ink: "#2a1a10"
  ink-soft: "#6a4c33"
  rubric: "#a3201c"
  roll-paper: "#f3e6c8"
  felt: "#3a1712"
  bone: "#efe2c4"
  text: "#f1e8d8"
  text-dim: "#b9adcb"
  text-mute: "#8577a0"
typography:
  display:
    fontFamily: "Jacquarda Bastarda 9, Alegreya, Georgia, serif"
    fontSize: "clamp(40px, 5vw, 60px)"
    fontWeight: 400
    lineHeight: 0.95
  title:
    fontFamily: "Alegreya, Georgia, Times New Roman, serif"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.15
  body:
    fontFamily: "Alegreya, Georgia, Times New Roman, serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.5
  chronicle:
    fontFamily: "Alegreya, Georgia, Times New Roman, serif"
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.6
  ui:
    fontFamily: "Departure Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.1
  label:
    fontFamily: "Departure Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "13px"
    fontWeight: 400
    letterSpacing: "0.1em"
  numeral:
    fontFamily: "Departure Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "30px"
    fontWeight: 400
    lineHeight: 1
rounded:
  none: "0px"
spacing:
  pixel: "3px"
  touch: "44px"
components:
  button-default:
    backgroundColor: "{colors.stone-3}"
    textColor: "{colors.text}"
    typography: "{typography.ui}"
    rounded: "{rounded.none}"
    padding: "0.5rem 1rem 0.6rem"
  button-primary:
    backgroundColor: "{colors.torch}"
    textColor: "{colors.torch-ink}"
    typography: "{typography.ui}"
    rounded: "{rounded.none}"
    padding: "0.5rem 1rem 0.6rem"
  button-primary-hover:
    backgroundColor: "{colors.torch-hi}"
    textColor: "{colors.torch-ink}"
  button-ghost:
    backgroundColor: "{colors.stone}"
    textColor: "{colors.text-dim}"
  button-danger:
    backgroundColor: "{colors.blood-dim}"
    textColor: "#ffd9d2"
  input:
    backgroundColor: "{colors.pit}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.none}"
    padding: "0.6rem 0.75rem"
  chip:
    backgroundColor: "{colors.well}"
    textColor: "{colors.text-dim}"
    typography: "{typography.ui}"
    padding: "0.3rem 0.65rem 0.36rem"
  chip-selected:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.gold-ink}"
  window:
    backgroundColor: "{colors.stone-2}"
    textColor: "{colors.text}"
    rounded: "{rounded.none}"
  chronicle:
    backgroundColor: "{colors.parch}"
    textColor: "{colors.ink}"
    typography: "{typography.chronicle}"
  roll-line:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.roll-paper}"
    typography: "{typography.ui}"
    padding: "0.32rem 0.75rem 0.38rem 2.1rem"
---

# Design System: Dragonex

## Overview

**Creative North Star: "La crónica de mazmorra en 16 bits"**

Dragonex is a dungeon at torchlight. Every screen sits on a pixel-brick wall (96×48 tile) lit by two warm torch pools at the top corners and a faint violet halo below, all flickering in four stepped frames. On that wall float classic-RPG windows: square, with a coloured rim, a dark one-pixel ring whose corners are clipped, and a hard drop beneath. The game itself is written on parchment: brown ink, rubric red for actors and capitals, and the engine's dice results as dark ink stubs in a pixel mono. The UI is dark (`color-scheme: dark`), dense, and Spanish throughout.

The home follows the same world and proves the product by showing it: a real chronicle replaying turn by turn between two animated torches, a dice tray where bone dice land on oxblood felt (dic_ex 2D engine), a roll readout, and a declare bar whose only action is «Crear cuenta». The brand mark is the SVG pixel wordmark, not type. The user rejected the earlier pixelated-blackletter wordmark (Jacquarda Bastarda 9) and the pixel dragon sprite on the home. Assets are plain CSS and SVG in `priv/static/assets`. There is no JS build pipeline; sprites come from `scripts/gen_pixel_sprites.py` and the wordmark from `scripts/gen_wordmark.py`.

**Key Characteristics:**
- Square corners everywhere; depth is built from hard pixel rings and offset drops, not blur.
- Three type voices: blackletter for titles, Alegreya for prose, Departure Mono for UI and numbers.
- Two surfaces: dark stone windows for the interface, parchment for the narrative.
- Motion snaps in `steps()` like a 16-bit menu; it never glides, with one exception (ink settling on the home).
- Pixel sprites (`image-rendering: pixelated`) scale by whole-pixel multipliers.

## Colors

A cold dungeon violet stone carries the interface. Torch orange and gold light it, and warm parchment holds the story.

### Primary
- **Torch Orange** (torch): the one call to action per view (primary button, active tab, active initiative entry, selected settings option), the input focus ring, text selection, checkbox accent. Hover lifts to **Torch Glow** (torch-hi), and **Ember** is the 3px under-bevel on active torch elements.
- **Dragon Gold** (gold): titles, character names, the "your turn" state, the selected chip, round badge, level-up callout, the copy toast and the global focus outline. **Tarnished Gold** (gold-dim) is its bevel and rim.

### Secondary
- **Rubric Red** (rubric): parchment-only accent. Actor names in turn headers, the "combate" phase tag, speaker labels, drop capitals, the left rule on player lines, and text selection on parchment.
- **Arcane Teal** (arcane): links, spell-group and list subheads, the "tú" tag. **Deep Arcane** (arcane-dim) is the rim for your own sheet and the random button.

### Tertiary (signal colours)
- **Moss** / **Deep Moss** (moss, moss-dim): healthy HP, running badge, hits and successes, ready seats.
- **Blood** / **Old Blood** (blood, blood-dim): low HP, misses, errors, enemy rims, the danger button. Old Blood is also the 3px text-shadow under every gold title.

### Neutral
- **Abyss** (abyss): page ground under the brick tile. **Well** (well) is the recessed panel used for stat boxes, chips, options and combatants. **Pit** (pit) is the input field. **Edge** (edge) is the near-black outer ring of every frame.
- **Stone** ramp (stone → stone-2 → stone-3 → stone-4): window gradient (stone-2 to stone), default rim and inset borders (stone-3), hover rim (stone-4).
- **Bone Text** (text) / **Lavender Dim** (text-dim) / **Lavender Mute** (text-mute): primary, secondary and tertiary text on stone.
- **Parchment** (parch), **Parchment Rim** (parch-rim) and **Parchment Edge** (parch-edge): the chronicle sheet, its 3px border and its outer ring. **Ink** / **Faded Ink** (ink, ink-soft) are the text on it. **Roll Paper** (roll-paper) is the text on dark roll stubs.
- **Oxblood Felt** (felt) and **Bone** (bone): the home dice tray. Dice are bone with rubric pips (`#8a1c16`) and a `#c9b48a` pip shadow, and the felt colour also fills the dic_ex grid and fog so the grid disappears.

### Named Rules
**The Two Surfaces Rule.** Stone is for interface and parchment is for narrative. Rubric red lives only on parchment, and arcane links live only on stone.

**The Dark-Ink-on-Light Rule.** Text on gold or torch backgrounds is always the dark ink of its family (gold-ink, torch-ink), never white.

## Typography

**Display Font:** Jacquarda Bastarda 9 (with Alegreya, Georgia)
**Body Font:** Alegreya 400–800, roman and italic (with Georgia, Times New Roman)
**Label/Mono Font:** Departure Mono (with ui-monospace, Menlo)

**Character:** A pixel blackletter for ceremony, a warm humanist serif for the story, and a pixel mono for anything mechanical (numbers, dice, controls). All fonts are self-hosted OFL, Latin subset, and `font-synthesis: none` stops faux bold on the single-weight pixel faces.

### Hierarchy
- **Display** (400, clamp(40px, 5vw, 60px), 0.95): page titles, waiting-room and wizard titles (up to 68–72px), the hero-sheet name (up to 88px), modal titles (40–44px), hero portrait initial. Always gold with a 3px Old Blood offset shadow, plus a second 6px black one at page scale. In game, it is also the rubric drop cap (3.2em) that opens each DM turn.
- **Title** (Alegreya 700, 20–23px, 1.15): card, quest, hero and item names, usually gold.
- **Body** (Alegreya 400, 17px, 1.5): interface prose. Italic is used for subtitles, hints, placeholders and whose-turn.
- **Chronicle** (Alegreya 400, 18px, 1.6–1.62): narration on parchment. Player lines are italic, and the home stays at 16.5px on mobile.
- **UI** (Departure Mono, 15px; 13px small): buttons, nav, badges, turn bar, roll stubs (14.5px).
- **Label** (Departure Mono, 13px, 0.1–0.14em, uppercase): field labels, panel heads in torch-hi, turn-header lines in ink-soft.
- **Numeral** (Departure Mono, 30px; readout 40px, die value 24px): ability scores, roll totals.

### Named Rules
**The Wordmark Is Not Type Rule.** The brand appears only as `wordmark.svg`: 26px tall in the topbar after an animated torch, and min(560px, 84vw) on the home with a torch-glow drop shadow. Never set "Dragonex" in Jacquarda Bastarda as a logo.

**The Home Capital Rule.** The home's drop cap is Alegreya 800 at 2.9em in rubric with no shadow. The in-game chronicle keeps the blackletter capital.

## Layout

The viewport is a fixed-height column (`100dvh`, `overflow: hidden`): topbar, then a LiveView main area where only one region scrolls (the game log at the table). Content pages center at min(1120px, 100% − 3rem), with narrow pages at 820px and the waiting room at 1080px. Vertical padding is clamp(1.25rem, 3vw, 2.5rem).

The game table is a three-column grid (250px rails, 210px below 1100px) around the chronicle. Below 1023px it collapses to one column: chronicle first, then a sheet-drawer toggle and the sheets, while the turn bar becomes two horizontally scrolling rows. In short landscape (721–1023px wide, ≤600px tall) the sheet moves to a side column. The home table is `torch | chronicle | torch` at max 1040px, and inside the chronicle a dice tray of clamp(240px, 29%, 320px) sits right. At ≤720px the torches hide and the tray becomes a 148px row under the log. The hero sheet becomes one column at 900px.

Spacing is rem-based without a formal scale. Window gaps are 0.8–1.6rem, and window padding is about 0.75–1.2rem. The structural unit is the frame pixel `--p` (3px): borders, rings, bevels and focus outlines are multiples of it. Touch targets are 44px minimum on coarse pointers and in the wizards.

## Elevation & Depth

Depth is pixel-built: stacked hard box-shadows with zero blur. A window is a 3px rim, a 3px edge ring drawn as four 1px-offset shadows (which clips the corners into steps), a 9px black drop at 45%, and a 3px white top highlight at 6%. Recessed elements (wells, inputs, chips) use inset 2–3px rings instead. Light comes from the scene, not from surfaces: radial torch gradients on the body and around the home table, plus a vignette.

### Shadow Vocabulary
- **Window frame** (`0 -3px 0 0 edge, 0 3px 0 0 edge, -3px 0 0 0 edge, 3px 0 0 0 edge, 0 9px 0 0 rgba(0,0,0,.45), inset 0 3px 0 0 rgba(255,255,255,.06)`): every panel, card, modal and turn bar.
- **Button bevel** (the same ring plus `inset 0 -3px 0 0 rgba(0,0,0,.32), inset 0 3px 0 0 rgba(255,255,255,.16)`): all buttons.
- **Well inset** (`inset 0 0 0 2px stone-3`): chips, stat boxes, options, badges.
- **Roll stub** (`inset 4px 0 0 0 <outcome>, 3px 3px 0 0 rgba(59,36,18,.3)`): a left bar coloured by outcome.
- **Title drop** (`text-shadow: 3px 3px 0 blood-dim[, 6px 6px 0 rgba(0,0,0,.45)]`): gold display type.

### Named Rules
**The No-Blur Frame Rule.** Frames and controls take zero-blur shadows only. Soft blur is reserved for light: torch glow, the vignette, and the home chronicle's lift (`0 14px 32px` plus a torch halo).

## Shapes

Every corner is square (`border-radius: 0`). The only "rounding" is the pixel step that the four-way ring cuts out of each frame corner. Dividers are dashed (2px dashed stone-3 at 35–45%, or a repeating 6px/6px stone-3 dash), and turn headers on parchment use a 3px/4px ink dash. Empty states get an inner dashed outline at −8 to −9px. HP bars are segmented every 12px. Sprites stay crisp at multiples of `--s` (1.5–4px per art pixel).

## Components

### Buttons
- **Shape:** square, beveled, with the edge ring (0px radius).
- **Primary:** torch with torch-ink text, Departure Mono 15px. Only one per view: «Crear cuenta», «Empezar» (start-btn, 19px).
- **Hover / Focus / Active:** `brightness(1.18)` on hover (primary swaps to torch-hi), a 2px press-down on active, the global 3px gold focus outline at 4px offset, and 0.45 opacity when disabled.
- **Variants:** default stone-3, ghost/back stone with text-dim, danger blood-dim, random arcane-dim, small 13px. Turn-bar controls are ghost-like, min 36px tall (44px on touch).

### Chips, Tabs, Steps
- **Style:** well background, 2px stone-3 inset, mono 14px, text-dim.
- **State:** selected chips are gold with a light-gold inset and a gold-dim under-bevel. Active tabs, steps and initiative entries use the torch fill with an ember under-bevel. Completed steps are moss.

### Cards / Containers
- **Corner Style:** square, window frame.
- **Background:** vertical gradient stone-2 → stone.
- **Border:** the 3px `--rim` changes meaning: stone-3 default, stone-4 on hover, arcane-dim for yours, blood-dim for enemies, gold for "your turn" (pulsing in two steps), moss-dim for ready or open.
- **Internal Padding:** 0.75–1.2rem. Windows unfold with `scaleY(.2)→1` in 4 steps over 0.24s.

### Inputs / Fields
- **Style:** pit background, a 3px stone-3 inset plus a 6px dark top inset, Alegreya 17px, italic text-mute placeholder.
- **Focus:** the inset ring turns torch. `select` uses mono 15px.
- **Error:** a blood-dim wash with a 2px blood inset, text `#ffd9d2`.

### Navigation
- **Topbar:** dark violet gradient, a stacked hard underline (edge, stone-3, black drop), the wordmark at left, mono 15px links in text-dim. On hover a link turns gold and a pixel ▶ arrow sprite slides in from the left in 2 steps. At ≤720px the links shrink to 13px, the arrow and user tag hide, and guests see only Entrar/Registro.

### Access (Entrar / Crear cuenta)
The wordmark at min(400px, 78vw) with the home's torch-glow shadow, above a 420px stone window flanked by two 3px torches whose glow lights the wall (torches hide at ≤620px). The window opens with two mono tabs on a pit strip (the current one torch, like `.tab.active`), an italic text-dim line, «Continuar con Google» as a stone button whose colour «G» sits on a white square (Google's brand rule), a dashed «o con tu correo» divider, then the form. A field error turns its inset ring blood and adds a 15px `#ff9d94` line under it.

### Chronicle (signature)
A parchment sheet (48px parchment tile plus burnt-edge gradients), framed by a 3px parch-rim border and a parch-edge ring. Each turn header is a dashed ink line with the actor in rubric (green `#1c6a3c` for you, violet `#4b2d9a` for auto). DM prose opens with a drop capital, and player lines are italic with a 3px rubric left rule. Rolls are dark ink stubs with a d20 sprite and a mono line: hits and successes get a moss bar, misses a blood bar, crits a full gold stub, critical fails a full blood-dim stub. The "thinking" state is an animated quill.

### Dice Tray and Readout (home)
A square of oxblood felt with a double ring (edge, then `#8a6a3c`) and an inner shadow, in which dic_ex rolls bone dice. Below it, the readout is an ink panel showing who and what in gold 13px, the total in parch at 40px, and the outcome in uppercase. Its ring turns moss-dim or blood-dim with the result.

### Declare Bar
The input of the table restated: a pit-dark field with a quill sprite, italic «Declara tu intención…» and a blinking torch caret (1.05s, 1 step), next to the primary button. On the home it sits on a `#d4b47b → #c9a86c` parchment strip and links to registration.

## Do's and Don'ts

### Do:
- **Do** build every new panel on the window frame and change meaning only through `--rim`.
- **Do** use `steps()` timing for UI motion (frame unfold 0.24s/4, flicker 3.2s/4, sprite strips 0.54s), and respect `prefers-reduced-motion`, which stops animations globally.
- **Do** put mechanical facts (numbers, dice, labels) in Departure Mono and narrative in Alegreya.
- **Do** keep text on gold and torch fills in the dark ink of its family.
- **Do** render sprites and the wordmark pixelated at whole multiples.

### Don't:
- **Don't** set the brand name in Jacquarda Bastarda 9 or bring back the pixel dragon on the home; both were rejected by the user.
- **Don't** round corners or use blurred drop shadows on frames and controls.
- **Don't** use rubric red on stone, or arcane teal on parchment.
- **Don't** add a JS build step or a CDN font; assets are static files in `priv/static/assets`.
- **Don't** show more than one torch-primary button in a view.
