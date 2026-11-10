// Continuous particle surfaces. No source sprite is sampled in this path.
// Detail is evaluated at output resolution, with derivative antialiasing.
// Uses ordinary spatial shading and depth sampling: no compute, vendor SDK,
// temporal history or hardware ray tracing is required.
uniform vec4 tint : source_color = vec4(1.0);
uniform int effect_profile = 0;
uniform float effect_age = 0.0;
uniform float effect_lifetime = 1.0;
uniform float effect_seed = 0.0;
uniform float particle_extent = 1.0;
uniform bool soft_particles = true;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;

float fx_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float fx_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	vec2 w = f * f * (3.0 - 2.0 * f);
	float a = fx_hash(cell);
	float b = fx_hash(cell + vec2(1.0, 0.0));
	float c = fx_hash(cell + vec2(0.0, 1.0));
	float d = fx_hash(cell + vec2(1.0));
	float n = mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
	// Fade frequencies smaller than a screen pixel; distant particles do not
	// shimmer and close particles retain true, newly generated surface detail.
	return mix(n, 0.5, smoothstep(0.35, 0.95, max(fwidth(p.x), fwidth(p.y))));
}

float fx_cloud(vec2 p) {
	float n = 0.54 * fx_noise(p);
	p = mat2(vec2(1.72, 1.11), vec2(-1.11, 1.72)) * p + vec2(8.3, 2.8);
	n += 0.27 * fx_noise(p);
	p = mat2(vec2(1.72, 1.11), vec2(-1.11, 1.72)) * p + vec2(5.7, 9.2);
	n += 0.13 * fx_noise(p);
	p = p * 2.03 + vec2(7.1, 3.2);
	return n + 0.06 * fx_noise(p);
}

float fx_coverage(float distance_to_edge) {
	float aa = max(fwidth(distance_to_edge), 0.0001);
	return 1.0 - smoothstep(-aa, aa, distance_to_edge);
}

vec4 fx_glint(vec2 p, bool red) {
	float r = length(p);
	float aa = max(length(fwidth(p)), 0.0001);
	vec2 q = abs(p);
	float cardinal = exp(-min(q.x, q.y) / max(0.012 + 0.085 * (1.0 - r), aa));
	float diagonal = exp(-abs(q.x - q.y) / max(0.010 + 0.035 * (1.0 - r), aa));
	float ray = (cardinal + 0.52 * diagonal) * pow(max(1.0 - r, 0.0), 1.9);
	float corona = exp(-r * r * 13.0) * 0.11;
	float core = exp(-r * r * 145.0);
	vec3 color = red ? vec3(1.0, 0.18, 0.075) : vec3(1.0, 0.68, 0.11);
	vec3 luminous = color * (ray * 0.80 + corona) + vec3(1.0, 0.95, 0.79) * core * 0.9;
	return vec4(luminous * (1.0 - smoothstep(0.90, 1.0, r)), 1.0);
}

vec4 fx_smoke(vec2 p) {
	float elapsed = effect_age * effect_lifetime;
	vec2 drift = vec2(effect_seed * 7.13, effect_seed * 3.71 - elapsed * 0.18);
	float coarse = fx_noise(p * 2.5 + drift);
	vec2 warp = vec2(coarse, fx_noise(p * 2.3 + drift + vec2(17.1, 1.7))) - 0.5;
	float n = fx_cloud(p * 3.7 + drift + warp * 0.7);
	float shape = 1.0 - smoothstep(0.30 + n * 0.21, 0.93, length(p));
	float volume = smoothstep(0.12, 0.82, n) * shape;
	float lit = 0.25 + 0.39 * n + 0.12 * coarse;
	return vec4(vec3(volume * lit), volume * 0.8);
}

vec4 fx_health(vec2 p) {
	float radius = 0.78;
	float r2 = dot(p, p) / (radius * radius);
	float cover = fx_coverage(length(p) - radius);
	vec3 normal = normalize(vec3(p / radius, sqrt(max(1.0 - r2, 0.001))));
	vec3 light = normalize(vec3(-0.45, -0.65, 0.78));
	float diffuse = max(dot(normal, light), 0.0);
	float pores = fx_noise(p * 36.0 + effect_seed * 14.0);
	float specular = pow(max(dot(normal, normalize(light + vec3(0.0, 0.0, 1.0))), 0.0), 48.0);
	float rim = pow(1.0 - max(normal.z, 0.0), 3.0);
	vec3 surface = vec3(0.26, 0.46, 0.025) * (0.47 + 0.64 * diffuse) * (0.96 + pores * 0.08);
	surface += vec3(0.81, 0.90, 0.50) * specular * 0.56 + vec3(0.18, 0.28, 0.01) * rim * 0.24;
	return vec4(surface, cover);
}

vec4 fx_ember(vec2 p) {
	float elapsed = effect_age * effect_lifetime;
	vec2 drift = vec2(effect_seed * 8.91, effect_seed * 2.77 - elapsed * 0.7);
	float coarse = fx_noise(p * 3.0 + drift);
	float n = fx_cloud(p * vec2(4.1, 3.3) + drift + vec2(coarse * 0.7, coarse));
	float radial = 1.0 - smoothstep(0.22, 0.98, length(p));
	float body = smoothstep(0.20, 0.73, n) * radial;
	float hot = smoothstep(0.42, 0.79, n) * radial;
	vec3 color = mix(vec3(0.36, 0.085, 0.012), vec3(1.0, 0.55, 0.10), hot);
	color += vec3(0.31, 0.25, 0.10) * hot * hot;
	return vec4(color * body, body);
}

vec4 fx_mote(vec2 p) {
	float r = length(p);
	float core = exp(-dot(p, p) * 4.8);
	float glow = exp(-dot(p, p) * 11.0);
	float grain = fx_noise(p * 10.0 + effect_seed * 6.7);
	float edge = 1.0 - smoothstep(0.68, 0.98, r);
	vec3 color = vec3(0.57, 0.69, 0.75) * core * (0.86 + 0.14 * grain);
	color += vec3(0.13, 0.14, 0.15) * glow;
	return vec4(color * edge, core * edge);
}

vec4 fx_stone(vec2 p) {
	float angle = atan(p.y, p.x);
	float radius = 0.74 + 0.045 * sin(angle * 5.0 + effect_seed * 4.0) + 0.025 * cos(angle * 9.0);
	float cover = fx_coverage(length(p) - radius);
	float rough = fx_cloud(p * 12.0 + effect_seed * 9.3);
	vec3 normal = normalize(vec3(p / radius, sqrt(max(1.0 - dot(p, p) / (radius * radius), 0.005))));
	vec2 relief = p * 7.0 + effect_seed * 9.3;
	vec2 slope = vec2(fx_noise(relief + vec2(0.12, 0.0)) - fx_noise(relief - vec2(0.12, 0.0)),
		fx_noise(relief + vec2(0.0, 0.12)) - fx_noise(relief - vec2(0.0, 0.12))) * 2.8;
	normal = normalize(normal + vec3(slope * max(normal.z, 0.0), 0.0));
	float diffuse = max(dot(normal, normalize(vec3(-0.45, -0.65, 0.7))), 0.0);
	float grain = fx_noise(p * 67.0 + effect_seed * 9.3);
	vec3 color = vec3(0.15, 0.16, 0.18) * (0.28 + 0.9 * diffuse) * (0.55 + 0.8 * rough);
	color *= 0.9 + grain * 0.2;
	return vec4(color, cover);
}

vec4 fx_surface(vec2 uv) {
	vec2 p = uv * 2.0 - 1.0;
	if (effect_profile == 0) { return fx_glint(p, false); }
	if (effect_profile == 1) { return fx_smoke(p); }
	if (effect_profile == 2) { return fx_glint(p, true); }
	if (effect_profile == 3) { return fx_health(p); }
	if (effect_profile == 4) { return fx_ember(p); }
	if (effect_profile == 5) { return fx_mote(p); }
	return fx_stone(p);
}

void fragment() {
	vec4 surface = fx_surface(UV);
	float intersection = 1.0;
	// The projection matrix handles reverse-Z. Compatibility uses OpenGL NDC,
	// whereas Mobile/Forward+ use [0, 1]. Source:
	// https://docs.godotengine.org/en/stable/tutorials/shaders/advanced_postprocessing.html
	if (soft_particles && effect_profile != 3 && effect_profile != 6) {
		float depth = texture(scene_depth, SCREEN_UV).r;
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 view_position = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		float scene_distance = -view_position.z / view_position.w;
		intersection = smoothstep(0.0, clamp(particle_extent * 0.08, 0.025, 0.35), scene_distance + VERTEX.z);
	}
	#if NATIVE_FX_BLEND == 1
		ALBEDO = vec3(1.0) - surface.rgb * tint.rgb * intersection;
		ALPHA = 1.0;
	#elif NATIVE_FX_BLEND == 2
		ALBEDO = surface.rgb * tint.rgb * intersection;
		ALPHA = 1.0;
	#else
		ALBEDO = surface.rgb * tint.rgb;
		ALPHA = surface.a * intersection;
	#endif
}
