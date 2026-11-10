class_name HugoPerformanceProfile
extends RefCounted
## Explicit visual tradeoffs only. Physics, source events and audio are identical.
## UI/output dimensions are independent of the internal 3D rendering scale.

const ORDER: Array[String] = ["quality", "balanced", "performance"]
const PRESETS: Dictionary = {
	"quality": {"msaa": 4, "render_scale": 1.0, "texture_quality": "enhanced", "texture_limit": 0},
	"balanced": {"msaa": 2, "render_scale": 1.0, "texture_quality": "enhanced", "texture_limit": 1024},
	"performance": {"msaa": 0, "render_scale": 0.75, "texture_quality": "enhanced", "texture_limit": 512}
}


static func apply_preset(raw: Dictionary, name: String) -> Dictionary:
	var result: Dictionary = raw.duplicate(true)
	if PRESETS.has(name):
		for key: String in PRESETS[name]:
			result[key] = PRESETS[name][key]
	return result


static func identify(raw: Dictionary) -> String:
	for name: String in ORDER:
		var matches: bool = true
		for key: String in PRESETS[name]:
			if raw.get(key) != PRESETS[name][key]:
				matches = false
				break
		if matches:
			return name
	return "custom"
