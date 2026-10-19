#version 330 core

// Doc 08 fragment stage: fill coverage, fwidth AA for lines, feathered page shadow.
in vec4 v_rgba;
in float v_aux;  // interpolated signed line distance
in float v_hw;   // |half width| (per-vertex, constant across a line quad)
in vec2 v_world; // world position

uniform int u_kind;         // 0 fill, 1 antialiased line, 2 artboard drop-shadow quad
uniform vec2 u_pageSize;    // (w, h) artboard world size — kind 2
uniform vec2 u_shadowOf;    // (offset, feather) — kind 2 (offset ≈ 0.02·min(w,h), feather ≈ 3×offset)
uniform vec4 u_shadowColor; // drop-shadow RGBA — kind 2
uniform int u_blendMode;    // 0 = SRC_OVER, 1 = MULTIPLY (template §3)

out vec4 fragColor;

void main() {
    vec3 color;
    float alpha;
    if (u_kind == 2) {
        // Feathered drop-shadow: separable smoothstep falloff outside the offset
        // shadow rect, masked away inside the page (the background pass already
        // painted the page opaquely).
        float o = u_shadowOf.x;
        float f = u_shadowOf.y;
        float lx = smoothstep(o - f, o, v_world.x);
        float rx = 1.0 - smoothstep(u_pageSize.x + o, u_pageSize.x + o + f, v_world.x);
        float ly = smoothstep(o - f, o, v_world.y);
        float ry = 1.0 - smoothstep(u_pageSize.y + o, u_pageSize.y + o + f, v_world.y);
        float outside = 1.0;
        if (v_world.x > 0.0 && v_world.y > 0.0 &&
            v_world.x < u_pageSize.x && v_world.y < u_pageSize.y) {
            // Only the page INTERIOR is masked — the feather band left of / below
            // the page (world x < 0 or y < 0) must still paint.
            outside = 0.0;
        }
        color = u_shadowColor.rgb;
        alpha = clamp(lx * rx * ly * ry, 0.0, 1.0) * outside * u_shadowColor.a;
    } else if (u_kind == 1) {
        // Line AA: |signed distance| smoothsteped against the analytic half width.
        float aa = fwidth(v_aux);
        color = v_rgba.rgb;
        alpha = (1.0 - smoothstep(v_hw - aa, v_hw + aa, abs(v_aux))) * v_rgba.a;
    } else {
        color = v_rgba.rgb;
        alpha = v_rgba.a;
    }
    if (alpha < 1.0 / 255.0) {
        discard;
    }
    if (u_blendMode == 1) {
        // MULTIPLY: the host pairs this output with
        // glBlendFunc(GL_DST_COLOR, GL_ZERO) (template §3), giving
        // dst * mix(1, color, alpha) with dst alpha preserved.
        fragColor = vec4(mix(vec3(1.0), color, alpha), 1.0);
    } else {
        // SRC_OVER: the host pairs this output with
        // glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA).
        fragColor = vec4(color, alpha);
    }
}
