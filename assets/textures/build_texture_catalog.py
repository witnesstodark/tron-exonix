"""
Build textures.blend — the level-design texture catalog (Stefan 2026-07-09).
One labeled PBR preview plane per texture set, arranged in three rows:
  CAPTURED 1-5   = claim_v4_1..5   (all in game today)
  CORRUPTED 1-5  = claim_c1..c5    (new: enemy-territory variants)
  UNCAPTURED 1-5 = unclaimed_B (in game), unclaimed_A (spare), unclaimed_C..E (new)
All image paths are RELATIVE — the file survives folder renames.
Run:  blender --background --factory-startup --python build_texture_catalog.py
"""
import bpy
from pathlib import Path

HERE = Path(__file__).parent if "__file__" in dir() else Path(bpy.data.filepath).parent
OUT = HERE.parent / "textures.blend"   # blend files live in the assets root, packed

ROWS = [
    ("CAPTURED", [("claim_v4_1", "in game"), ("claim_v4_2", "in game"), ("claim_v4_3", "in game"),
                  ("claim_v4_4", "in game"), ("claim_v4_5", "in game")]),
    ("CORRUPTED", [("claim_c1", "new"), ("claim_c2", "new"), ("claim_c3", "new"),
                   ("claim_c4", "new"), ("claim_c5", "new")]),
    ("UNCAPTURED", [("unclaimed_B", "in game"), ("unclaimed_A", "spare"), ("unclaimed_C", "new"),
                    ("unclaimed_D", "new"), ("unclaimed_E", "new")]),
]
STEP, SIZE = 6.0, 4.4

bpy.ops.wm.read_homefile(use_empty=True)
scene = bpy.context.scene

# dark world so emission reads like in the game
world = bpy.data.worlds.new("Void")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.004, 0.006, 0.01, 1.0)
scene.world = world


def load_img(set_name: str, map_name: str, non_color: bool):
    p = HERE / set_name / f"{map_name}.webp"
    if not p.exists():
        return None
    img = bpy.data.images.load(str(p))
    img.name = f"{set_name}_{map_name}"
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    return img


def make_material(set_name: str):
    mat = bpy.data.materials.new(set_name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    x = -520
    for map_name, sock, non_color in [("basecolor", "Base Color", False),
                                      ("roughness", "Roughness", True),
                                      ("metalness", "Metallic", True),
                                      ("emission", "Emission Color", False)]:
        img = load_img(set_name, map_name, non_color)
        if not img:
            continue
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = img
        node.location = (x, 500 - 300 * len([n for n in nt.nodes if n.type == "TEX_IMAGE"]))
        nt.links.new(node.outputs["Color"], bsdf.inputs[sock])
    if load_img(set_name, "emission", False):
        bsdf.inputs["Emission Strength"].default_value = 3.0
    nimg = load_img(set_name, "normal", True)
    if nimg:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = nimg
        tex.location = (x - 320, -700)
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.location = (x, -700)
        nt.links.new(tex.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


label_mat = bpy.data.materials.new("LabelWhite")
label_mat.use_nodes = True
lb = label_mat.node_tree.nodes["Principled BSDF"]
lb.inputs["Emission Color"].default_value = (0.85, 0.97, 1.0, 1.0)
lb.inputs["Emission Strength"].default_value = 2.0

for row_i, (row_name, sets) in enumerate(ROWS):
    y = -row_i * (STEP + 2.2)
    for col_i, (set_name, tag) in enumerate(sets):
        if not (HERE / set_name).exists():
            print(f"  SKIP missing set {set_name}")
            continue
        x = col_i * STEP
        bpy.ops.mesh.primitive_plane_add(size=SIZE, location=(x, y, 0))
        plane = bpy.context.active_object
        plane.name = f"{row_name}_{col_i + 1}__{set_name}"
        plane.data.materials.append(make_material(set_name))
        # label: big row name + number, small folder + status
        txt = bpy.data.curves.new(f"lbl_{set_name}", type="FONT")
        txt.body = f"{row_name} {col_i + 1}\n{set_name} · {tag}"
        txt.size = 0.44
        txt.align_x = "CENTER"
        ob = bpy.data.objects.new(f"Label_{set_name}", txt)
        ob.location = (x, y + SIZE / 2 + 0.35, 0.01)
        ob.data.materials.append(label_mat)
        bpy.context.collection.objects.link(ob)

# top-down camera framing the grid + a soft sun
cx, cy = 2 * STEP, -(STEP + 2.2)
cam = bpy.data.cameras.new("Cam")
cam.type = "ORTHO"
cam.ortho_scale = 5.0 * STEP
scene.render.resolution_x = 1600
scene.render.resolution_y = 1400
cam_ob = bpy.data.objects.new("Camera", cam)
cam_ob.location = (cx, cy, 30)
bpy.context.collection.objects.link(cam_ob)
scene.camera = cam_ob
sun = bpy.data.lights.new("Sun", type="SUN")
sun.energy = 2.0
sun_ob = bpy.data.objects.new("Sun", sun)
sun_ob.location = (cx, cy, 20)
sun_ob.rotation_euler = (0.35, 0.15, 0)
bpy.context.collection.objects.link(sun_ob)

# open straight into Material Preview, looking at the grid top-down
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == "VIEW_3D":
            for space in area.spaces:
                if space.type == "VIEW_3D":
                    space.shading.type = "MATERIAL"
                    space.region_3d.view_perspective = "ORTHO"

# save first (pack needs a saved file), then embed every texture -> self-contained
bpy.ops.wm.save_as_mainfile(filepath=str(OUT), compress=True)
bpy.ops.file.pack_all()
bpy.ops.wm.save_mainfile(compress=True)
print(f"SAVED {OUT} ({OUT.stat().st_size // 1024} KB, all textures packed)")
