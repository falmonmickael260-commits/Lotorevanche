extends Control

const Wallet = preload("res://wallet.gd")
const Room = preload("res://room.gd")
const Cage = preload("res://cage.gd")
const PORT := 8071
const COVER = preload("res://assets/loto-revanche.webp")
const GOLD := Color("#ffdb66")
const MUTED := Color("#e1d8ff")
const MINT := Color("#88f4d0")

var rooms := {}
var sessions := {}
var house := 0
var room_sequence := 0
var server_mode := false
var wallet: Node
var wallet_busy := false
var wallet_queue := {}
var departing := {}
var next_sweep_at := 0
var platform_token := ""
var default_address := "ws://127.0.0.1:8071"
var current := {}
var marked := {}
var card_views := []
var card_tiles := {}
var card_render_key := ""
var synced_code := ""
var synced_cards := []
var next_draw_at := 0
var chat_open := false
var last_ball := 0
var root: VBoxContainer
var body: VBoxContainer
var chat_panel: VBoxContainer
var chat_log: RichTextLabel
var chat_input: LineEdit
var status: Label
var wallet_label: Label
var ticket_layout: BoxContainer
var entry_layout: BoxContainer
var stage_meter: ProgressBar
var buy_summary: Label
var purchase_panel: VBoxContainer
var lobby_grid: GridContainer
var stage_phase: Label
var award_key := ""
var wallet_tween: Tween
var last_balance := -1
var connection: PanelContainer
var home: VBoxContainer
var game: VBoxContainer
var cage: SubViewportContainer
var ball_label: Label
var draw_status: Label
var board_heading: Button
var recent_balls: Label
var order_button: Button
var chronological := false
var called_board: GridContainer
var called_cells: Array[Label] = []
var card_caption: Label
var buy_button: Button
var quantity: SpinBox
var buy_controls: HBoxContainer
var chat_button: Button
var dock_ball: Label
var message_count := 0
var reveal_tween: Tween
var current_ball_label := 0
var lobby_cache := []
var remembered_balance := -1
var room_header: Label
var pot_label: Label
var start_button: Button
var number_grid: GridContainer
var results: VBoxContainer
var selected_nickname := ""
var connect_button: Button
var connect_deadline := 0

func _ready() -> void:
	server_mode = "--server" in OS.get_cmdline_user_args()
	if server_mode:
		var adapter := Wallet.new()
		if adapter.configured():
			wallet = adapter
			add_child(wallet)
		else:
			adapter.free()
			if OS.get_environment("LOTO_REQUIRE_WALLET") == "1":
				push_error("Configuration du portefeuille manquante.")
				get_tree().quit(1)
				return
		var peer := WebSocketMultiplayerPeer.new()
		var port := OS.get_environment("PORT").to_int()
		var bind := OS.get_environment("LOTO_BIND")
		var error := peer.create_server(port if port > 0 else PORT, bind if not bind.is_empty() else "*")
		if error != OK:
			push_error("Impossible d’ouvrir le serveur : %s" % error_string(error))
			get_tree().quit(1)
			return
		multiplayer.multiplayer_peer = peer
		multiplayer.peer_disconnected.connect(disconnect_player)
		print("Serveur Loto Revanche prêt.")
		return
	read_web_launch()
	build_ui()
	multiplayer.connected_to_server.connect(func():
		action.rpc_id(1, "hello", {"name": selected_nickname, "token": platform_token}))
	multiplayer.connection_failed.connect(connection_lost)
	multiplayer.server_disconnected.connect(connection_lost)
	if not platform_token.is_empty():
		connect_game(default_address, "")

func _process(_delta: float) -> void:
	if not server_mode:
		if connect_deadline > 0 and Time.get_ticks_msec() >= connect_deadline:
			connection_lost()
		update_clock()
		return
	var now := Time.get_ticks_msec()
	var changed := false
	if wallet and now >= next_sweep_at:
		next_sweep_at = now + 60000
		sweep_wallet()
	for code in rooms:
		var room = rooms[code]
		if wallet and not wallet_busy and room.phase == "attente" and now >= room.wait_until:
			begin_settlement(room, true)
		if room.pending_balance and not room.wallet_job and now >= room.retry_at:
			settle_wallet(room)
			continue
		if room.phase == "partie" and not room.bag.is_empty() and now >= room.next_draw:
			room.draw()
			changed = true
		elif room.phase == "partie" and room.bag.is_empty() and now >= room.next_draw:
			if room.drawn.size() == 90 and not room.final_window:
				room.final_window = true
				room.next_draw = now + 45000
			else:
				close_unclaimed(room)
			changed = true

	if changed:
		broadcast()
	remove_finished_rooms()

func disconnect_player(id: int) -> void:
	if not sessions.has(id):
		return
	departing[id] = true
	if not wallet_busy:
		flush_departures.call_deferred()

func flush_departures() -> void:
	if wallet_busy:
		return
	wallet_busy = true
	for id in departing.keys():
		if sessions.has(id):
			if wallet and rooms.has(sessions[id].room):
				sessions[id].offline = true
			else:
				await leave_room(id, true)
				sessions.erase(id)
		departing.erase(id)
	wallet_busy = false
	broadcast()
	resume_wallet_queue()

func sweep_wallet() -> void:
	await wallet.call_api({"action": "sweep"})

func leave_room(id: int, disconnected := false) -> void:
	var session: Dictionary = sessions[id]
	var code: String = session.room
	if not rooms.has(code):
		return
	var room = rooms[code]
	if room.phase in ["partie", "règlement"] and not disconnected:
		hint.rpc_id(id, "Tu peux quitter le salon une fois le tirage terminé.")
		return
	if room.phase == "attente":
		var sold: int = room.cards[id].size()
		if wallet:
			var result: Dictionary = await wallet.call_api({
				"action": "leave", "round": room.wallet_id, "uid": session.uid,
			})
			if result.get("temporary", false):
				begin_settlement(room, true)
				if disconnected:
					session.room = ""
				else:
					hint.rpc_id(id, "Le remboursement va être vérifié avant de fermer le salon.")
				return
			if not result.get("ok", false) and not disconnected:
				hint.rpc_id(id, result.error)
				return
			session.balance = int(result.get("balance", session.balance))
		else:
			session.balance += room.price * sold
		room.tickets -= sold
		room.players.erase(id)
		room.cards.erase(id)
		room.accounts.erase(id)
		if not room.players.is_empty() and room.host == id:
			room.host = room.players.keys()[0]
	session.room = ""
	if room.phase == "attente" and room.players.is_empty():
		rooms.erase(code)

func pay(room, id: int, ticket: int, line: int) -> void:
	var stage: int = room.awards.size()
	var gain: int = room.award(id, ticket, line)
	if wallet:
		room.winning_accounts[stage] = room.accounts[id]
		if room.phase == "terminée":
			begin_settlement(room)
		return
	if sessions.has(id) and rooms.get(sessions[id].room) == room:
		sessions[id].balance += gain
	if room.phase == "terminée":
		house += room.price * room.tickets - room.prizes().reduce(func(a, b): return a + b, 0)

@rpc("any_peer", "call_remote", "reliable")
func action(kind: String, value: Variant = null) -> void:
	if not server_mode:
		return
	var id := multiplayer.get_remote_sender_id()
	if kind == "hello":
		await hello(id, value)
		return
	if not sessions.has(id):
		return
	var session: Dictionary = sessions[id]
	var code: String = session.room
	var room = rooms.get(code)
	if wallet and kind in ["create", "join", "buy", "leave", "start"]:
		wallet_action(id, kind, value)
		return
	match kind:
		"create":
			if code != "" or not (value is int) or value not in Room.PRICES:
				return
			if session.balance < value:
				hint.rpc_id(id, "Ton solde est insuffisant.")
				return
			room_sequence += 1
			code = str(room_sequence).pad_zeros(4)
			rooms[code] = Room.new(id, int(value))
			enter_room(id, code)
		"join":
			if code != "" or not (value is String) or not rooms.has(value):
				return
			var target = rooms[value]
			if target.phase != "attente" or target.players.size() >= 40:
				hint.rpc_id(id, "Ce salon n’accepte plus de joueurs.")
				return
			if session.balance < target.price:
				hint.rpc_id(id, "Ton solde est insuffisant.")
				return
			enter_room(id, value)
		"buy":
			if room == null or room.phase != "attente":
				return
			if not (value is int) or value < 1 or value > session.balance / float(room.price):
				hint.rpc_id(id, "Ton solde est insuffisant.")
				return
			for _ticket in range(value):
				enter_room(id, code)
		"leave":
			leave_room(id)
		"start":
			if room == null or room.host != id or room.phase != "attente":
				return
			if room.players.size() < 2:
				hint.rpc_id(id, "Il faut au moins deux joueurs pour lancer le tirage.")
				return
			room.start()
		"mark":
			if room == null or not (value is Dictionary):
				return
			if not (value.get("ticket") is int) or not (value.get("number") is int):
				return
			if room.mark_number(id, value.ticket, value.number):
				broadcast(id)
			return
		"claim":
			if room == null or not (value is Dictionary):
				return
			if value.get("stage") != room.awards.size():
				return
			var ticket: Variant = value.get("ticket")
			if not (ticket is int):
				return
			var line: int = room.eligible(id, ticket, room.marks.get(Vector2i(id, ticket), []))
			if line < 0:
				hint.rpc_id(id, "Vérifie que tous les numéros nécessaires sont tirés et cochés.")
				return
			pay(room, id, ticket, line)
		"chat":
			if room == null or not (value is String):
				return
			var now := Time.get_ticks_msec()
			var message: String = value.strip_edges().replace("\n", " ").left(240)
			if message.is_empty() or now - session.last_chat < 850:
				return
			session.last_chat = now
			room.add_chat("%s · %s" % [session.name, message])
		_:
			return
	broadcast()
	remove_finished_rooms()

func close_unclaimed(room) -> void:
	if wallet:
		begin_settlement(room)
		return
	# Refund the shares of prizes that were never claimed; honor prizes already credited.
	var remaining := 0
	var prizes: Array = room.prizes()
	for stage in range(room.awards.size(), prizes.size()):
		remaining += prizes[stage]
	var refund := floori(float(remaining) / room.tickets)
	house += room.price * room.tickets - prizes.reduce(func(a, b): return a + b, 0)
	var remainder: int = remaining - refund * room.tickets
	for id in room.cards:
		var count: int = room.cards[id].size()
		var extra := mini(remainder, count)
		remainder -= extra
		if sessions.has(id) and rooms.get(sessions[id].room) == room:
			sessions[id].balance += refund * count + extra
	room.phase = "terminée"
	room.add_chat("Fin du tirage · Les lots non réclamés sont reversés aux cartons.")

func remove_finished_rooms() -> void:
	var changed := false
	for key in rooms.keys():
		var room = rooms[key]
		if room.phase == "terminée" and room.retain_until == 0:
			room.retain_until = Time.get_ticks_msec() + 300000
		if room.retain_until > 0 and Time.get_ticks_msec() >= room.retain_until:
			for peer_id in sessions.keys():
				if sessions[peer_id].room == key:
					if sessions[peer_id].get("offline", false):
						sessions.erase(peer_id)
					else:
						sessions[peer_id].room = ""
			rooms.erase(key)
			changed = true
	if changed:
		broadcast()

func enter_room(id: int, code: String) -> void:
	var session: Dictionary = sessions[id]
	var room = rooms[code]
	session.balance -= room.price
	session.room = code
	room.add_player(id, session.name)

func broadcast(only_peer := 0) -> void:
	var lobby := []
	for code in rooms:
		var room = rooms[code]
		if room.phase == "attente":
			lobby.append({"code": code, "host": room.players[room.host], "price": room.price,
				"count": room.players.size(), "tickets": room.tickets, "prizes": room.prizes()})
	var peer := multiplayer.multiplayer_peer as WebSocketMultiplayerPeer
	var connected := multiplayer.get_peers()
	for id in sessions:
		if only_peer != 0 and id != only_peer:
			continue
		if sessions[id].get("offline", false) or departing.has(id) or id not in connected or peer.get_peer(id).get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		var session: Dictionary = sessions[id]
		var snapshot := {"balance": session.balance, "lobby": lobby, "code": session.room, "test_mode": wallet == null, "nickname": session.name}
		if rooms.has(session.room):
			var room = rooms[session.room]
			var tickets: Array = room.cards[id]
			var offset: int = session.get("sent_count", 0) if session.get("sent_code", "") == session.room else 0
			while offset < tickets.size():
				var finish := mini(tickets.size(), offset + 24)
				sync_cards.rpc_id(id, session.room, offset, tickets.slice(offset, finish))
				offset = finish
			session.sent_count = offset
			session.sent_code = session.room
			snapshot.merge({"drawn": room.drawn, "phase": room.phase,
				"tickets": room.tickets, "remaining": room.next_draw - Time.get_ticks_msec(),
				"final_window": room.final_window, "used_lines": room.used_lines(id), "marks": room.player_marks(id),
				"count": room.players.size(), "host": room.host == id, "price": room.price,
				"awards": room.awards, "prizes": room.prizes(), "chat": room.chat})
		else:
			session.sent_code = ""
			session.sent_count = 0
		update_view.rpc_id(id, snapshot)

@rpc("authority", "call_remote", "reliable")
func sync_cards(code: String, offset: int, batch: Array) -> void:
	if synced_code != code or offset == 0:
		synced_code = code
		synced_cards = []
	synced_cards.append_array(batch)

@rpc("authority", "call_remote", "reliable")
func hint(message: String) -> void:
	if connect_deadline > 0:
		connection_lost()
	status.text = message

@rpc("authority", "call_remote", "reliable")
func update_view(snapshot: Dictionary) -> void:
	connect_deadline = 0
	if current.get("code", "") != snapshot.code:
		if reveal_tween:
			reveal_tween.kill()
		marked.clear()
		last_ball = 0
		chat_open = false
		message_count = 0
		lobby_cache.clear()
		remembered_balance = -1
	if snapshot.code != "":
		snapshot.cards = synced_cards
		marked = snapshot.get("marks", {})
	current = snapshot
	next_draw_at = Time.get_ticks_msec() + int(snapshot.get("remaining", 0))
	status.text = snapshot.nickname
	wallet_label.text = "%s pièces%s" % [coin_amount(snapshot.balance), " de test" if snapshot.test_mode else ""]
	wallet_label.get_parent().get_parent().show()
	if last_balance >= 0 and last_balance != int(snapshot.balance):
		if wallet_tween:
			wallet_tween.kill()
		wallet_label.modulate = MINT if int(snapshot.balance) > last_balance else GOLD
		wallet_tween = create_tween()
		wallet_tween.tween_property(wallet_label, "modulate", Color.WHITE, 0.65)
	last_balance = int(snapshot.balance)
	connection.hide()
	home.visible = snapshot.code == ""
	game.visible = snapshot.code != ""
	chat_panel.visible = game.visible and chat_open
	if game.visible:
		render_game()
	else:
		render_lobby()

func connection_lost() -> void:
	connect_deadline = 0
	connect_button.disabled = false
	connect_button.text = "Réessayer"
	current.clear()
	last_balance = -1
	wallet_label.get_parent().get_parent().hide()
	synced_cards.clear()
	synced_code = ""
	marked.clear()
	last_ball = 0
	chat_open = false
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	connection.show()
	home.hide()
	game.hide()
	chat_panel.hide()
	status.text = "Connexion interrompue. Vérifie l’adresse du serveur et reconnecte-toi."

func read_web_launch() -> void:
	if not OS.has_feature("web"):
		return
	var window := JavaScriptBridge.get_interface("window")
	var url: Variant = JavaScriptBridge.create_object("URL", str(window.location.href))
	default_address = ("wss://" if str(url.protocol) == "https:" else "ws://") + str(url.host) + "/ws"
	var token: Variant = url.searchParams.get("rg_token")
	if token is String:
		platform_token = token
		url.searchParams.delete("rg_token")
		window.history.replaceState(null, "", str(url.href))

func connect_game(address: String, nickname: String) -> void:
	selected_nickname = nickname.strip_edges().left(20)
	if selected_nickname.is_empty() and platform_token.is_empty():
		status.text = "Choisis un pseudo pour entrer."
		return
	if connect_deadline > 0:
		return
	var peer := WebSocketMultiplayerPeer.new()
	var error := peer.create_client(address.strip_edges())
	if error != OK:
		status.text = "Adresse invalide. Exemple : ws://127.0.0.1:8071"
		return
	status.text = "Chargement des salons…"
	connect_button.disabled = true
	connect_deadline = Time.get_ticks_msec() + 16000
	if not platform_token.is_empty():
		connection.hide()
	multiplayer.multiplayer_peer = peer

func panel_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(15)
	style.content_margin_left = 11
	style.content_margin_right = 11
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func label(parent: Node, caption: String, size := 16, color := MUTED) -> Label:
	var node := Label.new()
	node.text = caption
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	parent.add_child(node)
	return node

func button(parent: Node, caption: String, callback: Callable) -> Button:
	var node := Button.new()
	node.text = caption
	node.custom_minimum_size.y = 39
	node.pressed.connect(callback)
	parent.add_child(node)
	return node

func column(parent: Node, spacing := 9) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation", spacing)
	parent.add_child(node)
	return node

func row(parent: Node, spacing := 8) -> HBoxContainer:
	var node := HBoxContainer.new()
	node.add_theme_constant_override("separation", spacing)
	parent.add_child(node)
	return node

func field(parent: Node, placeholder: String, initial := "") -> LineEdit:
	var node := LineEdit.new()
	node.placeholder_text = placeholder
	node.text = initial
	node.custom_minimum_size.y = 42
	parent.add_child(node)
	return node

func surface(parent: Node, fill: String, edge: String) -> PanelContainer:
	var node := PanelContainer.new()
	var style := panel_style(Color(fill), Color(edge))
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	style.set_corner_radius_all(15)
	node.add_theme_stylebox_override("panel", style)
	parent.add_child(node)
	return node

func emphasis(node: Button) -> void:
	for state in ["normal", "hover", "pressed"]:
		var fill := Color("#ffce56") if state == "normal" else Color("#ffe292")
		var style := panel_style(fill, Color("#bd6e2b"))
		style.shadow_color = Color("#271352")
		style.shadow_size = 3
		style.shadow_offset = Vector2(0, 3) if state != "pressed" else Vector2.ZERO
		node.add_theme_stylebox_override(state, style)
		node.add_theme_color_override("font_color" if state == "normal" else "font_%s_color" % state, Color("#21180e"))

func coin_amount(amount: int) -> String:
	var digits := str(amount)
	for index in range(digits.length() - 3, 0, -3):
		digits = digits.insert(index, " ")
	return digits

func meter(parent: Node, limit: float, accent: Color) -> ProgressBar:
	var progress := ProgressBar.new()
	progress.show_percentage = false
	progress.max_value = limit
	progress.custom_minimum_size.y = 5
	progress.add_theme_stylebox_override("background", ball_chip(Color("#594183")))
	progress.add_theme_stylebox_override("fill", ball_chip(accent))
	parent.add_child(progress)
	return progress

func adapt_layout() -> void:
	ticket_layout.vertical = size.x < 1070
	entry_layout.vertical = ticket_layout.vertical
	cage.custom_minimum_size.y = 188 if ticket_layout.vertical else 252
	called_board.columns = 15 if ticket_layout.vertical else 10
	number_grid.columns = 2 if size.x >= 1600 else 1
	if is_instance_valid(lobby_grid):
		lobby_grid.columns = 1 if ticket_layout.vertical else 2

func build_ui() -> void:
	var skin := Theme.new()
	skin.default_font_size = 17
	skin.set_stylebox("normal", "Button", panel_style(Color("#5934a5"), Color("#a384ff")))
	skin.set_stylebox("hover", "Button", panel_style(Color("#7d52ca"), MINT))
	skin.set_stylebox("pressed", "Button", panel_style(Color("#7143bb"), MINT))
	skin.set_stylebox("disabled", "Button", panel_style(Color("#332260"), Color("#523b80")))
	skin.set_stylebox("focus", "Button", panel_style(Color(0, 0, 0, 0), GOLD))
	skin.set_stylebox("normal", "LineEdit", panel_style(Color("#31215f"), Color("#8c64e3")))
	skin.set_color("font_color", "Button", Color("#f7f1e7"))
	skin.set_color("font_disabled_color", "Button", Color("#9daea5"))
	theme = skin

	var background := TextureRect.new()
	var tones := Gradient.new()
	tones.colors = PackedColorArray([Color("#653ccd"), Color("#221144")])
	var lighting := GradientTexture2D.new()
	lighting.gradient = tones
	lighting.fill = GradientTexture2D.FILL_RADIAL
	lighting.fill_from = Vector2(0.52, 0.13)
	lighting.fill_to = Vector2(0.96, 0.85)
	background.texture = lighting
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var frame := column(self, 0)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(scroll)
	var padding := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		padding.add_theme_constant_override("margin_" + side, 16)
	padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(padding)
	root = column(padding, 11)
	var brand := row(root)
	var brand_name := column(brand, 0)
	brand_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label(brand_name, "REVANCHE GAMES", 13, MINT)
	label(brand_name, "Loto Revanche", 34, GOLD)
	var wallet_chip := surface(brand, "#56359d", "#a779eb")
	var wallet_stack := column(wallet_chip, 0)
	label(wallet_stack, "PORTEFEUILLE", 12, MUTED)
	wallet_label = label(wallet_stack, "", 22, GOLD)
	wallet_chip.hide()
	status = label(root, "Entre dans la salle pour voir les parties ouvertes.", 15)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body = column(root)
	connection = surface(body, "#3c2474", "#7753c2")
	entry_layout = BoxContainer.new()
	entry_layout.add_theme_constant_override("separation", 20)
	connection.add_child(entry_layout)
	var cover := TextureRect.new()
	cover.texture = COVER
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover.custom_minimum_size.y = 335
	cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry_layout.add_child(cover)
	var form := column(entry_layout, 12)
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.alignment = BoxContainer.ALIGNMENT_CENTER
	label(form, "Entrer dans la salle", 26, GOLD)
	var nickname := field(form, "Ton pseudo")
	nickname.max_length = 20
	var address := field(form, "Adresse du serveur", default_address)
	address.visible = not OS.has_feature("web")
	nickname.visible = platform_token.is_empty()
	connect_button = button(form, "Entrer dans le loto", func(): connect_game(address.text, nickname.text))
	emphasis(connect_button)
	nickname.text_submitted.connect(func(_text):
		if not connect_button.disabled:
			connect_button.pressed.emit())
	home = column(body)
	home.hide()
	game = column(body, 9)
	game.hide()
	var room_info := row(surface(game, "#482985", "#7956bc"), 12)
	var room_title := column(room_info, 2)
	room_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_header = label(room_title, "", 22, Color("#fbf3e5"))
	pot_label = label(room_title, "", 15, MINT)
	stage_phase = label(room_info, "ENTRÉES OUVERTES", 13, GOLD)
	stage_phase.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var theatre := column(surface(game, "#442790", "#c495ff"), 8)
	var stage := row(theatre, 14)
	cage = SubViewportContainer.new()
	cage.custom_minimum_size = Vector2(0, 173)
	cage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cage.stretch = true
	cage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cage.set_script(Cage)
	stage.add_child(cage)
	var display_panel := surface(stage, "#271557", "#bb95fc")
	display_panel.custom_minimum_size.x = 185
	var display := column(display_panel, 1)
	display.alignment = BoxContainer.ALIGNMENT_CENTER
	var display_name := label(display, "✦  BOULE EN JEU  ✦", 16, MINT)
	display_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ball_label = label(display, "–", 86, GOLD)
	ball_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "DejaVu Sans Mono", "monospace"])
	ball_label.add_theme_font_override("font", mono)
	ball_label.add_theme_color_override("font_shadow_color", Color("#7d5129"))
	ball_label.add_theme_constant_override("shadow_offset_y", 2)
	draw_status = label(display, "En attente", 14)
	draw_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage_meter = meter(theatre, 90.0, GOLD)
	recent_balls = label(theatre, "Aucune boule tirée", 15, MINT)

	ticket_layout = BoxContainer.new()
	ticket_layout.add_theme_constant_override("separation", 12)
	game.add_child(ticket_layout)
	var ticket_column := column(ticket_layout, 10)
	ticket_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var board_column := column(ticket_layout, 10)
	board_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var board := column(surface(board_column, "#302063", "#7553bc"), 5)
	var board_toolbar := row(board)
	board_heading = button(board_toolbar, "Numéros sortis", func():
		called_board.visible = not called_board.visible
		refresh_board_heading())
	board_heading.alignment = HORIZONTAL_ALIGNMENT_LEFT
	board_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_button = button(board_toolbar, "Ordre du tirage", switch_board_order)
	called_board = GridContainer.new()
	called_board.columns = 15
	called_board.add_theme_constant_override("h_separation", 3)
	called_board.add_theme_constant_override("v_separation", 3)
	board.add_child(called_board)
	for number in range(1, 91):
		var cell := label(called_board, str(number).pad_zeros(2), 14)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.custom_minimum_size.y = 22
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		called_cells.append(cell)

	var ticket_panel := column(surface(ticket_column, "#322375", "#8260ed"), 10)
	card_caption = label(ticket_panel, "Mes cartons", 26, GOLD)
	var tip := label(ticket_panel, "Appuie sur le numéro doré avant la boule suivante. La coche verte confirme ton clic.", 16)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	number_grid = GridContainer.new()
	number_grid.columns = 1
	number_grid.add_theme_constant_override("v_separation", 10)
	ticket_panel.add_child(number_grid)
	purchase_panel = column(surface(ticket_column, "#422778", "#845ddb"), 7)
	label(purchase_panel, "Acheter des cartons", 20, GOLD)
	buy_controls = row(purchase_panel)
	quantity = SpinBox.new()
	quantity.min_value = 1
	quantity.max_value = 1
	quantity.custom_minimum_size.x = 82
	quantity.value_changed.connect(func(_value: float): refresh_price())
	buy_controls.add_child(quantity)
	buy_button = button(buy_controls, "Acheter des cartons", func():
		action.rpc_id(1, "buy", int(quantity.value)))
	buy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	emphasis(buy_button)
	buy_summary = label(purchase_panel, "", 14, MUTED)
	buy_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	start_button = button(purchase_panel, "Lancer le tirage", func(): action.rpc_id(1, "start"))
	emphasis(start_button)
	results = column(surface(board_column, "#302063", "#405f4c"), 6)
	resized.connect(adapt_layout)
	adapt_layout()

	var footer_panel := surface(frame, "#302063", "#633dae")
	var footer := column(footer_panel, 6)
	var actions := row(footer)
	dock_ball = label(actions, "", 19, GOLD)
	chat_button = button(actions, "Chat du loto", toggle_chat)
	chat_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(actions, "Quitter", func(): action.rpc_id(1, "leave"))
	chat_panel = column(footer, 5)
	chat_log = RichTextLabel.new()
	chat_log.custom_minimum_size.y = 104
	chat_log.scroll_following = true
	chat_panel.add_child(chat_log)
	var composer := row(chat_panel)
	chat_input = field(composer, "Écrire au salon")
	chat_input.max_length = 240
	chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_input.text_submitted.connect(func(_text): send_chat())
	button(composer, "Envoyer", send_chat)
	chat_panel.hide()
	footer_panel.hide()
	game.visibility_changed.connect(func(): footer_panel.visible = game.visible)

func toggle_chat() -> void:
	chat_open = not chat_open
	chat_panel.visible = chat_open
	chat_button.text = "Fermer le chat" if chat_open else "Chat du loto"
	message_count = current.chat.size()

func send_chat() -> void:
	if not chat_input.text.strip_edges().is_empty():
		action.rpc_id(1, "chat", chat_input.text)
		chat_input.clear()

func clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

func render_lobby() -> void:
	if lobby_cache == current.lobby and remembered_balance == current.balance:
		return
	lobby_cache = current.lobby
	remembered_balance = current.balance
	clear_children(home)
	label(home, "Salons ouverts  ·  %d" % current.lobby.size(), 23, Color("#fff1d8"))
	if current.lobby.is_empty():
		label(home, "Aucun salon ouvert pour le moment.")
	lobby_grid = GridContainer.new()
	lobby_grid.add_theme_constant_override("h_separation", 10)
	lobby_grid.add_theme_constant_override("v_separation", 10)
	home.add_child(lobby_grid)
	adapt_layout()
	for entry in current.lobby:
		var card := surface(lobby_grid, "#302063", "#8562ce")
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var group := column(card, 7)
		label(group, "Salon %s · %s" % [entry.code, entry.host], 19, GOLD)
		label(group, "%d joueurs · %d cartons · Cagnotte %d pièces" % [entry.count,
			entry.tickets, entry.tickets * entry.price], 15)
		label(group, "Quines %s / %s  ·  Carton plein %s" % [
			coin_amount(entry.prizes[0]), coin_amount(entry.prizes[1]), coin_amount(entry.prizes[2])], 15, MINT)
		var join := button(group, "Rejoindre · %d pièces" % entry.price,
			func(): action.rpc_id(1, "join", entry.code))
		join.disabled = current.balance < entry.price

	var create := column(surface(home, "#4e2c91", "#9471f1"))
	label(create, "Créer un salon", 24, GOLD)
	label(create, "Choisis le prix du carton. Ton premier carton est acheté à l’ouverture du salon.", 15).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var prices := row(create, 5)
	for price in Room.PRICES:
		var node := button(prices, coin_amount(price), func(): action.rpc_id(1, "create", price))
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		node.disabled = current.balance < price
		emphasis(node)

func update_clock() -> void:
	if draw_status == null or not game.visible:
		return
	if current.phase == "attente":
		draw_status.text = "En attente"
	elif current.phase == "terminée":
		draw_status.text = "Tirage terminé"
	elif current.phase == "règlement":
		draw_status.text = "Versement des gains…"
	else:
		var seconds := maxi(0, ceili((next_draw_at - Time.get_ticks_msec()) / 1000.0))
		draw_status.text = "Réclamations · %ds" % seconds if current.final_window else "Prochaine boule · %ds" % seconds
		if current_ball_label > 0:
			dock_ball.text = "Boule %02d · %ds" % [current_ball_label, seconds]

func render_game() -> void:
	room_header.text = "Salon %s  ·  %d joueurs  ·  %d cartons" % [current.code,
		current.count, current.tickets]
	var total: int = current.price * current.tickets
	pot_label.text = "Cagnotte %s pièces  ·  Carton %s pièces" % [coin_amount(total), coin_amount(current.price)]
	stage_phase.text = {"attente": "ENTRÉES OUVERTES", "partie": "TIRAGE EN COURS",
		"règlement": "VERSEMENT", "terminée": "PARTIE TERMINÉE"}[current.phase]
	start_button.visible = current.host and current.phase == "attente"
	start_button.disabled = current.count < 2
	start_button.text = "En attente d’un 2ᵉ joueur" if start_button.disabled else "Lancer le tirage"
	purchase_panel.visible = current.phase == "attente"
	quantity.max_value = maxi(1, floori(float(current.balance) / current.price))
	refresh_price()
	var drawn: Array = current.drawn
	var ball: int = drawn.back() if not drawn.is_empty() else 0
	if ball != last_ball:
		last_ball = ball
		cage.reveal(ball)
		if reveal_tween:
			reveal_tween.kill()
		reveal_tween = create_tween()
		reveal_tween.tween_callback(show_ball.bind(ball)).set_delay(0.67)
	elif ball == 0:
		show_ball(0)
		if cage.has_method("reset_stage"):
			cage.reset_stage()
	refresh_board_heading()
	paint_board()
	render_card()
	render_results()
	update_clock()

	var chat_text := "\n".join(current.chat)
	if chat_log.text != chat_text:
		if not chat_open and not chat_log.text.is_empty():
			message_count += 1
		chat_log.text = chat_text
	if not chat_open:
		chat_button.text = "Chat du loto" if message_count == 0 else "Chat du loto · %d" % message_count

func show_ball(ball: int) -> void:
	current_ball_label = ball
	ball_label.text = str(ball).pad_zeros(2) if ball > 0 else "–"
	dock_ball.text = "Boule %02d" % ball if ball else "Salon %s" % current.code
	ball_label.pivot_offset = ball_label.size * 0.5
	ball_label.scale = Vector2.ONE * 0.82
	create_tween().tween_property(ball_label, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	paint_board()
	render_card()

func refresh_board_heading() -> void:
	board_heading.text = "Numéros sortis   %d / 90    %s" % [current.drawn.size(), "⌄" if called_board.visible else "›"]

func ball_chip(fill: Color) -> StyleBoxFlat:
	var style := panel_style(fill, fill)
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.set_corner_radius_all(5)
	return style

func switch_board_order() -> void:
	chronological = not chronological
	order_button.text = "Tableau 1–90" if chronological else "Ordre du tirage"
	paint_board()

func paint_board() -> void:
	var drawn: Array = current.drawn
	var shown := drawn.duplicate()
	if last_ball != current_ball_label:
		shown.pop_back()
	var recent := PackedStringArray()
	for number in shown.slice(maxi(0, shown.size() - 7)):
		recent.append(str(number).pad_zeros(2))
	stage_meter.value = shown.size()
	recent_balls.text = "Dernières sorties   " + "  ·  ".join(recent) if not recent.is_empty() else "Aucune boule tirée"
	for index in range(90):
		var number: int = shown[index] if chronological and index < shown.size() else index + 1
		var cell := called_cells[index]
		cell.text = "–" if chronological and index >= shown.size() else str(number).pad_zeros(2)
		if number == current_ball_label and (not chronological or index < shown.size()):
			cell.add_theme_color_override("font_color", Color("#171c13"))
			cell.add_theme_stylebox_override("normal", ball_chip(GOLD))
		elif number in shown and (not chronological or index < shown.size()):
			cell.add_theme_color_override("font_color", MINT)
			cell.add_theme_stylebox_override("normal", ball_chip(Color("#553488")))
		else:
			cell.add_theme_color_override("font_color", Color("#caadf1"))
			cell.remove_theme_stylebox_override("normal")

func refresh_price() -> void:
	if not current.has("price"):
		return
	var amount := int(quantity.value) * int(current.price)
	buy_button.disabled = current.balance < amount
	buy_button.text = "Acheter · %s pièces" % coin_amount(amount)
	var quantity_count := int(quantity.value)
	var priced := "%d × %s pièces" % [quantity_count, coin_amount(current.price)]
	buy_summary.text = "%s   ·   Solde après achat %s" % [priced, coin_amount(current.balance - amount)] if not buy_button.disabled else "%s   ·   Solde insuffisant" % priced
	quantity.editable = current.balance >= current.price

func render_card() -> void:
	var cards: Array = current.cards
	var key := str([current.code, cards.size(), current.phase, last_ball, current_ball_label,
		current.awards.size(), marked, current.used_lines])
	if key == card_render_key:
		return
	card_render_key = key
	card_caption.text = "Mes cartons · %d" % cards.size()
	if cards.size() != card_views.size():
		clear_children(number_grid)
		card_views.clear()
		for ticket in range(cards.size()):
			var panel := column(surface(number_grid, "#fff1d1", "#ffab55"), 6)
			panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var caption := label(panel, "", 20, Color("#382362"))
			var grid := GridContainer.new()
			grid.columns = 9
			panel.add_child(grid)
			var cells := []
			for index in range(27):
				var cell := button(grid, "", toggle_cell.bind(ticket, index))
				cell.custom_minimum_size.y = 42
				cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				cell.add_theme_font_size_override("font_size", 20)
				cells.append(cell)
			var claim := button(panel, "Réclamer", claim_ticket.bind(ticket))
			emphasis(claim)
			card_views.append({"caption": caption, "cells": cells, "claim": claim})
	var stage: int = current.awards.size()
	for ticket in range(cards.size()):
		var view: Dictionary = card_views[ticket]
		var marks: Array = marked.get(ticket, [])
		var used: Array = current.used_lines.get(ticket, [])
		var card: Array = cards[ticket]
		view.caption.text = "Carton %02d    •    %d / 15 cochés" % [ticket + 1, marks.size()]
		for index in range(27):
			@warning_ignore("integer_division")
			var number: int = card[index / 9][index % 9]
			var cell: Button = view.cells[index]
			var checked := number in marks
			var available := number > 0 and number == current_ball_label and last_ball == current_ball_label
			cell.text = ("✓ " if checked else "") + str(number) if number else ""
			cell.disabled = not available or checked or current.phase != "partie"
			var fill := Color("#f9daa7")
			var ink := Color("#45346a")
			if number == 0:
				fill = Color("#f4e8ca")
			elif checked:
				fill = Color("#95edaa")
			elif available:
				fill = Color("#ffc261")
			if not card_tiles.has(fill):
				card_tiles[fill] = ball_chip(fill)
			var tile: StyleBoxFlat = card_tiles[fill]
			for state in ["normal", "hover", "pressed", "disabled"]:
				cell.add_theme_stylebox_override(state, tile)
			for state in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
				cell.add_theme_color_override(state, ink)
		var claim: Button = view.claim
		claim.visible = current.phase == "partie"
		claim.text = ["Réclamer la 1ʳᵉ quine", "Réclamer la 2ᵉ quine", "Réclamer le carton plein"][mini(stage, 2)]
		claim.disabled = true
		if stage == 2:
			claim.disabled = marks.size() != 15
		elif stage < 2:
			for line in range(3):
				if line not in used and Room.marked_row(card[line], marks):
					claim.disabled = false
					break

func render_results() -> void:
	var key := "%s/%s/%s/%s" % [current.code, current.phase, str(current.prizes), str(current.awards)]
	if key == award_key:
		return
	award_key = key
	clear_children(results)
	label(results, "Gains du salon", 21, GOLD)
	for index in range(Room.TITLES.size()):
		var active: bool = index == current.awards.size() and current.phase == "partie"
		var won: bool = index < current.awards.size()
		var result := row(surface(results, "#163c2e" if won else ("#3b3220" if active else "#142b23"),
			"#4d8167" if won else ("#ac8b56" if active else "#284436")))
		var name := label(result, Room.TITLES[index], 15, GOLD if index == current.awards.size() else MUTED)
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var caption := "%s pièces" % coin_amount(current.prizes[index])
		if index < current.awards.size():
			caption = "%s · %s" % [current.awards[index].name, caption]
		elif current.phase == "terminée":
			caption = "Lot non réclamé"
		label(result, caption, 15, MINT if index < current.awards.size() else Color("#eee9de"))
	if current.phase == "terminée":
		label(results, "Part Revanche Games · %d pièces" % (
			current.price * current.tickets - current.prizes[0] - current.prizes[1] - current.prizes[2]), 14)

func claim_ticket(ticket: int) -> void:
	action.rpc_id(1, "claim", {"stage": current.awards.size(), "ticket": ticket})

func toggle_cell(ticket: int, index: int) -> void:
	if card_views[ticket].cells[index].disabled:
		return
	@warning_ignore("integer_division")
	var number: int = current.cards[ticket][index / 9][index % 9]
	action.rpc_id(1, "mark", {"ticket": ticket, "number": number})

func hello(id: int, value: Variant) -> void:
	if sessions.has(id) or not (value is Dictionary) or not (value.get("name") is String):
		return
	var account := ""
	var balance := 10000
	var nickname: String = value.name
	if wallet:
		var token: Variant = value.get("token")
		if not (token is String) or token.length() > 4096:
			return
		var identity: Dictionary = await wallet.call_api({"action": "identity", "token": token})
		if id not in multiplayer.get_peers() or sessions.has(id):
			return
		if not identity.get("ok", false):
			hint.rpc_id(id, identity.error)
			return
		account = identity.uid
		balance = int(identity.balance)
		nickname = identity.username
		while wallet_busy:
			await get_tree().process_frame
		if id not in multiplayer.get_peers() or sessions.has(id):
			return
		for old_id in sessions.keys():
			var previous: Dictionary = sessions[old_id]
			if previous.uid != account:
				continue
			var previous_room = rooms.get(previous.room)
			if previous_room != null:
				previous_room.reassign_player(old_id, id)
				previous.offline = false
				previous.balance = balance
				previous.sent_count = 0
				previous.sent_code = ""
				sessions[id] = previous
			sessions.erase(old_id)
			departing.erase(old_id)
			if old_id in multiplayer.get_peers():
				multiplayer.multiplayer_peer.disconnect_peer(old_id)
			if previous_room != null:
				broadcast()
				return
			break
	nickname = nickname.strip_edges().replace("\n", " ").left(20)
	if nickname.is_empty():
		nickname = "Joueur %d" % (sessions.size() + 1)
	sessions[id] = {"uid": account, "name": nickname, "balance": balance, "room": "", "last_chat": -850}
	broadcast()

func wallet_action(id: int, kind: String, value: Variant) -> void:
	if not wallet_queue.has(id) and not departing.has(id):
		wallet_queue[id] = {"kind": kind, "value": value, "room": sessions[id].room}
	resume_wallet_queue()

func resume_wallet_queue() -> void:
	if wallet_busy:
		return
	if not departing.is_empty():
		flush_departures.call_deferred()
	elif not wallet_queue.is_empty():
		run_wallet_queue.call_deferred()

func run_wallet_queue() -> void:
	if wallet_busy or wallet_queue.is_empty():
		return
	var id: int = wallet_queue.keys()[0]
	var command: Dictionary = wallet_queue[id]
	wallet_busy = true
	if sessions.has(id) and not departing.has(id) and sessions[id].room == command.room:
		await perform_wallet_action(id, command.kind, command.value)
	wallet_queue.erase(id)
	wallet_busy = false
	broadcast()
	remove_finished_rooms()
	resume_wallet_queue()

func perform_wallet_action(id: int, kind: String, value: Variant) -> void:
	var session: Dictionary = sessions[id]
	var code: String = session.room
	var room = rooms.get(code)
	var payload := {"action": kind, "uid": session.uid}
	var quantity_to_buy := 1
	match kind:
		"create":
			if code != "" or not (value is int) or value not in Room.PRICES:
				return
			room = Room.new(id, value)
			room.wallet_id = Wallet.id()
			payload.price = value
		"join":
			if code != "" or not (value is String) or not rooms.has(value):
				return
			room = rooms[value]
			if room.phase != "attente" or room.players.size() >= 40:
				return
			code = value
			payload.action = "buy"
		"buy":
			if room == null or room.phase != "attente" or not (value is int) or value < 1:
				return
			quantity_to_buy = value
		"leave":
			await leave_room(id)
			return
		"start":
			if room == null or room.host != id or room.phase != "attente" or room.players.size() < 2:
				return
		_:
			return
	payload.round = room.wallet_id
	if payload.action in ["create", "buy"]:
		payload.quantity = quantity_to_buy
		payload.request = Wallet.id()
	var result: Dictionary = await wallet.call_api(payload)
	if not result.get("ok", false):
		if not departing.has(id):
			hint.rpc_id(id, result.error)
		if result.get("temporary", false):
			if kind == "create":
				await wallet.call_api({"action": "cancel", "round": room.wallet_id})
			else:
				begin_settlement(room, true)
		return
	if kind == "start":
		room.start()
		return
	if kind == "create":
		room_sequence += 1
		code = str(room_sequence).pad_zeros(4)
		rooms[code] = room
	session.balance = int(result.balance)
	session.room = code
	room.accounts[id] = session.uid
	for _ticket in range(quantity_to_buy):
		room.add_player(id, session.name)

func begin_settlement(room, cancel := false) -> void:
	room.phase = "règlement"
	room.cancelling = cancel
	room.pending_balance = true

func settle_wallet(room) -> void:
	room.wallet_job = true
	var result: Dictionary = await wallet.call_api({
		"action": "cancel" if room.cancelling else "settle",
		"round": room.wallet_id, "winners": room.winning_accounts,
	})
	room.wallet_job = false
	if result.get("temporary", false):
		room.retry_at = Time.get_ticks_msec() + 5000
		return
	room.pending_balance = false
	room.phase = "terminée"
	if result.get("ok", false):
		var balances: Variant = result.get("balances")
		if balances is Dictionary:
			for id in sessions:
				sessions[id].balance = int(balances.get(sessions[id].uid, sessions[id].balance))
		room.add_chat("Salon annulé · Les cartons ont été remboursés." if room.cancelling else
			"Les gains et éventuels remboursements sont versés au portefeuille.")
	else:
		room.add_chat("Portefeuille · " + str(result.error))
	broadcast()
	remove_finished_rooms()
