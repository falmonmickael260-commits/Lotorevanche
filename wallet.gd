extends Node

var endpoint := OS.get_environment("LOTO_WALLET_URL")
var secret := OS.get_environment("LOTO_WALLET_SECRET")

func configured() -> bool:
	return not endpoint.is_empty() and not secret.is_empty()

func call_api(payload: Dictionary) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 4.0
	request.body_size_limit = 65536
	request.max_redirects = 0
	add_child(request)
	var headers := PackedStringArray(["Authorization: Bearer " + secret, "Content-Type: application/json"])
	var body := JSON.stringify(payload)
	for attempt in range(3):
		if request.request(endpoint, headers, HTTPClient.METHOD_POST, body) == OK:
			var response: Array = await request.request_completed
			if response[0] == HTTPRequest.RESULT_SUCCESS and response[1] < 500:
				var parsed: Variant = JSON.parse_string(response[3].get_string_from_utf8())
				if parsed is Dictionary:
					request.queue_free()
					return parsed
		if attempt < 2:
			await get_tree().create_timer(0.35 + attempt * 0.5).timeout
	request.queue_free()
	return {"ok": false, "temporary": true, "error": "Le portefeuille est momentanément indisponible."}

static func id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
