extends SceneTree
## Build mipmaps in the editor import, retaining lossless maximum-quality pixels.
## Run after an initial --import, then run --import again to rebuild these six assets.


func _initialize() -> void:
	var manifest: String = "res://assets/hd/texture_pack.json"
	if not FileAccess.file_exists(manifest):
		print("HD_IMPORTS no optional texture pack")
		quit(0)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest))
	if not parsed is Dictionary:
		quit(1)
		return
	var modified: int = 0
	for texture: Dictionary in parsed.get("textures", {}).values():
		var relative: String = str(texture.get("path", ""))
		if relative.is_empty() or relative.is_absolute_path() or ":" in relative or ".." in relative.split("/"):
			quit(1)
			return
		var path: String = manifest.get_base_dir().path_join(relative) + ".import"
		var config := ConfigFile.new()
		if config.load(path) != OK:
			push_error("Run the initial Godot import before preparing HD mipmaps")
			quit(1)
			return
		config.set_value("params", "mipmaps/generate", true)
		config.set_value("params", "compress/mode", 0)
		config.set_value("params", "detect_3d/compress_to", 0)
		if config.save(path) != OK:
			quit(1)
			return
		modified += 1
	print("HD_IMPORTS ", JSON.stringify({"textures": modified, "mipmaps": true, "compression": "lossless", "next": "run Godot --import"}))
	quit(0)
