// Genuine shared 3D orb/debris meshes. Detail is evaluated in object space,
// independent of the former 16/32 px sprite. Geometry writes depth normally.
uniform vec4 tint : source_color = vec4(1.0);
uniform int effect_profile = 3;
uniform float effect_seed = 0.0;
uniform float effect_rotation = 0.0;
uniform float effect_age = 0.0;
uniform float effect_lifetime = 1.0;
uniform float particle_extent = 1.0;
varying vec3 solid_position;

float solid_hash(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float solid_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	vec3 w = f * f * (3.0 - 2.0 * f);
	float a = mix(solid_hash(cell), solid_hash(cell + vec3(1.0, 0.0, 0.0)), w.x);
	float b = mix(solid_hash(cell + vec3(0.0, 1.0, 0.0)), solid_hash(cell + vec3(1.0, 1.0, 0.0)), w.x);
	float c = mix(solid_hash(cell + vec3(0.0, 0.0, 1.0)), solid_hash(cell + vec3(1.0, 0.0, 1.0)), w.x);
	float d = mix(solid_hash(cell + vec3(0.0, 1.0, 1.0)), solid_hash(cell + vec3(1.0, 1.0, 1.0)), w.x);
	float n = mix(mix(a, b, w.y), mix(c, d, w.y), w.z);
	vec3 footprint = fwidth(p);
	return mix(n, 0.5, smoothstep(0.35, 0.95, max(footprint.x, max(footprint.y, footprint.z))));
}

void vertex() {
	solid_position = VERTEX;
	// Tumble around two axes using only the native angle and existing seed.
	// Camera-facing transparent particles keep their separate quad pipeline.
	if (effect_profile == 6) {
		float a = effect_rotation * 0.71 + effect_seed * 6.2831853;
		float b = effect_rotation * 0.37 + effect_seed * 3.1415927;
		mat3 ry = mat3(vec3(cos(a), 0.0, -sin(a)), vec3(0.0, 1.0, 0.0), vec3(sin(a), 0.0, cos(a)));
		mat3 rx = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, cos(b), sin(b)), vec3(0.0, -sin(b), cos(b)));
		VERTEX = ry * rx * VERTEX;
		NORMAL = ry * rx * NORMAL;
	}
}

void fragment() {
	vec3 normal = normalize(NORMAL);
	vec3 light = normalize(vec3(-0.45, 0.65, 0.78));
	float diffuse = max(dot(normal, light), 0.0);
	float grain = solid_noise(solid_position * 165.0 + effect_seed * 19.0);
	vec3 surface;
	if (effect_profile == 3) {
		float highlight = pow(max(dot(normal, normalize(light + vec3(0.0, 0.0, 1.0))), 0.0), 48.0);
		float rim = pow(1.0 - max(normal.z, 0.0), 3.0);
		surface = vec3(0.26, 0.46, 0.025) * (0.47 + 0.64 * diffuse) * (0.97 + grain * 0.06);
		surface += vec3(0.81, 0.90, 0.50) * highlight * 0.56 + vec3(0.18, 0.28, 0.01) * rim * 0.24;
	} else {
		float coarse = solid_noise(solid_position * 21.0 + effect_seed * 9.3);
		float fine = solid_noise(solid_position * 54.0 + effect_seed * 2.7);
		surface = vec3(0.15, 0.16, 0.18) * (0.28 + 0.90 * diffuse) * (0.55 + coarse * 0.60 + fine * 0.20);
		surface *= 0.90 + grain * 0.20;
	}
	#if NATIVE_FX_BLEND == 1
		ALBEDO = vec3(1.0) - surface * tint.rgb;
		ALPHA = 1.0;
	#elif NATIVE_FX_BLEND == 2
		ALBEDO = surface * tint.rgb;
		ALPHA = 1.0;
	#else
		ALBEDO = surface * tint.rgb;
	#endif
}
