# Implementation Plan: `output <name> margin` config option

## Summary

Add an `output <name> margin <top> <right> <bottom> <left>` config option that
defines per-output safe area insets. These margins shrink the usable area for
tiling, fullscreen windows, and initial layer-shell exclusive zone calculations,
while leaving layer surfaces (like swaybar) free to occupy the full output. This
is the pragmatic solution for laptop display notches.

## Syntax

```
output eDP-1 margin <top> <right> <bottom> <left>
```

All four values required, in pixels (CSS order: top right bottom left).

## Architecture

The margin is:
- **Parsed** from config into `struct output_config`
- **Stored** on `struct sway_output` at finalization time
- **Consumed** in three places during arrangement:
  1. `arrange_layers()` — shrinks the initial `usable_area` before layer-shell
     exclusive zones are computed (but leaves `full_area` untouched so layer
     surfaces can still anchor to real output edges)
  2. `view_autoconfigure()` — fullscreen views get margin-reduced content geometry
  3. `arrange_workspace()` / transaction `arrange_output()` + `arrange_fullscreen()`
     — fullscreen containers are sized and positioned within the margin

The fullscreen background rect stays full-output-sized (black behind translucent
fullscreen surfaces, per Wayland protocol).

## Files to Change

### 1. `include/sway/config.h` — Add margin to output_config

Add fields after the `hdr` field:

```c
bool set_margin;
int margin_top, margin_right, margin_bottom, margin_left;
```

### 2. `include/sway/output.h` — Add margin to sway_output

Add fields after `bool hdr`:

```c
int margin_top, margin_right, margin_bottom, margin_left;
```

### 3. `include/sway/commands.h` — Declare handler

Add:
```c
sway_cmd output_cmd_margin;
```

### 4. `sway/commands/output/margin.c` — New file: parse margin subcommand

Parse 4 integer arguments (top right bottom left). Pattern follows `scale.c`:
- Check `config->handler_context.output_config` exists
- Check argc >= 4
- Parse 4 ints with `strtol`
- Set `oc->set_margin = true` and the 4 margin fields
- Set leftovers for remaining argv

### 5. `sway/commands/output.c` — Register handler

Add to `output_handlers[]` (alphabetically sorted):
```c
{ "margin", output_cmd_margin },
```

### 6. `sway/meson.build` — Add new source file

Add `'commands/output/margin.c'` to the sway sources list (alphabetically,
between `max_render_time.c` and `mode.c`).

### 7. `sway/config/output.c` — Init, merge, finalize, log

**`new_output_config()`**: Initialize `set_margin = false`, all margin fields = 0.

**`merge_output_config()`**: Add:
```c
if (src->set_margin) {
    dst->set_margin = true;
    dst->margin_top = src->margin_top;
    dst->margin_right = src->margin_right;
    dst->margin_bottom = src->margin_bottom;
    dst->margin_left = src->margin_left;
}
```

**`finalize_output_config()`**: Before the return, add:
```c
if (oc && oc->set_margin) {
    output->margin_top = oc->margin_top;
    output->margin_right = oc->margin_right;
    output->margin_bottom = oc->margin_bottom;
    output->margin_left = oc->margin_left;
} else {
    output->margin_top = output->margin_right = 0;
    output->margin_bottom = output->margin_left = 0;
}
```

**`store_output_config()`**: Add margin to the debug log format string.

### 8. `sway/desktop/layer_shell.c` — Apply margin to initial usable_area

In `arrange_layers()` (line ~80), after computing `full_area` and before calling
`arrange_surface`, shrink `usable_area` by the margin:

```c
struct wlr_box usable_area = { 0 };
wlr_output_effective_resolution(output->wlr_output,
        &usable_area.width, &usable_area.height);
const struct wlr_box full_area = usable_area;

// Apply output margin to usable area (but not full_area, so layer
// surfaces can still anchor to real output edges)
usable_area.x += output->margin_left;
usable_area.y += output->margin_top;
usable_area.width -= output->margin_left + output->margin_right;
usable_area.height -= output->margin_top + output->margin_bottom;
```

This means:
- Layer surfaces still get positioned relative to the full output (swaybar can
  cover the notch)
- The `usable_area` result (stored on `output->usable_area`) already includes
  the margin, so tiling automatically respects it

### 9. `sway/tree/view.c` — Fullscreen view content geometry

In `view_autoconfigure()` (~line 310), change the FULLSCREEN_WORKSPACE case:

```c
if (con->pending.fullscreen_mode == FULLSCREEN_WORKSPACE) {
    con->pending.content_x = output->lx + output->margin_left;
    con->pending.content_y = output->ly + output->margin_top;
    con->pending.content_width = output->width - output->margin_left - output->margin_right;
    con->pending.content_height = output->height - output->margin_top - output->margin_bottom;
    return;
}
```

### 10. `sway/tree/arrange.c` — Fullscreen container geometry

In `arrange_workspace()` (~line 310), change the fullscreen branch:

```c
if (workspace->fullscreen) {
    struct sway_container *fs = workspace->fullscreen;
    fs->pending.x = output->lx + output->margin_left;
    fs->pending.y = output->ly + output->margin_top;
    fs->pending.width = output->width - output->margin_left - output->margin_right;
    fs->pending.height = output->height - output->margin_top - output->margin_bottom;
    arrange_container(fs);
}
```

### 11. `sway/desktop/transaction.c` — Scene graph fullscreen positioning

**`arrange_fullscreen()`**: Add x/y offset parameters:

```c
static void arrange_fullscreen(struct wlr_scene_tree *tree,
        struct sway_container *fs, struct sway_workspace *ws,
        int x, int y, int width, int height) {
    // ... existing body ...
    wlr_scene_node_set_position(fs_node, x, y);  // was (0, 0)
}
```

**`arrange_output()` in transaction.c** (~line 594): Change the fullscreen branch:

```c
if (fs) {
    disable_workspace(child);

    // Background still covers full output
    wlr_scene_rect_set_size(output->fullscreen_background, width, height);

    arrange_workspace_floating(child);
    arrange_fullscreen(child->layers.fullscreen, fs, child,
        output->margin_left,
        output->margin_top,
        width - output->margin_left - output->margin_right,
        height - output->margin_top - output->margin_bottom);
}
```

**`arrange_root()` in transaction.c** (~line 682): Global fullscreen stays at (0,0)
with full root dimensions (no margin for global fullscreen):

```c
arrange_fullscreen(root->layers.fullscreen_global, fs, NULL,
    0, 0, root->width, root->height);
```

## What's NOT affected (by design)

- **Layer shell surfaces**: They get `full_area` for positioning, so they can
  anchor to real output edges. Swaybar covering the notch still works.
- **Global fullscreen**: Spans all outputs, no per-output margin applied.
- **The fullscreen background rect**: Stays full-output-sized so the black
  background covers the notch area too (no rendering artifacts).
