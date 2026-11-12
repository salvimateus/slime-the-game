# Slime Prototype

> A 2D platformer prototype made with Godot 4.7, where the mass of the slime is its life.

## The game

- You are a green slime. Damage and high falls splash goo off your body, and the slime gets smaller. Below a minimum size, the slime dies.
- Move over the lost goo to pull it back and grow again.
- A smaller slime is more agile. A larger slime carries more objects.
- Absorb rocks and crystals, then spit them as shots that ricochet. Traps break a thrown object into smaller pieces.
- The hot zone melts the slime, and it flows through pipes. The fire zone burns its goo and makes ember shots. The cold zone turns it into an ice cube.
- Coloured monsters drop goo of their colour, which mixes with the green.
- There is one level, with no life bar: the size of the slime is the life.

## Controls

| Action | Keyboard and mouse | Xbox or PlayStation pad | Touch |
|---|---|---|---|
| Move | A / D or arrows | Left stick or D-pad | Floating stick |
| Jump and double jump | Space, W, Up or Z | A / Cross | Green button |
| Quick shot | J or X | X / Square | Rock button |
| Aim (hold) | Right mouse button | LT / L2, direction on the right stick | Hold and drag the blue button |
| Fire | Left click | RT / R2 | Release the drag |
| Run | Shift | RB / R1 | Push the stick to its limit |
| Dodge and roll | K or C | B / Circle | Pink button |
| Crouch | S or Down | Stick or D-pad down | Stick down |
| Restart | R | Back / Share | Corner button |
| Performance panel | F3 (F5 quality, F6 render scale) | | Small corner button |
| Fullscreen and quit | F11 and Esc | | Android back |

## Run the project

- Open `project.godot` with Godot 4.7.2.
- The renderer is Compatibility (OpenGL) on desktop and on mobile.
- Ready builds for Windows and Android are in the Releases page.

## Export

- The export presets are `Android` (arm64, debug keystore of the editor) and `Windows Desktop` (x86_64, embedded PCK).
- The `Windows Desktop` preset points to a custom release template on the machine of the author. Clear that field to use the official template.

## Test harness

- The `Harness` autoload reads arguments after `--` for scripted runs: `--spawn=`, `--input-inline=`, `--log=stdout`, `--quit-at-tick=`, `--shot=`, `--perf`.
- `PRIMITIVES.md` is the inventory of the shared contracts of the code.
