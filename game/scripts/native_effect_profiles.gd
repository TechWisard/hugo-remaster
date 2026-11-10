class_name NativeEffectProfiles
extends RefCounted
## Identity-based visual replacements for every sprite used by the imported
## campaign's CEmitters. A hash identifies source pixels, not an inferred name.
## Motion, blend mode, tint, lifetime, frames and pool budgets remain source data.

enum Kind { GOLD_GLINT, CLOUD, RED_GLINT, HEALTH_ORB, EMBER_CLOUD, LIGHT_MOTE, STONE }

const NAMES: PackedStringArray = ["gold_glint", "cloud", "red_glint", "health_orb", "ember_cloud", "light_mote", "stone"]
const PIXEL_PROFILES: Dictionary = {
	"64x64:d64f3d2bccf0f19a8a2f7a79d24701c971d13055d966cab755f428b7d6335451": Kind.GOLD_GLINT,
	"64x64:caef497b386c536359a87152e25666c4f12afad9687b32136b623503d040c595": Kind.CLOUD,
	"32x32:07726403ee87ba9d9f315cb9afaaaa603669e5d1a4c0363a4957c0ca51084dff": Kind.RED_GLINT,
	"32x32:a2405d2de63fc7792d0bc7c775b3968d4a192402114e6d20ac2226af1040c590": Kind.HEALTH_ORB,
	"64x64:a42ce61904c451cc72efee31dda35410d67af969abb9ca7f21fa55348f3be34b": Kind.EMBER_CLOUD,
	"16x16:750a50ddc5653f6b7dd79710af10ed2e7e9a8afee6acd180fe1555dd4d2f17b5": Kind.LIGHT_MOTE,
	"16x16:7096fd95988c6c4aaeb0394df41948fe9fc98ba6ceaa3d61fbf8a2d3972753d2": Kind.STONE,
}

# Godot's default PNG import fixes RGB under zero alpha for filtered borders.
# These two measured import identities retain the same visible pixels/alpha.
const IMPORT_IDENTITIES: Dictionary = {
	"32x32:5b5d692f4cc330c2b7310fb5c690fc5b23ebf5850358165f9dddc83131fe889d": "32x32:a2405d2de63fc7792d0bc7c775b3968d4a192402114e6d20ac2226af1040c590",
	"16x16:d2b48ed97a729bde850f631d758f20515f46a490e3927a2c1a85510363c36d37": "16x16:7096fd95988c6c4aaeb0394df41948fe9fc98ba6ceaa3d61fbf8a2d3972753d2",
}


static func identify(texture: Texture2D) -> Dictionary:
	if texture == null:
		return {"key": "", "profile": -1}
	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		return {"key": "", "profile": -1}
	if image.is_compressed() and image.decompress() != OK:
		return {"key": "", "profile": -1}
	image.convert(Image.FORMAT_RGBA8)
	# Imported textures may contain mips; only base-level pixels identify art.
	image.clear_mipmaps()
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(image.get_data())
	var key: String = "%dx%d:%s" % [image.get_width(), image.get_height(), hashing.finish().hex_encode()]
	key = str(IMPORT_IDENTITIES.get(key, key))
	return {"key": key, "profile": int(PIXEL_PROFILES.get(key, -1))}
