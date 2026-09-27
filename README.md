# Orion Drift Spectator — Replay Cam

A free-fly spectator camera for the **Orion Drift Spectator** client that records
replays, and — the part the built-in cameras do not do — plays **several replays at
the same time in one world**, as ordinary characters, all locked to a single clock.

Load three replays of the same match, press play, and all three players are in the
frame at once, still in step when you scrub, still in step when you jump back to the
start. Then fly around them, record the flight, and save the whole setup as a shot
you can reload next week.

```
Behaviors/you.replaycam/
├── package.json          the manifest the client loads
├── main.luau             the only file that touches the client API
├── ui.luau               the panel: menu bar and eight pages
├── types.luau            shared shapes, no logic
├── util.luau             coercion, time formatting, path and error helpers
├── vecmath.luau          basis maths, quaternion slerp, keyframe bracketing
├── replaylayers.luau     the master clock and the multi-replay sync
├── flycamera.luau        the free-fly integrator
├── camerapath.luau       keyframe capture and playback
├── shotfile.luau         shot save/load, validated and repaired on read
└── replayrecorder.luau   the client's recorder, including the auto-stop
```

Everything with arithmetic in it is a pure function in one of the modules, and the
client objects are handed to them as plain tables. That is what makes the whole thing
testable without the game running: `dev/run_checks.sh` runs 512 assertions against
this exact code, then strict-type-checks it.

---

## Install

1. Copy the `you.replaycam` folder into:

   ```
   C:\Users\<you>\Documents\Another-Axiom\A2\Cameras\Behaviors\
   ```

2. Start the Spectator app (**Start in Desktop Mode** from the Meta Horizon app on
   PC), open a match.

3. `F2` opens the Cameras panel — pick **Replay Cam**. `F3` opens the panel for the
   current camera, which is where this camera's UI draws.

Any folder in `Behaviors` that contains a `package.json` counts as one camera, so the
folder name is yours; it is the `name` inside `package.json` that identifies it. If
the app does not list the camera at all, rename the folder to `you.replaycam.luau` —
the official examples carry that suffix, and the docs accept both.

Saving a file hot-reloads the camera; there is no build step and no restart. If a
script error appears, `F4` shows the Camera Logs.

The app's own keys are `F1` (GUI), `F2` (Cameras), `F3` (this camera's panel) and
`F4` (logs). Everything below belongs to Replay Cam, and only fires while Replay Cam
is the active camera — so it cannot fight with another camera's keys.

### One thing to check first

The whole point of the overlay is that loaded replays show up as **people**, not
ghosts or trails. That behaviour is not documented anywhere in the official docs, so
it is the one assumption in this package that is not proven by reading. There is a
probe for exactly that question, and it takes ninety seconds:

1. Copy `probe/Behaviors/you.preprobe` into `Behaviors` as well.
2. Select it, press `1` to load three replays, `2` to align them, `4` to report.
3. You should see three characters in the world moving together.

If they are there, Replay Cam's design is exactly right and you can skip the probe.
If they are invisible, or render as something other than a body, stop and say so —
the fallback is to draw the rig from `getAllGameData()` with `WorldDraw`, which is a
different implementation and I would build it that way instead.

---

## The menu

One row of tabs along the top, each with a count badge where it matters. Every page
ends with a **Next** line saying what the usual next action is, so the panel reads as
a workflow rather than a wall of widgets.

| Page | What it is for |
| --- | --- |
| **Overview** | Transport: play, pause, step, scrub, speed. A table of every layer with its length, offset and how far through it is. The clock you are dragging is the master clock — one handle for the whole stack. |
| **Replays** | The overlay itself. Stack and remove layers, choose how they line up (relative offsets, or real wall-clock timestamps), and pick what a layer does when it finishes: hold on its last frame, or loop. There is also a browser of every replay file the client can see, with a filter box. |
| **Record** | The client's recorder. Start a recording, and it stops by itself at the configured length (one minute by default) so you never capture a gigabyte by forgetting about it. Below that, clip a range out of an existing replay into its own file. |
| **Camera** | Where the camera comes from: your hands, a captured path, or a blend of both. Movement feel lives here too — speed, smoothing, look sensitivity, field of view. |
| **Motion** | The captured camera path: keyframe count, span, a sparkline of how the keys are spread over time, and the offset for lining the move up against the replays. |
| **Shot** | Save the entire setup — layers, offsets, timing modes, range and camera path — to one file, and load it back later. |
| **Keys** | Every key binding, in one place, so you never have to remember which of them you are one keystroke away from. |
| **Debug** | What the client actually gave this camera: whether replay control is allowed, whether package files work, whether screenshots work, frames per second, current fly speed, and any error the camera has swallowed. Read this first if something is off. |

---

## Keys

**Flying**

| | |
| --- | --- |
| Move | `W` `A` `S` `D` |
| Up / down | `E` / `Q` |
| Boost / fine | `Left Shift` / `Left Control` |
| Look | hold `Right mouse` and move |
| Freeze in place | `Backspace` |

Look is held-to-the-right-mouse by design: the app has no way for a camera to ask
for the mouse, so an always-on look would spin the camera every time you dragged a
slider. `freeLook` in the config switches to always-on if you would rather have it.

**Timeline and recording**

| | |
| --- | --- |
| Play / pause | `Space` |
| Step one frame | `,` / `.` |
| Jump to the start | `Home` |
| Start / stop recording | `R` |
| Export the clip | `C` |
| Capture camera keys | `P` |
| Cycle camera source | `K` |
| Ride the built-in Free Cam | `F` |
| Screenshot | `V` |

`F` is the escape hatch: it makes this camera follow the client's own Free Cam, so
you can use the tool you already know, then press `F` again to come back.

---

## Config

`Documents\Another-Axiom\A2\Cameras\Configs\you.replaycam.json`, under its
`customData` block — that block is exactly what the script's `config` global holds:

```json
{
	"keybind": "",
	"script": "you.replaycam",
	"customData": { "moveSpeed": 1400, "recordTargetSeconds": 120 }
}
```

The keys are flat, so hand-editing works, and every value is clamped on the way in —
a typo makes the camera use a sane number instead of breaking. They are all editable
from the panel too, which writes them back with `saveConfig()`. A config file with no
`customData` block is survivable: the camera logs that once and runs on the defaults
below. Copying the config file gives you a second instance of the same camera with
different settings.

| Key | Default | Meaning |
| --- | --- | --- |
| `moveSpeed` | `900` | Fly speed in cm/s (Unreal units). |
| `boostMultiplier` | `4` | Multiplier while `Left Shift` is held. |
| `fineMultiplier` | `0.15` | Multiplier while `Left Control` is held. |
| `inertia` | `true` | Coast to a stop, or stop dead. |
| `dampingTime` | `0.35` | Seconds to close most of the gap, matching the client's own smoothing vocabulary. |
| `lookSensitivity` | `0.12` | Degrees per mouse pixel. |
| `freeLook` | `false` | Look without holding the right mouse button. |
| `alignRoll` | `true` | Use the world's gravity for the up vector; falls back to world +Z where gravity is zero. |
| `positionSmoothing` | `0.12` | Camera position smoothing, passed to the client. |
| `rotationSmoothing` | `0.12` | Camera rotation smoothing. |
| `fov` | `90` | Field of view in degrees. |
| `followBuiltInFreecam` | `false` | Start out riding the built-in Free Cam. |
| `recordTargetSeconds` | `60` | Auto-stop for a new recording. `0` never stops. |
| `pathSampleHz` | `30` | Keyframe capture rate. |
| `pathMaxKeys` | `20000` | Keyframe budget; past it the path is marked truncated instead of growing forever. |
| `pathBlend` | `0.5` | In blend mode, how much the captured path wins against your hands. |
| `layerCap` | `8` | How many replays may be stacked at once. |

---

## How the overlay stays in step

Each layer gets a time offset, and the frame's single source of truth is
`comp.masterT`:

```
layer i time = masterT + offset i
```

Every frame, each loaded replay is *forced* to that time: `isPlaying` is set false
and the time is written by hand. That is deliberate. If the replays were left to play
themselves, each would drift on its own clock and the three characters would slowly
slide apart — the exact thing this tool exists to prevent. It also means scrubbing is
free: the stack is a function of one number, so dragging the handle moves all of them
together.

Two ways to line layers up, on the Replays page:

- **relative** — you set the offsets, or start from zero and nudge. Good when you know
  the match started together.
- **wallclock** — reads each replay's own start timestamp and aligns to the *earliest*
  of them, so all offsets are ≤ 0 and the window begins at zero.

A layer whose file is missing, or whose handle has gone stale, is marked and skipped
rather than dragging the rest down; handles are re-resolved every couple of seconds,
so a replay loaded from the client's own UI turns up without a manual refresh.

---

## Shots

A shot is one JSON file holding the layers, their labels and offsets, the timing
modes, the range, and the captured camera path. Save from the Shot page; the file
lands in this camera's own folder:

```
Documents\Another-Axiom\A2\Cameras\Behaviors\you.replaycam\shots\<name>.json
```

Names are reduced to something safe before they touch a path: no separators, no
leading dot, capped length — so a name typed into a text box cannot write outside the
folder. Reading is the same idea in the other direction: an unknown mode falls back to
a known one, an out-of-range speed is clamped, a keyframe with a missing number is
dropped and the rest survive, and the keys are re-sorted by time because playback
binary-searches on it. A file written by a *newer* version is refused with a clear
message rather than half-read.

There is no delete API in the client, so removing a shot means deleting the file from
that folder — the Shot page says so rather than leaving you hunting.

Recordings themselves are the client's business: they land in
`Documents\Another-Axiom\A2\Replays\`.

---

## Trying it out

Take these in order. Each one is a few minutes, and each isolates a different layer
of the design.

1. **Probe.** Three replays visible as characters, moving together. (Above.)
2. **Fly only.** Select Replay Cam, `WASD` around, hold right mouse to look. Nothing
   else has to work for this to be worth checking.
3. **Record one.** Press `R`, watch the timer, and confirm it stops on its own at one
   minute and that the file appears in `Replays`.
4. **Lockstep — the acceptance test.** Stack three replays from the same match, press
   `Space`, and watch for ten seconds. Then drag the scrubber to the middle, then
   `Home`, then play again. If the three characters stay in contact through all of
   that, the core claim holds. If any one of them slides out of step, that is a bug
   worth reporting.
5. **Reload a shot.** Save, restart the app, load the shot. The layers come back with
   their offsets, and any replay file that has gone missing is reported rather than
   silently dropped.
6. **Path playback.** `P` to capture a move, `K` to follow it, and check the move
   lands where you flew it, still in sync with the replays.
7. **Clip export.** Give a range, press `C`, and confirm the clip shows up as a new
   replay file.

---

## Developing against it

```
dev/setup_tools.sh      # fetches the luau CLI and luau-lsp into .tools
dev/run_checks.sh       # unit tests, then strict type checks
```

`run_checks.sh` stages the package into `.stage` (rewriting the bare
`require("util")` imports the client wants into the `./util` form the CLI wants), runs
each `dev/tests/test_*.luau` as the main script, and then strict-type-checks the
package, the tests and the probe against `dev/defs/spectator.d.lua`.

Each test file runs as the *main* script rather than being required by a runner. That
is not a stylistic choice: the reference CLI silently skips a required module that
fails to parse, and a require-driven suite once reported "all green" while executing
nothing at all.

Two conventions the layout depends on:

- **`main.luau` is the only writer to `camera`.** Modules never touch the engine
  globals; they take numbers and plain tables and return numbers and plain tables.
  That is what makes them testable and what stops two modules fighting over the
  transform.
- **Modules hold no state.** The client's `require` behaves like a copy per requiring
  file, so a module-level table is not shared between two files that require it. All
  session state lives in `main.luau` and is passed in as arguments.

`dev/defs/spectator.d.lua` is my hand-written model of the API, built from the
official docs. The client ships its own `*.d.lua` files and `types/*.json` next to the
built-in cameras, and those are authoritative — if they disagree with mine, they are
right and mine should be corrected.

---

## Known limits

- The panel can only draw what the client's `Gui` API offers, which is Dear ImGui's
  smaller subset: no colours, no fonts, no images, no tab or menu widgets. The menu is
  built from `selectable` buttons in a horizontal row, and the icons are the client's
  own FontAwesome glyph names, looked up defensively so a missing glyph degrades to
  text instead of erroring. The timeline scrubber and range slider are also probed
  rather than assumed, with plain widgets behind them.
- A replay can be stacked or unstacked, but this camera never unloads one — the
  client keeps files loaded, and unloading by index while other layers still point at
  the same file is how handles get mis-attributed.
- Frame stepping assumes 1/60 s. There is no accessor for the replay's tick rate, so
  `,` and `.` move by one frame at that rate; fine scrubbing is what the slider is for.
- If something inside the frame loop starts throwing, the camera says so once, counts
  the repeats, and stops updating after a couple of hundred consecutive failures
  rather than flooding the log for the rest of the session. The Debug page shows the
  last error and reload is the recovery.

## Provenance

Written against the official Spectator documentation. No code or assets were taken
from the game install, and no networking API is used — files stay inside this
camera's own folder. Where the official documentation is silent about a widget or a signature, the
shape recorded in `dev/defs/spectator.d.lua` came from community notes and was then
checked against what the client actually accepts; where the two disagreed, the
client won and the definition was corrected. That file is the summary of those
findings, and the traps are called out in comments next to the entries they affect.
