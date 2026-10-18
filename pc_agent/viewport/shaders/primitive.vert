#version 330 core

// Doc 08 lines / shapes / graph axes — camera transform frozen in _micro_doc_template.md §3.
in vec3 in_vec3; // (world_x, world_y, signed line distance: ±half-width at edge verts, 0 for fills)
in vec4 in_rgba; // vertex colour + alpha

uniform vec3 u_camera;   // (scale, tx, ty) — live camera frame f1/f2/f3
uniform vec2 u_viewport; // framebuffer size in pixels

out vec4 v_rgba;
out float v_aux; // interpolated signed line distance (centre 0, edge ±hw)
out float v_hw;  // |half width| computed per-vertex → constant across the quad
out vec2 v_world; // world position (drop-shadow feathering in the fragment stage)

void main() {
    vec2 world = in_vec3.xy;
    // Template §3: screen = (world − camera_center) * scale + viewport / 2
    vec2 screen = (world - u_camera.yz) * u_camera.x + u_viewport * 0.5;
    // Template §3: NDC = screen / u_viewport * 2 − 1; screen y is top-left y-down.
    vec2 ndc = screen / u_viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    v_rgba = in_rgba;
    v_aux = in_vec3.z;
    v_hw = abs(in_vec3.z);
    v_world = world;
}
