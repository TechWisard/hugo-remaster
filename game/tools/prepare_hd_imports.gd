extends SceneTree
## Build mipmaps in the editor import, retaining lossless maximum-quality pixels.
## Run after an initial --import, then --import again to rebuild the whole pack.


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
	var native_resources: int = 0
	var visited: Dictionary = {}
	var paths: Array[String] = []
	for texture: Dictionary in parsed.get("textures", {}).values():
		paths.append(str(texture.get("path", "")))
		for tier: Variant in texture.get("tiers", {}).values():
			paths.append(str(tier))
	for relative: String in paths:
		if relative.is_empty() or relative.is_absolute_path() or ":" in relative or ".." in relative.split("/") or "\\" in relative:
			quit(1)
			return
		if visited.has(relative):
			continue
		visited[relative] = true
		var resource_path: String = manifest.get_base_dir().path_join(relative)
		if relative.get_extension().to_lower() in ["tres", "res"]:
			var texture: Texture2D = ResourceLoader.load(resource_path, "Texture2D") as Texture2D
			if texture == null:
				push_error("Native HD resource is not a Texture2D: " + relative)
				quit(1)
				return
			# GradientTexture2D and other native textures have no .import file
			# and no universal mipmap property. HugoTexturePack.resolve obtains
			# their Image and builds the mip chain once per retained live resource.
			native_resources += 1
			continue
		var path: String = resource_path + ".import"
		var config := ConfigFile.new()
		if config.load(path) != OK:
			push_error("Run the initial Godot import before preparing HD mipmaps")
			quit(1)
			return
		config.set_value("params", "mipmaps/generate", true)
		config.set_value("params", "compress/mode", 0)
		config.set_value("params", "detect_3d/compress_to", 0)
		# Transparent UV islands need RGB dilation without premultiplying alpha;
		# the source blend equations multiply alpha in their own verified way.
		config.set_value("params", "process/fix_alpha_border", true)
		config.set_value("params", "process/premult_alpha", false)
		if config.save(path) != OK:
			quit(1)
			return
		modified += 1
	print("HD_IMPORTS ", JSON.stringify({"textures": modified, "native_texture_resources": native_resources,
		"unique_paths_including_tiers": visited.size(), "mipmaps": true, "compression": "lossless", "next": "run Godot --import"}))
	quit(0)
