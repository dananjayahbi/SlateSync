#version 330 core

// Round-9 procedural backgrounds: BLANK / RULED / SQUARE_GRID.
// World coordinates are recovered via the inverse template §3 transform:
//   screen = (world - camera_center) * scale + viewport/2
//   world  = (screen - viewport/2) / scale + camera_center
//
// The pattern is PARAMETERISED by u_spacing so the user can choose the gap
// between rules (RULED) or the side of one cell (SQUARE_GRID). DOT_GRID and
// ISO_GRID were removed in round 9; legacy documents are normalised to BLANK
// on load, so they never reach this shader.
uniform vec3 u_camera;   // (scale, tx, ty) - live camera frame f1/f2/f3
uniform vec2 u_viewport; // framebuffer size in pixels
uniform int u_pattern;   // 0 BLANK, 1 RULED, 2 SQUARE_GRID
uniform float u_spacing; // world units: rule gap / square side (> 0)
uniform vec3 u_bgColor;  // artboard background_color
uniform vec3 u_lineColor; // pattern ink colour
uniform vec4 u_scissor;  // bounded artboard world rect (min_x, min_y, max_x, max_y)
uniform int u_scissorEnabled; // 1 for bounded presets (INFINITE draws the full viewport)

out vec4 fragColor;

void main() {
    // gl_FragCoord is y-up; template §3 screen space is top-left y-down.
    vec2 screen = vec2(gl_FragCoord.x, u_viewport.y - gl_FragCoord.y);
    vec2 world = (screen - u_viewport * 0.5) / u_camera.x + u_camera.yz;
    if (u_scissorEnabled == 1 &&
        (world.x < u_scissor.x || world.y < u_scissor.y ||
         world.x > u_scissor.z || world.y > u_scissor.w)) {
        discard;
    }
    float px = 1.0 / u_camera.x; // one screen pixel expressed in world units
    float spacing = max(u_spacing, 1.0);
    // One-pixel hairline: the half-width never drops below a third of a world
    // unit, so rules stay visible when zoomed far out.
    float halfw = max(0.5 * px, 0.35);
    float alpha = 0.0;
    if (u_pattern == 1) {
        // RULED - horizontal line wherever world_y is a multiple of spacing.
        float d = abs(world.y - spacing * floor(world.y / spacing + 0.5));
        float aa = fwidth(d);
        alpha = 1.0 - smoothstep(halfw - aa, halfw + aa, d);
    } else if (u_pattern == 2) {
        // SQUARE_GRID - lattice of spacing-sided cells. The nearer of the
        // horizontal and vertical families wins, so a pixel lights up on
        // either set of rules (a real grid, not just tick marks).
        float dx = abs(world.x - spacing * floor(world.x / spacing + 0.5));
        float dy = abs(world.y - spacing * floor(world.y / spacing + 0.5));
        float d = min(dx, dy);
        float aa = fwidth(d);
        alpha = 1.0 - smoothstep(halfw - aa, halfw + aa, d);
    }
    // BLANK (u_pattern == 0) keeps alpha 0 -> solid background colour only.
    vec3 color = mix(u_bgColor, u_lineColor, clamp(alpha, 0.0, 1.0));
    fragColor = vec4(color, 1.0);
}