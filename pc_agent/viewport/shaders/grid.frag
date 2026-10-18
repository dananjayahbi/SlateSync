#version 330 core

// Doc 08 procedural backgrounds (BLANK / RULED / DOT_GRID / ISO_GRID).
// World coordinates are recovered via the inverse template §3 transform:
//   screen = (world − camera_center) * scale + viewport/2
//   world  = (screen − viewport/2) / scale + camera_center
uniform vec3 u_camera;   // (scale, tx, ty) — live camera frame f1/f2/f3
uniform vec2 u_viewport; // framebuffer size in pixels
uniform int u_pattern;   // 0 BLANK, 1 RULED, 2 DOT_GRID, 3 ISO_GRID
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
    float alpha = 0.0;
    if (u_pattern == 1) {
        // RULED — horizontal line wherever world_y ≡ 0 (mod 32).
        float d = abs(world.y - 32.0 * floor(world.y / 32.0 + 0.5));
        float aa = fwidth(d);
        alpha = 1.0 - smoothstep(0.5 * px - aa, 0.5 * px + aa, d);
    } else if (u_pattern == 2) {
        // DOT_GRID — dots on the (24i, 24j) lattice, radius 0.45·24 world units.
        vec2 off = world - 24.0 * floor(world / 24.0 + 0.5);
        float d = length(off);
        float aa = fwidth(d);
        alpha = 1.0 - smoothstep(0.45 * 24.0 - aa, 0.45 * 24.0 + aa, d);
    } else if (u_pattern == 3) {
        // ISO_GRID — line families at ±60°, 24 u perpendicular spacing.
        // s = ±√3·x − y is constant along each family; mod 48 wraps to ±24,
        // halving yields the signed perpendicular distance (±12 u envelope).
        float s1 = sqrt(3.0) * world.x - world.y;
        float s2 = sqrt(3.0) * world.x + world.y;
        float d1 = (mod(s1 + 24.0, 48.0) - 24.0) * 0.5;
        float d2 = (mod(s2 + 24.0, 48.0) - 24.0) * 0.5;
        float d = min(abs(d1), abs(d2));
        float aa = fwidth(d);
        alpha = 1.0 - smoothstep(0.5 * px - aa, 0.5 * px + aa, d);
    }
    // BLANK (u_pattern == 0) keeps alpha 0 ⇒ solid background colour only.
    vec3 color = mix(u_bgColor, u_lineColor, clamp(alpha, 0.0, 1.0));
    fragColor = vec4(color, 1.0);
}
