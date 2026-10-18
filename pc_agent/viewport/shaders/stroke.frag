#version 330 core

// Doc 07 fragment stage — fwidth-based smoothstep AA over the analytic edge
// distance produced by the strip layout (edge verts carry ±hw, centers 0).
in float v_dist; // interpolated signed distance to the centerline
in float v_half; // interpolated |half width| — the analytic stroke edge

uniform vec3 u_color;    // stroke RGB
uniform float u_opacity; // style opacity multiplier (1.0 for live strokes)
uniform int u_blendMode; // 0 = SRC_OVER, 1 = MULTIPLY (highlighter)

out vec4 fragColor;

void main() {
    float d = abs(v_dist);
    float aa = fwidth(d);
    float alpha = 1.0 - smoothstep(v_half - aa, v_half + aa, d);
    if (alpha < 1.0 / 255.0) {
        discard;
    }
    if (u_blendMode == 1) {
        // MULTIPLY: the host pairs this output with
        // glBlendFunc(GL_DST_COLOR, GL_ZERO) (template §3), giving
        // dst * mix(1, color, alpha · opacity) with dst alpha preserved.
        fragColor = vec4(mix(vec3(1.0), u_color, alpha * u_opacity), 1.0);
    } else {
        // SRC_OVER: the host pairs this output with
        // glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA).
        fragColor = vec4(u_color, alpha * u_opacity);
    }
}
