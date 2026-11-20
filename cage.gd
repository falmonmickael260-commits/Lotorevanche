extends SubViewportContainer

const BRASS := Color("#ffbf56")
const DARK_BRASS := Color("#cb5680")
const IVORY := Color("#fff1b9")
const REST_SPEED := 0.48

var drum: Node3D
var stage: Node3D
var prize_ball: MeshInstance3D
var ball_number: Label3D
var lamp: OmniLight3D
var flight: Tween
var sound: AudioStreamPlayer
var speed := REST_SPEED
var inner_balls: Array[MeshInstance3D] = []
var tick := 0.0

func _ready() -> void:
	var view := SubViewport.new()
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(view)
	stage = Node3D.new()
	view.add_child(stage)
	setup_lighting()
	build_machine()
	build_ball()
	sound = AudioStreamPlayer.new()
	sound.volume_db = -8
	add_child(sound)
	sound.stream = make_chime()

func setup_lighting() -> void:
	var camera := Camera3D.new()
	camera.fov = 36.0
	stage.add_child(camera)
	camera.position = Vector3(3.0, 2.0, 7.9)
	camera.look_at(Vector3(0.38, 0.04, 0))
	for spec in [[Vector3(-2, 4, 4), Color("#ffdcac"), 2.8],
		[Vector3(4, 2, -2), Color("#b980ff"), 2.7]]:
		var light := OmniLight3D.new()
		light.position = spec[0]
		light.light_color = spec[1]
		light.light_energy = spec[2]
		light.omni_range = 12.0
		stage.add_child(light)
	lamp = OmniLight3D.new()
	lamp.position = Vector3(0.7, 1.2, 2.4)
	lamp.light_color = Color("#ffd69a")
	lamp.light_energy = 0.0
	lamp.omni_range = 6.0
	stage.add_child(lamp)

func build_machine() -> void:
	var podium := CylinderMesh.new()
	podium.top_radius = 1.58
	podium.bottom_radius = 1.72
	podium.height = 0.21
	surface(stage, podium, Color("#623cbd"), Vector3(0.08, -1.02, 0), 0.45)
	var trim := TorusMesh.new()
	trim.inner_radius = 1.47
	trim.outer_radius = 1.53
	surface(stage, trim, BRASS, Vector3(0.08, -0.91, 0), 0.52)
	rod(stage, Vector3(-1.02, -0.91, 0.2), Vector3(-1.02, 0.03, 0), 0.104, DARK_BRASS)
	rod(stage, Vector3(1.02, -0.91, 0.2), Vector3(1.02, 0.03, 0), 0.104, DARK_BRASS)
	rod(stage, Vector3(-1.14, 0, 0), Vector3(1.18, 0, 0), 0.075, BRASS)

	drum = Node3D.new()
	stage.add_child(drum)
	var flange := TorusMesh.new()
	flange.inner_radius = 0.74
	flange.outer_radius = 0.82
	flange.rings = 32
	flange.ring_segments = 12
	for x in [-0.81, -0.58, 0.58, 0.81]:
		var ring := surface(drum, flange, BRASS, Vector3(x, 0, 0), 0.62)
		ring.rotation.z = PI / 2.0
	for index in range(15):
		var angle := TAU * index / 15.0
		var rim := Vector3(0, 0.77 * cos(angle), 0.77 * sin(angle))
		rod(drum, rim + Vector3.LEFT * 0.81, rim + Vector3.RIGHT * 0.81, 0.021, BRASS)
		if index % 3 == 0:
			for x in [-0.81, 0.81]:
				var hub := Vector3(x, 0.0, 0.0)
				rod(drum, hub, hub + rim, 0.028, DARK_BRASS)
	rod(drum, Vector3(1.14, 0, 0), Vector3(1.14, 0.28, 0), 0.037, BRASS)
	rod(drum, Vector3(1.14, 0.28, 0), Vector3(1.40, 0.28, 0), 0.047, DARK_BRASS)

	var marble := SphereMesh.new()
	marble.radius = 0.112
	marble.height = 0.224
	marble.radial_segments = 16
	marble.rings = 8
	var colors := [IVORY, Color("#fc5f9a"), Color("#56e4e1"), Color("#ffdc54")]
	for index in range(18):
		inner_balls.append(surface(drum, marble, colors[index % colors.size()], Vector3.ZERO))

	var slide := BoxMesh.new()
	slide.size = Vector3(0.29, 0.06, 0.90)
	var track := surface(stage, slide, DARK_BRASS, Vector3(0.73, -0.57, 0.64), 0.45)
	track.rotation.x = 0.32
	for x in [0.55, 0.90]:
		rod(stage, Vector3(x, -0.35, 0.14), Vector3(x, -0.66, 1.18), 0.032, BRASS)

func build_ball() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.28
	mesh.height = 0.56
	prize_ball = surface(stage, mesh, IVORY, Vector3.ZERO)
	ball_number = Label3D.new()
	ball_number.font_size = 72
	ball_number.pixel_size = 0.0038
	ball_number.outline_size = 0
	ball_number.modulate = Color("#253020")
	ball_number.no_depth_test = true
	ball_number.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	ball_number.position = Vector3(0.065, 0.03, 0.14)
	prize_ball.add_child(ball_number)
	prize_ball.hide()

func rod(parent: Node3D, start: Vector3, finish: Vector3, radius: float, metal_color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = start.distance_to(finish)
	mesh.radial_segments = 10
	var axis := (finish - start).normalized()
	var part := surface(parent, mesh, metal_color, start.lerp(finish, 0.5), 0.55)
	part.quaternion = Quaternion(Vector3.UP, axis)

func surface(parent: Node3D, mesh: Mesh, color: Color, at: Vector3, metal := 0.08) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.68
	material.metallic = metal * 0.2
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.25
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	tick += delta
	drum.rotate_x(delta * speed)
	speed = move_toward(speed, REST_SPEED, delta * 3.3)
	for index in range(inner_balls.size()):
		var angle := index * 2.399963 + tick * (0.50 + speed * 0.13)
		var radius := 0.20 + 0.32 * absf(sin(tick * 0.67 + index))
		inner_balls[index].position = Vector3(
			0.63 * sin(index * 1.43 + tick * 0.8), radius * cos(angle), radius * sin(angle))

func reset_stage() -> void:
	if flight:
		flight.kill()
	prize_ball.hide()
	lamp.light_energy = 0.0
	speed = REST_SPEED

func reveal(number: int) -> void:
	if flight:
		flight.kill()
	speed = 7.0
	prize_ball.hide()
	prize_ball.position = Vector3(0.40, -0.15, 0.27)
	prize_ball.scale = Vector3.ONE * 0.42
	ball_number.text = str(number).pad_zeros(2)
	lamp.light_energy = 0.0
	flight = create_tween()
	flight.tween_interval(0.20)
	flight.tween_callback(prize_ball.show)
	flight.tween_property(prize_ball, "position", Vector3(0.70, 0.20, 0.65), 0.18)
	flight.tween_property(prize_ball, "position", Vector3(1.14, -0.49, 1.30), 0.29).set_trans(Tween.TRANS_CUBIC)
	flight.parallel().tween_property(prize_ball, "scale", Vector3.ONE, 0.26)
	flight.tween_callback(sound.play)
	flight.tween_property(lamp, "light_energy", 2.4, 0.10)
	flight.tween_property(lamp, "light_energy", 0.1, 0.80)

func make_chime() -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.mix_rate = 22050
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	var samples := PackedByteArray()
	samples.resize(8820 * 2)
	for index in range(8820):
		var time := float(index) / stream.mix_rate
		var wave := sin(TAU * 740.0 * time) + 0.4 * sin(TAU * 1109.0 * time)
		var level := wave * exp(-12.0 * time) * minf(time * 180.0, 1.0) * 4200.0
		samples.encode_s16(index * 2, int(level))
	stream.data = samples
	return stream
