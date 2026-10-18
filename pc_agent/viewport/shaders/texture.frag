#version 330 core

// Doc 08 textured quad sampling — image quads (white tint) and glyph labels (colour tint).
in vec2 v_uv;

uniform sampler2D u_tex;    // image texture or 128×64 digit glyph atlas
uniform vec4 u_tint;        // rgb tint (glyph colour) × alpha (style opacity)
uniform int u_blendMode;    // 0 = SRC_OVER, 1 = MULTIPLY (template §3)

out vec4 fragColor;

void main() {
    vec4 texel = texture(u_tex, v_uv);
    float alpha = texel.a * u_tint.a;
    if (alpha < 1.0 / 255.0) {
        discard;
    }
    if (u_blendMode == 1) {
        // MULTIPLY: the host pairs this output with
        // glBlendFunc(GL_DST_COLOR, GL_ZERO) (template §3), giving
        // dst * mix(1, color, alpha) with dst alpha preserved.
        fragColor = vec4(mix(vec3(1.0), texel.rgb * u_tint.rgb, alpha), 1.0);
    } else {
        // SRC_OVER: the host pairs this output with
        // glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA).
        fragColor = vec4(texel.rgb * u_tint.rgb, alpha);
    }
}
