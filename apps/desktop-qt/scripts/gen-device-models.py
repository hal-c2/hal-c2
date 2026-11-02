# Generates the 3D device bodies DeviceBody3D loads (qml/HalC2/Bricks/models):
# a generic phone, a generic tablet, and a keyboard cover for the tablet.
# Every shape is drawn here from rounded slabs and cylinders, so the models
# carry the repository's licence and no one else's assets.
#
#   blender -b --factory-startup --python scripts/gen-device-models.py -- qml/HalC2/Bricks/models
#
# The contract with DeviceBody3D, in glTF axes (Y up, the screen facing +Z):
# the body is portrait, its screen centred on the origin and 2.2 units tall,
# and its front lies behind z = 0.06, where the live screen is drawn. The
# keyboard shares the tablet's axes with the tablet turned to landscape.
import math
import sys

import bmesh
import bpy

# Blender is Z up and glTF Y up: a glTF point (x, y, z) is Blender (x, -z, y),
# so the screen faces Blender's -Y and "front" is negative y below.
FRONT = -0.05


def material(name, colour, metallic=0.0, roughness=0.5):
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*colour, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def finish(obj, mat, bevel):
    obj.data.materials.append(mat)
    bpy.context.collection.objects.link(obj)
    if bevel > 0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 4
        mod.limit_method = "ANGLE"
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier="bevel") if bevel > 0 else None
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    obj.select_set(False)
    return obj


def rounded_rect(width, height, radius, segments=12):
    """The outline of a rounded rectangle centred on the origin."""
    points = []
    cx, cz = width / 2 - radius, height / 2 - radius
    for sx, sz, start in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
        for i in range(segments + 1):
            a = math.radians(start + 90 * i / segments)
            points.append((sx * cx + radius * math.cos(a), sz * cz + radius * math.sin(a)))
    return points


def slab(name, mat, width, height, radius, y0, y1, x=0.0, z=0.0, bevel=0.0, segments=12):
    """A rounded rectangle in the X-Z plane, from depth y0 to y1."""
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    outline = rounded_rect(width, height, min(radius, width / 2, height / 2) - 1e-4, segments)
    front = [bm.verts.new((x + px, y0, z + pz)) for px, pz in outline]
    back = [bm.verts.new((x + px, y1, z + pz)) for px, pz in outline]
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)
    n = len(outline)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    return finish(bpy.data.objects.new(name, mesh), mat, bevel)


def flat(name, mat, width, depth, radius, z0, z1, x=0.0, y=0.0, bevel=0.0, segments=12):
    """A rounded rectangle lying in the X-Y plane, from height z0 to z1."""
    obj = slab(name, mat, width, depth, radius, -z1, -z0, bevel=bevel, segments=segments)
    obj.rotation_euler = (math.radians(-90), 0, 0)
    obj.location = (x, y, 0)
    return obj


def disc(name, mat, radius, y0, y1, x, z, axis="Y"):
    """A cylinder along the depth axis (or along X for a hinge)."""
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=radius, depth=abs(y1 - y0))
    obj = bpy.context.active_object
    obj.name = name
    if axis == "Y":
        obj.rotation_euler = (math.radians(90), 0, 0)
        obj.location = (x, (y0 + y1) / 2, z)
    else:
        obj.rotation_euler = (0, math.radians(90), 0)
        obj.location = ((y0 + y1) / 2, x, z)
    obj.data.materials.append(mat)
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    obj.select_set(False)
    return obj


def palette():
    return {
        "frame": material("frame", (0.3, 0.305, 0.315), metallic=1.0, roughness=0.3),
        "back": material("back", (0.035, 0.036, 0.04), roughness=0.45),
        "glass": material("glass", (0.008, 0.008, 0.01), roughness=0.06),
        "lens": material("lens", (0.01, 0.012, 0.02), roughness=0.04),
        "ring": material("ring", (0.25, 0.26, 0.28), metallic=1.0, roughness=0.25),
        "island": material("island", (0.05, 0.051, 0.055), roughness=0.3),
        "flash": material("flash", (0.85, 0.8, 0.65), roughness=0.4),
        "fabric": material("fabric", (0.022, 0.022, 0.024), roughness=0.85),
        "key": material("key", (0.008, 0.008, 0.009), roughness=0.6),
        "pad": material("pad", (0.03, 0.03, 0.032), roughness=0.35),
    }


def device(name, screen_w, bezel, radius, thickness, camera):
    """A slab with a glass front, a frame and a back with a camera island."""
    m = palette()
    w, h = screen_w + 2 * bezel, 2.2 + 2 * bezel
    back = FRONT + thickness
    slab(f"{name}-frame", m["frame"], w, h, radius, FRONT + 0.006, back - 0.006, bevel=thickness * 0.3)
    slab(f"{name}-front", m["glass"], w - 0.012, h - 0.012, radius - 0.006, FRONT, FRONT + 0.01, bevel=0.003)
    slab(f"{name}-back", m["back"], w - 0.03, h - 0.03, radius - 0.015, back - 0.01, back, bevel=0.003)
    camera(m, w, h, back)


def phone_camera(m, w, h, back):
    # Seen from behind the left edge is +x: the island sits top-left there.
    size = w * 0.42
    x, z = w / 2 - 0.06 - size / 2, h / 2 - 0.06 - size / 2
    slab("phone-island", m["island"], size, size, size * 0.28, back - 0.002, back + 0.022, x, z, bevel=0.006)
    for dz in (size * 0.22, -size * 0.22):
        lx = x + size * 0.2
        disc("phone-ring", m["ring"], size * 0.19, back + 0.02, back + 0.05, lx, z + dz)
        disc("phone-lens", m["lens"], size * 0.13, back + 0.048, back + 0.052, lx, z + dz)
    disc("phone-flash", m["flash"], size * 0.06, back + 0.02, back + 0.026, x - size * 0.25, z + size * 0.22)


def tablet_camera(m, w, h, back):
    size = w * 0.11
    x, z = w / 2 - 0.07 - size / 2, h / 2 - 0.07 - size / 2
    slab("tablet-island", m["island"], size, size, size * 0.3, back - 0.002, back + 0.012, x, z, bevel=0.004)
    disc("tablet-ring", m["ring"], size * 0.3, back + 0.01, back + 0.025, x, z)
    disc("tablet-lens", m["lens"], size * 0.2, back + 0.024, back + 0.027, x, z)


def keyboard():
    """A keyboard cover for the tablet held in landscape (its 2.2-unit side
    across): a back panel behind it, a hinge, and a base with keys and a
    trackpad lying in front of its lower edge."""
    m = palette()
    across, tall = TABLET_W_LANDSCAPE, TABLET_H_LANDSCAPE
    back = FRONT + TABLET_THICKNESS
    slab("cover-panel", m["fabric"], across + 0.02, tall + 0.02, TABLET_RADIUS + 0.01, back + 0.004, back + 0.03, bevel=0.008)
    bottom = -tall / 2
    disc("cover-hinge", m["fabric"], 0.035, -across / 2, across / 2, back + 0.017, bottom - 0.02, axis="X")
    depth = across * 0.68
    base_back = back + 0.04
    top = bottom - 0.035
    flat("cover-base", m["fabric"], across + 0.02, depth, 0.08, top - 0.05, top, y=base_back - depth / 2, bevel=0.012)
    # Six rows of fourteen keys, the bottom row with a long space bar.
    cols, rows = 14, 6
    pitch = (across - 0.2) / cols
    key = pitch * 0.82
    first_row = base_back - 0.12 - pitch / 2
    for r in range(rows):
        y = first_row - r * pitch
        if r == rows - 1:
            widths = [1, 1, 1, 1.3, 5.4, 1.3, 1, 1, 1]
        else:
            widths = [1] * cols
        scale = cols / sum(widths)
        x = -(across - 0.2) / 2
        for kw in widths:
            span = kw * scale * pitch
            flat("cover-key", m["key"], span - (pitch - key), key * (0.6 if r == 0 else 1), 0.012, top, top + 0.012, x + span / 2, y, segments=3)
            x += span
    pad_w, pad_d = across * 0.38, depth - (0.12 + rows * pitch) - 0.12
    flat("cover-trackpad", m["pad"], pad_w, pad_d, 0.03, top, top + 0.002, y=base_back - depth + 0.06 + pad_d / 2)


# A 13-inch tablet's 4:3 screen, and a tall phone's 9:19.5.
TABLET_SCREEN_W = 2.2 * 3 / 4
TABLET_BEZEL = 0.075
TABLET_THICKNESS = 0.045
TABLET_RADIUS = 0.13
TABLET_W_LANDSCAPE = 2.2 + 2 * TABLET_BEZEL
TABLET_H_LANDSCAPE = TABLET_SCREEN_W + 2 * TABLET_BEZEL

MODELS = {
    "phone": lambda: device("phone", 2.2 * 9 / 19.5, 0.05, 0.16, 0.13, phone_camera),
    "tablet": lambda: device("tablet", TABLET_SCREEN_W, TABLET_BEZEL, TABLET_RADIUS, TABLET_THICKNESS, tablet_camera),
    "tablet-keyboard": keyboard,
}


def main():
    out = sys.argv[sys.argv.index("--") + 1]
    for name, build in MODELS.items():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        build()
        bpy.ops.export_scene.gltf(
            filepath=f"{out}/{name}.glb",
            export_format="GLB",
            export_yup=True,
            export_apply=True,
            export_normals=True,
            export_texcoords=False,
            export_materials="EXPORT",
            export_cameras=False,
            export_lights=False,
        )


main()
