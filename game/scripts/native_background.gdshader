shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

uniform sampler2D source_texture : source_color, filter_nearest, repeat_enable;
uniform bool has_texture = false;
uniform vec4 background_tint : source_color = vec4(1.0);

void vertex() {
	// CBackmap is a camera-centred backdrop, drawn behind the world. Preserve
	// its source perspective without writing a foreground depth shell.
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.z = (CLIP_SPACE_FAR + 0.000001) * POSITION.w;
}

void fragment() {
	vec4 texel = has_texture ? texture(source_texture, UV) : vec4(1.0);
	if (texel.a < 0.5) { discard; }
	ALBEDO = texel.rgb * background_tint.rgb * COLOR.rgb;
}
