extends Node3D
## Bonnezeaux — first Godot prototype: sail a little boat around some islands.
## The whole scene (water, boat, islands, camera, light) is built in code so the
## project stays easy to edit by hand. Replace/extend freely.

# --- Boat physics tunables -------------------------------------------------
const MAX_SPEED := 36.0
const ACCEL := 26.0
const DRAG := 1.3
const TURN := 2.8            # rad/s at full speed
const CAM_OFFSET := Vector3(40, 50, -40)

# --- Wind / sailing tunables ----------------------------------------------
const WIND_ACCEL := 48.0     # how hard a well-trimmed sail pushes the boat
const WIND_DRIFT := 1.1      # rad/s random walk of the wind direction (gusty/shifty)
const WIND_SHIFT_CHANCE := 0.8   # per-second chance the wind picks a new strength
const WIND_STRENGTH_MIN := 0.65
const WIND_STRENGTH_MAX := 1.0
const WIND_SPEED_SCALE := 20.0   # true wind speed in boat-speed units (for apparent wind)
const NO_GO := deg_to_rad(43.0)  # can't sail closer than this to the wind
const SHEET_SPEED := 1.6     # rad/s the player can sheet the sail in/out (Q/E)
const SHEET_MAX := PI / 2.0  # fully eased = sail 90° out

var heading := 0.0           # radians, 0 = +Z
var speed := 0.0
var elapsed := 0.0

var wind_dir := 0.0          # radians, direction the wind blows TOWARD
var wind_strength := 0.8
var wind_strength_target := 0.8
var sail_sheet := 0.5        # how far the sail is eased out, 0 (in tight) .. SHEET_MAX
var sail_angle := 0.0        # actual visual sail angle (sheet, on the leeward side)
var efficiency := 0.0        # how well the sail is drawing, 0..1 (for HUD/tint)
var awa := 0.0               # apparent wind angle off the bow, 0 = dead upwind

var boat: Node3D
var sail_node: MeshInstance3D
var sail_mat: StandardMaterial3D
var wind_arrow: Node3D
var water: MeshInstance3D
var water_mat: ShaderMaterial
var cam: Camera3D
var status_label: Label

# islands as {pos: Vector3, radius: float} for simple collision
var islands: Array = []

# touch steering (mobile): -1 / 0 / +1, and auto-sail while touching
var touch_steer := 0.0
var touching := false


func _ready() -> void:
	_build_environment()
	_build_water()
	_make_island(Vector3(18, 0, -22), 7.0)
	_make_island(Vector3(-30, 0, 10), 10.0)
	_make_island(Vector3(40, 0, 35), 6.0)
	_make_island(Vector3(-10, 0, 55), 8.0)
	_make_island(Vector3(60, 0, -40), 9.0)
	_build_boat()
	_build_wind_arrow()
	_build_camera()
	_build_hud()
	wind_dir = randf() * TAU


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.83, 0.91)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.82, 0.95)
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.83, 0.91)
	env.fog_density = 0.006
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.3
	sun.rotation_degrees = Vector3(-55, -35, 0)
	add_child(sun)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	plane.subdivide_width = 80
	plane.subdivide_depth = 80

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_back, diffuse_lambert;

uniform float time;
uniform vec3 deep : source_color = vec3(0.10, 0.33, 0.52);
uniform vec3 shallow : source_color = vec3(0.27, 0.62, 0.72);

void vertex() {
	float w = sin(VERTEX.x * 0.08 + time * 1.3) * 0.8
			+ cos(VERTEX.z * 0.10 + time * 1.1) * 0.7;
	VERTEX.y += w;
}

void fragment() {
	float h = clamp(VERTEX.y * 0.35 + 0.5, 0.0, 1.0);
	ALBEDO = mix(deep, shallow, h);
	ROUGHNESS = 0.5;
	METALLIC = 0.0;
}
"""
	water_mat = ShaderMaterial.new()
	water_mat.shader = shader

	water = MeshInstance3D.new()
	water.mesh = plane
	water.material_override = water_mat
	add_child(water)


func _solid_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


func _make_island(pos: Vector3, r: float) -> void:
	var g := Node3D.new()
	g.position = pos

	# sandy base (a low chunky cylinder poking above the water)
	var sand_mesh := CylinderMesh.new()
	sand_mesh.top_radius = r
	sand_mesh.bottom_radius = r * 1.25
	sand_mesh.height = 3.0
	sand_mesh.radial_segments = 7
	var sand := MeshInstance3D.new()
	sand.mesh = sand_mesh
	sand.material_override = _solid_mat(Color(0.90, 0.82, 0.60))
	sand.position.y = 1.0
	g.add_child(sand)

	# grassy hill (cone = cylinder with zero top radius)
	var hill_mesh := CylinderMesh.new()
	hill_mesh.top_radius = 0.0
	hill_mesh.bottom_radius = r * 0.8
	hill_mesh.height = r * 0.7
	hill_mesh.radial_segments = 7
	var hill := MeshInstance3D.new()
	hill.mesh = hill_mesh
	hill.material_override = _solid_mat(Color(0.37, 0.68, 0.33))
	hill.position.y = 2.5 + r * 0.35
	g.add_child(hill)

	# a few palm-ish trees
	var n_trees := 2 + (randi() % 3)
	for i in n_trees:
		var a := randf() * TAU
		var rr := randf() * r * 0.5
		var tx := cos(a) * rr
		var tz := sin(a) * rr

		var trunk_mesh := CylinderMesh.new()
		trunk_mesh.top_radius = 0.18
		trunk_mesh.bottom_radius = 0.28
		trunk_mesh.height = 3.2
		trunk_mesh.radial_segments = 5
		var trunk := MeshInstance3D.new()
		trunk.mesh = trunk_mesh
		trunk.material_override = _solid_mat(Color(0.48, 0.32, 0.19))
		trunk.position = Vector3(tx, 4.1, tz)
		g.add_child(trunk)

		var leaf_mesh := CylinderMesh.new()
		leaf_mesh.top_radius = 0.0
		leaf_mesh.bottom_radius = 1.3
		leaf_mesh.height = 1.6
		leaf_mesh.radial_segments = 6
		var leaves := MeshInstance3D.new()
		leaves.mesh = leaf_mesh
		leaves.material_override = _solid_mat(Color(0.25, 0.56, 0.28))
		leaves.position = Vector3(tx, 6.0, tz)
		g.add_child(leaves)

	add_child(g)
	islands.append({"pos": pos, "radius": r * 1.25})


func _build_boat() -> void:
	boat = Node3D.new()

	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(1.6, 0.7, 3.4)
	var hull := MeshInstance3D.new()
	hull.mesh = hull_mesh
	hull.material_override = _solid_mat(Color(0.54, 0.35, 0.17))
	hull.position.y = 0.45
	boat.add_child(hull)

	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(1.4, 0.2, 3.0)
	var deck := MeshInstance3D.new()
	deck.mesh = deck_mesh
	deck.material_override = _solid_mat(Color(0.73, 0.54, 0.31))
	deck.position.y = 0.85
	boat.add_child(deck)

	var mast_mesh := CylinderMesh.new()
	mast_mesh.top_radius = 0.08
	mast_mesh.bottom_radius = 0.1
	mast_mesh.height = 3.2
	mast_mesh.radial_segments = 5
	var mast := MeshInstance3D.new()
	mast.mesh = mast_mesh
	mast.material_override = _solid_mat(Color(0.35, 0.24, 0.13))
	mast.position = Vector3(0, 2.4, 0.1)
	boat.add_child(mast)

	# The sail is a thin plane that pivots around the mast. We rotate this node
	# with Q/E to trim it, and tint it green/red to show how well it catches wind.
	var sail_mesh := BoxMesh.new()
	sail_mesh.size = Vector3(0.06, 2.2, 1.6)
	sail_mat = _solid_mat(Color(0.95, 0.94, 0.88))
	sail_node = MeshInstance3D.new()
	sail_node.mesh = sail_mesh
	sail_node.material_override = sail_mat
	sail_node.position = Vector3(0, 2.4, 0.1)
	boat.add_child(sail_node)

	add_child(boat)


func _build_wind_arrow() -> void:
	# Floating arrow above the boat that points the way the wind is blowing.
	wind_arrow = Node3D.new()
	var arrow_mat := _solid_mat(Color(0.2, 0.85, 1.0))

	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.25, 0.25, 2.6)
	var shaft := MeshInstance3D.new()
	shaft.mesh = shaft_mesh
	shaft.material_override = arrow_mat
	wind_arrow.add_child(shaft)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.7
	head_mesh.height = 1.2
	head_mesh.radial_segments = 6
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.material_override = arrow_mat
	head.rotation_degrees = Vector3(90, 0, 0)  # point the cone along +Z
	head.position = Vector3(0, 0, 1.8)
	wind_arrow.add_child(head)

	add_child(wind_arrow)


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 60.0
	cam.far = 1000.0
	add_child(cam)
	cam.make_current()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = "W/S throttle · A/D steer · Q/E trim sail    |    mobile: tap left / right to steer"
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	label.position.y = -34
	layer.add_child(label)

	# live wind / sail readout, top-left
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color.WHITE)
	status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	status_label.add_theme_constant_override("shadow_offset_y", 1)
	status_label.position = Vector2(14, 10)
	layer.add_child(status_label)

	add_child(layer)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		touching = event.pressed
		if event.pressed:
			_set_touch_from(event.position.x)
		else:
			touch_steer = 0.0
	elif event is InputEventScreenDrag:
		_set_touch_from(event.position.x)


func _set_touch_from(x: float) -> void:
	var half := get_viewport().get_visible_rect().size.x * 0.5
	touch_steer = 1.0 if x < half else -1.0


func _process(delta: float) -> void:
	elapsed += delta
	var t := elapsed

	# --- input ---
	var throttle := 0.0
	if touching:
		throttle = 1.0  # auto-sail forward on mobile
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		throttle += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		throttle -= 1.0

	var steer := touch_steer
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		steer += 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		steer -= 1.0
	steer = clampf(steer, -1.0, 1.0)

	# sheet the sail with Q / E (Q eases out, E sheets in tight)
	var sheet := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		sheet += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		sheet -= 1.0
	sail_sheet = clampf(sail_sheet + sheet * SHEET_SPEED * delta, 0.0, SHEET_MAX)

	# --- wind: gusty, shifty true wind ---
	wind_dir = wrapf(wind_dir + randf_range(-1.0, 1.0) * WIND_DRIFT * delta, 0.0, TAU)
	if randf() < delta * WIND_SHIFT_CHANCE:
		wind_strength_target = randf_range(WIND_STRENGTH_MIN, WIND_STRENGTH_MAX)
	wind_strength = lerpf(wind_strength, wind_strength_target, delta * 0.8)

	# Apparent wind = true wind minus the boat's own motion. This is what the
	# sail actually feels, and it shifts forward as the boat speeds up.
	var forward := Vector2(sin(heading), cos(heading))
	var true_wind := Vector2(sin(wind_dir), cos(wind_dir)) * (wind_strength * WIND_SPEED_SCALE)
	var app_wind := true_wind - forward * speed   # vector the wind blows TOWARD, boat frame
	var app_from := -app_wind                     # points back to where it comes from
	var app_speed := app_wind.length()

	# Angle between the bow and where the wind comes from. 0 = dead upwind.
	awa = absf(forward.angle_to(app_from)) if app_from.length() > 0.01 else 0.0

	# Point of sail: nothing in the no-go zone, ramps up to a fast beam reach,
	# eases off a little dead downwind (running on drag alone is slower).
	var pos_power := 0.0
	if awa > NO_GO:
		var ramp := clampf((awa - NO_GO) / deg_to_rad(27.0), 0.0, 1.0)
		var run_falloff := 1.0 - 0.30 * clampf((awa - deg_to_rad(120.0)) / deg_to_rad(60.0), 0.0, 1.0)
		pos_power = ramp * run_falloff

	# Correct sheet for this point of sail: in tight upwind, eased out downwind.
	var optimal_sheet := clampf((awa - NO_GO) * 0.62, 0.0, SHEET_MAX)
	var trim_quality := clampf(1.0 - absf(sail_sheet - optimal_sheet) / deg_to_rad(45.0), 0.0, 1.0)

	var app_norm := clampf(app_speed / WIND_SPEED_SCALE, 0.0, 1.6)
	var sail_drive := pos_power * trim_quality * app_norm
	efficiency = clampf(pos_power * trim_quality, 0.0, 1.0)

	# show the sail eased to the leeward side, by the sheeted amount
	var lee := signf(forward.angle_to(app_from))
	sail_angle = sail_sheet * (lee if lee != 0.0 else 1.0)

	# tint the sail: pale = luffing/badly trimmed, green = drawing well
	sail_mat.albedo_color = Color(0.95, 0.94, 0.88).lerp(Color(0.3, 1.0, 0.4), efficiency)

	# --- physics ---
	speed += (throttle * ACCEL + sail_drive * WIND_ACCEL) * delta
	speed -= speed * DRAG * delta
	speed = clampf(speed, -MAX_SPEED * 0.4, MAX_SPEED)

	# need some speed before the rudder bites
	var steer_scale := minf(1.0, absf(speed) / 3.0)
	heading += steer * TURN * delta * steer_scale * signf(speed if speed != 0.0 else 1.0)

	var nx := boat.position.x + sin(heading) * speed * delta
	var nz := boat.position.z + cos(heading) * speed * delta

	# island collision: bonk and bounce back a little
	var blocked := false
	for isl in islands:
		var dx: float = nx - isl.pos.x
		var dz: float = nz - isl.pos.z
		var rr: float = isl.radius + 1.5
		if dx * dx + dz * dz < rr * rr:
			blocked = true
			break
	if blocked:
		speed = -speed * 0.3
	else:
		boat.position.x = nx
		boat.position.z = nz

	# orient + bob on the waves
	boat.rotation.y = heading
	boat.position.y = sin(t * 1.5) * 0.25
	boat.rotation.z = sin(t * 1.2) * 0.04
	boat.rotation.x = sin(t * 0.9) * 0.03
	sail_node.rotation.y = sail_angle

	# wind arrow floats above the boat, pointing where the wind blows
	wind_arrow.position = boat.position + Vector3(0, 9, 0)
	wind_arrow.rotation.y = wind_dir

	# water + camera follow the boat so the sea feels endless
	water.position.x = boat.position.x
	water.position.z = boat.position.z
	water_mat.set_shader_parameter("time", t)

	cam.position = boat.position + CAM_OFFSET
	cam.look_at(boat.position, Vector3.UP)

	var awa_deg := rad_to_deg(awa)
	var pos_name := "running"
	if awa_deg <= rad_to_deg(NO_GO):
		pos_name = "IN IRONS (no-go — tack!)"
	elif awa_deg < 60.0:
		pos_name = "close-hauled"
	elif awa_deg < 100.0:
		pos_name = "beam reach"
	elif awa_deg < 150.0:
		pos_name = "broad reach"
	status_label.text = "wind %d°  strength %.2f\npoint of sail: %s  (%d° off bow)\ncatching %d%%" % [
		int(rad_to_deg(wind_dir)) % 360,
		wind_strength,
		pos_name,
		int(awa_deg),
		int(efficiency * 100.0),
	]
