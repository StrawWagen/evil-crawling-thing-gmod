import json
import math
import os
import sys

import bpy
from mathutils import Quaternion, Vector

SCALE = 0.02
SIDES = 20
SUB = 10
SEED = 777
REAR_ARC = 45
SUN = 4
LAMP = 0.6
SKY = 1.0
SKY_COLOR = tuple((c / 255) ** 2.2 for c in (142, 164, 178)) + (1,)

FLESH = (44, 34, 40)
BONE = (170, 160, 145)

SHOTS = {
    "icon": dict(at=(-2000, -3300, -200), toward=(0, 0, -1), yaw=200, size=(512, 512), cam=(-3.2, -3.0, 4.4),
                 look=(0, 0, -0.3), lens=50, exposure=1.6),
    "icon_loose": dict(at=(-2720, -1170, 100), toward=(0, 0, 1), yaw=0, size=(512, 512), cam=(4.0, 3.0, 4.2),
                       look=(0, 0, -0.2), lens=40, exposure=2.2,
                       fill=[("AREA", (3, 3, 3.5), 60, (0.6, 0.72, 1.0), 2.0)]),
    "thumbnail": dict(at=(-2250, -1400, 0), toward=(0, 0, -1), yaw=0, size=(1024, 1024), cam=(-4.4, -3.2, 2.3),
                      look=(0.2, 0, -0.45), lens=40, exposure=0.4),
    "preview_floor": dict(at=(-2000, -3300, -200), toward=(0, 0, -1), yaw=30, size=(1920, 1080), cam=(-6.0, -4.0, 2.8),
                          look=(0.4, 0, -0.4), lens=35, exposure=1.6),
    "clickbait": dict(at=(-2420, -1300, 0), toward=(0, 0, -1), cam_world=(-2815, -1095, -112), size=(2560, 1440),
                      look=(0, 0, 0.1), lens=60, roll=-7, fstop=2.8, rear=True, lead=0.6, exposure=0.6,
                      flashlight=(3000, 40)),
    "preview_ceiling": dict(at=(-2400, -1500, 100), toward=(0, 0, 1), yaw=0, size=(1920, 1080), cam=(2.5, 5.5, 4.4),
                            look=(0, 0, -0.3), lens=28, exposure=1.4,
                            fill=[("AREA", (2, 4, 3.5), 40, (0.6, 0.72, 1.0), 2.0)]),
    "killicon": dict(size=(1024, 512), cam=(0, -8, 1), look=(0, 0, 0), ortho=8, silhouette=True),
}


def rng(seed):
    s = seed % 2147483646 + 1

    def rand(a=None, b=None):
        nonlocal s
        s = s * 16807 % 2147483647
        f = (s - 1) / 2147483646
        return a + f * (b - a) if a is not None else f

    return rand


def grow(seed):
    rand = rng(seed)
    integer = lambda a, b: math.floor(rand(a, b + 1))

    def on_sphere(r, min_z, max_z):
        yaw = math.radians(rand(0, 360))
        z = rand(min_z, max_z)
        flat = math.sqrt(1 - z * z)
        return Vector((math.cos(yaw) * flat * r, math.sin(yaw) * flat * r, z * r))

    def segments(count, total):
        lengths = [rand(0.6, 1.4) for _ in range(count)]
        s = sum(lengths)
        return [l / s * total for l in lengths]

    creature = dict(churn=rand(-30, 30), phase=rand(0, 100), legs=[])
    count = integer(8, 12)
    reach = 0
    for i in range(count):
        segs = integer(3, 5)
        length = rand(150, 230)
        reach += length
        leg = dict(segments=segs, length=length)
        leg["root"] = on_sphere(rand(3, 7), -0.5, 1)
        leg["angle"] = i / count * 360 + rand(-14, 14)
        leg["spread"] = rand(0.45, 0.65)
        leg["lengths"] = segments(segs, length)
        leg["width"] = rand(2.5, 4.5)
        for name, a, b in (("stepDistance", 35, 65), ("stepTime", 0.2, 0.34), ("stepHeight", 20, 45)):
            leg[name] = rand(a, b)
        leg["pitch"] = integer(55, 120)
        leg["phase"] = rand(0, 100)
        leg["freq"] = rand(0.6, 2.4)
        leg["shade"] = rand(0.75, 1.2)
        creature["legs"].append(leg)
    creature["height"] = reach / count * 0.36
    return creature


def wobble(t, phase, freq):
    return Vector((
        math.sin(t * freq + phase) + 0.5 * math.sin(t * freq * 2.3 + phase * 1.7),
        math.sin(t * freq * 1.3 + phase * 2.1) + 0.5 * math.sin(t * freq * 2.9 + phase),
        math.sin(t * freq * 0.9 + phase * 3.3) + 0.5 * math.sin(t * freq * 3.1 + phase * 0.6),
    ))


def solve_chain(points, lengths, root, target, iterations):
    n = len(points)
    for _ in range(iterations):
        points[n - 1] = target.copy()
        for i in range(n - 2, -1, -1):
            points[i] = points[i + 1] + (points[i] - points[i + 1]).normalized() * lengths[i]
        points[0] = root.copy()
        for i in range(1, n):
            points[i] = points[i - 1] + (points[i] - points[i - 1]).normalized() * lengths[i - 1]


def pose(creature, up, fwd, t, feel=None, origin=Vector(), lead=Vector(), agitation=0.6):
    h = creature["height"]
    left = up.cross(fwd)
    shake = 0.04 + 0.04 * agitation

    def world(v):
        return fwd * v.x + left * v.y + up * v.z

    pos = origin + up * h
    threat = None
    if feel is not None:
        d = feel - pos
        threat = math.degrees(math.atan2(d.dot(left), d.dot(fwd)))

    chains = []
    for leg in creature["legs"]:
        root = pos + world(leg["root"])
        yaw = math.radians(leg["angle"])
        rest = pos + (fwd * math.cos(yaw) + left * math.sin(yaw)) * (leg["length"] * leg["spread"]) + lead
        foot = rest - up * (rest - origin).dot(up)
        bow_k = 0.35
        off = (leg["angle"] - threat + 180) % 360 - 180 if threat is not None else 180
        if abs(off) < REAR_ARC:
            to = (feel - root).normalized()
            to = Quaternion(up, math.radians(off * 1.2)) @ to
            to = (to + up * (0.12 + 0.2 * math.sin(leg["phase"]))).normalized()
            foot = root + to * (leg["length"] * 0.9) + wobble(t * 3, leg["phase"], leg["freq"]) * (leg["length"] * 0.03)
            bow_k = 0.12
        n = leg["segments"] + 1
        bow = up * (leg["length"] * bow_k)
        pts = []
        for i in range(n):
            f = i / (n - 1)
            noise = wobble(t, leg["phase"] + (i + 1) * 1.9, leg["freq"]) * (leg["length"] * shake)
            pts.append(root.lerp(foot, f) + (bow + noise) * math.sin(f * math.pi))
        solve_chain(pts, leg["lengths"], root, foot, 3)
        chains.append((leg, pts))
    return chains


def catmull_rom(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5


def limb_radius(f, leg):
    r = leg["width"] * (1 - 0.9 * f ** 1.3)
    for k in range(1, leg["segments"]):
        d = (f - k / leg["segments"]) / 0.035
        r += leg["width"] * 0.12 * math.exp(-d * d)
    return r


def limb_color(f, leg):
    k = f ** 3
    return tuple((FLESH[i] + (BONE[i] - FLESH[i]) * k) * leg["shade"] for i in range(3))


def linear(c):
    return tuple(min(1, max(0, v / 255)) ** 2.2 for v in c) + (1,)


def tube(chain, leg):
    n = len(chain)
    samples = []
    for i in range(n - 1):
        p0, p1, p2, p3 = chain[max(i - 1, 0)], chain[i], chain[i + 1], chain[min(i + 2, n - 1)]
        for s in range(SUB):
            t = s / SUB
            samples.append((catmull_rom(p0, p1, p2, p3, t), (i + t) / (n - 1)))
    samples.append((chain[-1], 1.0))

    verts, cols, faces = [], [], []
    normal = None
    count = len(samples)
    for j, (p, f) in enumerate(samples):
        a, b = samples[max(j - 1, 0)][0], samples[min(j + 1, count - 1)][0]
        tan = b - a
        tan = tan.normalized() if tan.length > 1e-6 else Vector((0, 0, 1))
        if normal is None:
            normal = Vector((0, 0, 1)) if abs(tan.z) < 0.9 else Vector((1, 0, 0))
        normal = normal - tan * normal.dot(tan)
        if normal.length < 1e-6:
            normal = tan.orthogonal()
        normal.normalize()
        binormal = tan.cross(normal)
        r = max(limb_radius(f, leg), 0.05)
        col = linear(limb_color(f, leg))
        for k in range(SIDES):
            ang = k / SIDES * math.pi * 2
            verts.append((p + (normal * math.cos(ang) + binormal * math.sin(ang)) * r) * SCALE)
            cols.append(col)
    for j in range(count - 1):
        for k in range(SIDES):
            k2 = (k + 1) % SIDES
            faces.append((j * SIDES + k, j * SIDES + k2, (j + 1) * SIDES + k2, (j + 1) * SIDES + k))
    for end, ring, sign in ((0, 0, -1), (count - 1, (count - 1) * SIDES, 1)):
        p = samples[end][0]
        q = samples[end - sign][0] if 0 <= end - sign < count else p
        tip = p + (p - q).normalized() * (limb_radius(samples[end][1], leg) * 0.8)
        verts.append(tip * SCALE)
        cols.append(cols[ring])
        c = len(verts) - 1
        for k in range(SIDES):
            k2 = (k + 1) % SIDES
            faces.append((ring + k2, ring + k, c) if sign < 0 else (ring + k, ring + k2, c))
    return verts, faces, cols


def material_flesh():
    m = bpy.data.materials.new("Flesh")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.42
    for name, value in (("Subsurface Weight", 0.12), ("Coat Weight", 0.35), ("Coat Roughness", 0.18)):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = value
    if "Subsurface Radius" in bsdf.inputs:
        bsdf.inputs["Subsurface Radius"].default_value = (0.6, 0.12, 0.08)
    if "Subsurface Scale" in bsdf.inputs:
        bsdf.inputs["Subsurface Scale"].default_value = 0.03
    return m


def add_mesh(name, verts, faces, cols=None, smooth=True, material=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    if cols is not None:
        attr = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
        for i, c in enumerate(cols):
            attr.data[i].color = c
    if smooth:
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    if material:
        me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def light(kind, at, look, energy, color=(1, 1, 1), size=0.5, spot=None):
    data = bpy.data.lights.new(kind + "Light", kind)
    data.energy = energy
    data.color = color
    if kind == "AREA":
        data.size = size
    elif kind == "SPOT":
        data.spot_size = math.radians(spot or 50)
        data.spot_blend = 0.6
        data.shadow_soft_size = size
    else:
        data.shadow_soft_size = size
    ob = bpy.data.objects.new(kind + "Light", data)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(at) * SCALE
    ob.rotation_euler = (Vector(look) * SCALE - ob.location).to_track_quat("-Z", "Y").to_euler()
    return ob


def stage(map_dir):
    with open(os.path.join(map_dir, "scene.json")) as f:
        info = json.load(f)
    bpy.ops.wm.obj_import(filepath=os.path.join(map_dir, "map.obj"), forward_axis="Y", up_axis="Z")
    for ob in bpy.context.selected_objects:
        for slot in ob.material_slots:
            fix_material(slot.material, info["materials"].get(slot.material.name.lower(), {}))

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = SKY_COLOR
    bg.inputs["Strength"].default_value = SKY
    bpy.context.scene.world = world

    for l in info["lights"]:
        color = l["color"]
        if l["kind"] == "light_environment":
            d = Vector(l["direction"])
            if d.z > 0:
                d = -d
            data = bpy.data.lights.new("Sun", "SUN")
            data.energy = SUN * l["brightness"] / 255
            data.angle = math.radians(1.5)
            ob = bpy.data.objects.new("Sun", data)
            ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        else:
            spot = l["kind"] == "light_spot"
            data = bpy.data.lights.new("MapLight", "SPOT" if spot else "POINT")
            data.energy = LAMP * l["brightness"]
            data.shadow_soft_size = 0.15
            if spot:
                data.spot_size = math.radians(min(175, l["outer"] * 2))
                data.spot_blend = max(0, min(1, 1 - l["inner"] / max(1, l["outer"])))
            ob = bpy.data.objects.new("MapLight", data)
            ob.location = l["origin"]
            if spot:
                ob.rotation_euler = Vector(l["direction"]).to_track_quat("-Z", "Y").to_euler()
        data.color = color
        bpy.context.scene.collection.objects.link(ob)


def fix_material(m, info):
    if not m or not m.use_nodes:
        return
    nt = m.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        return
    bsdf.inputs["Roughness"].default_value = 0.85
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.25
    image = next((n for n in nt.nodes if n.type == "TEX_IMAGE"), None)
    if image and (info.get("translucent") or info.get("alphatest")):
        nt.links.new(image.outputs["Alpha"], bsdf.inputs["Alpha"])
    if info.get("water"):
        bsdf.inputs["Base Color"].default_value = (0.02, 0.04, 0.05, 1)
        bsdf.inputs["Roughness"].default_value = 0.05
    if not image and "glass" in m.name.lower():
        bsdf.inputs["Transmission Weight"].default_value = 1
        bsdf.inputs["Roughness"].default_value = 0.05


def surface_at(point, toward):
    deps = bpy.context.evaluated_depsgraph_get()
    hit, loc, normal, *_ = bpy.context.scene.ray_cast(deps, Vector(point) * SCALE, Vector(toward).normalized())
    if not hit:
        raise RuntimeError("nothing to cling to from %s" % (point,))
    return loc / SCALE, normal


def material_white():
    m = bpy.data.materials.new("White")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    glow = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(glow.outputs["Emission"], nt.nodes["Material Output"].inputs["Surface"])
    return m


def build(shot, seed, t, map_dir):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    creature = grow(seed)
    h = creature["height"]

    if shot.get("silhouette"):
        origin, up = Vector(), Vector((0, 0, 1))
    else:
        stage(map_dir)
        origin, up = surface_at(shot["at"], shot["toward"])
    yaw = math.radians(shot.get("yaw", 0))
    fwd = Vector((math.cos(yaw), math.sin(yaw), 0))
    if "cam_world" in shot:
        fwd = Vector(shot["cam_world"]) - origin
    fwd = (fwd - up * fwd.dot(up))
    if fwd.length < 1e-3:
        fwd = up.orthogonal()
    fwd.normalize()
    left = up.cross(fwd)
    frame = lambda v: origin + fwd * (v[0] * h) + left * (v[1] * h) + up * (v[2] * h)

    cam_pos = Vector(shot["cam_world"]) if "cam_world" in shot else frame(shot["cam"])
    feel = cam_pos if shot.get("rear") else None
    lead = fwd * (shot.get("lead", 0) * h)
    flesh = material_white() if shot.get("silhouette") else material_flesh()
    for i, (leg, chain) in enumerate(pose(creature, up, fwd, t, feel, origin, lead)):
        v, f, c = tube(chain, leg)
        add_mesh("Leg%d" % i, v, f, c, material=flesh)

    for kind, at, energy, color, size in shot.get("fill", ()):
        light(kind, frame(at), origin + up * h, energy, color, size=size)

    if "flashlight" in shot:
        energy, cone = shot["flashlight"]
        body = origin + up * h
        light("SPOT", cam_pos + (body - cam_pos).normalized() * 12, body, energy, (1.0, 0.93, 0.8), size=0.05, spot=cone)

    cam_data = bpy.data.cameras.new("Camera")
    if "ortho" in shot:
        cam_data.type = "ORTHO"
        cam_data.ortho_scale = shot["ortho"]
    else:
        cam_data.lens = shot["lens"]
    cam = bpy.data.objects.new("Camera", cam_data)
    scene.collection.objects.link(cam)
    cam.location = cam_pos * SCALE
    target = frame(shot["look"]) + up * h
    aim = (target * SCALE - cam.location).to_track_quat("-Z", "Y")
    aim = aim @ Quaternion((0, 0, 1), math.radians(shot.get("roll", 0)))
    cam.rotation_euler = aim.to_euler()
    if "fstop" in shot:
        cam_data.dof.use_dof = True
        cam_data.dof.focus_distance = (target - cam_pos).length * SCALE
        cam_data.dof.aperture_fstop = shot["fstop"]
    scene.camera = cam
    return scene


PERCENT = 100


def render(scene, shot, samples, path):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = shot["size"]
    scene.render.resolution_percentage = PERCENT
    scene.render.film_transparent = bool(shot.get("silhouette"))
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    try:
        if shot.get("silhouette"):
            scene.view_settings.view_transform = "Standard"
        else:
            scene.view_settings.view_transform = "AgX"
            scene.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    scene.view_settings.exposure = shot.get("exposure", 0)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = dict(zip(argv[::2], argv[1::2]))
    out = args.get("--out", "//renders")
    shots = args["--shots"].split(",") if "--shots" in args else list(SHOTS)
    samples = int(args.get("--samples", 160))
    seed = int(args.get("--seed", SEED))
    global PERCENT
    PERCENT = int(args.get("--pct", 100))
    t = float(args.get("--t", 11.0))
    for name in shots:
        shot = SHOTS[name]
        scene = build(shot, seed, t, args.get("--map"))
        render(scene, shot, samples, "%s/%s.png" % (out.rstrip("/\\"), name))


if __name__ == "__main__":
    main()
