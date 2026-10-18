#version 330 core

// Doc 07 §4 explicit decision: this geometry stage is a MINIMAL pass-through stub.
// Round end caps are baked into the CPU-side vertex buffer (8-segment fans built by
// stroke_tessellator.build_strip), so this stage performs NO vertex- or
// primitive-emission expansion — the output stream would be left untouched by a
// future identity implementation.
//
// The file exists only so the optional-geometry hook stays stable for future
// miter/join work without changing ProgramRegistry's <stem>.vert + <stem>.frag
// contract; the program loader intentionally does not link this file yet (linking
// a geometry stage that emits nothing would discard every primitive).
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

void main() {
    // Intentionally empty: pass-through hook only (emission lives on the CPU pass).
}
