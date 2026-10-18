#version 330 core

// Doc 07 stroke vertex stage — camera transform frozen in _micro_doc_template.md §3.
// in_vec3 = (world_x, world_y, signed_half_width); edge strip vertices carry ±hw so
// the fragment stage gets an analytic signed distance to the centerline.
in vec3 in_vec3;

uniform vec3 u_camera;   // (scale, tx, ty) — live camera frame f1/f2/f3
uniform vec2 u_viewport; // (w, h) framebuffer size in pixels

out float v_dist; // signed distance to the centerline (±half width at edge verts)
out float v_half; // |signed half width| — the analytic edge for the AA smoothstep

void main() {
    vec2 world = in_vec3.xy;
    // Template §3: screen = (world − camera_center) * scale + viewport / 2
    vec2 screen = (world - u_camera.yz) * u_camera.x + u_viewport * 0.5;
    // Template §3: NDC = screen / u_viewport * 2 − 1
    vec2 ndc = screen / u_viewport * 2.0 - 1.0;
    // §3 screen space is top-left y-down; GL NDC is y-up — flip at presentation.
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    v_dist = in_vec3.z;
    v_half = abs(in_vec3.z);
}
