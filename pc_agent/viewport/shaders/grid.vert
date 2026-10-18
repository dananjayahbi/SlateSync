#version 330 core

// Doc 08 fullscreen background quad — pattern evaluation lives in grid.frag.
in vec2 in_pos; // NDC corners (-1, -1) … (1, 1)

void main() {
    gl_Position = vec4(in_pos, 0.0, 1.0);
}
