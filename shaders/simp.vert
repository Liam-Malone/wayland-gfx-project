#version 450

void main() {
    // gl_Position = vec4(a_pos, 0.0, 1.0);
    // v_color = a_color;
	 if (gl_VertexIndex == 0) {
	 	gl_Position = vec4(-0.5, -0.5, 0, 1);
	 } else  if (gl_VertexIndex == 1) {
	 	gl_Position = vec4(0, 0.5, 0, 1);
	 } else if (gl_VertexIndex == 2) {
	 	gl_Position = vec4(0.5, -0.5, 0, 1);
	 }
}
