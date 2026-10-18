#version 330 core

// Doc 08 textured quads — image attachments and glyph-atlas labels (template §3 camera).
in vec4 in_pos_uv; // (world_x, world_y, u, v)

uniform vec3 u_camera;   // (scale, tx, ty) — live camera frame f1/f2/f3
uniform vec2 u_viewport; // framebuffer size in pixels

out vec2 v_uv;

void main() {
    vec2 world = in_pos_uv.xy;
    // Template §3: screen = (world − camera_center) * scale + viewport / 2
    vec2 screen = (world - u_camera.yz) * u_camera.x + u_viewport * 0.5;
    // Template §3: NDC = screen / u_viewport * 2 − 1; screen y is top-left y-down.
    vec2 ndc = screen / u_viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    v_uv = in_pos_uv.zw;
}
