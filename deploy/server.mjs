import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, request } from "node:http";
import { extname, resolve } from "node:path";

const root = resolve(process.env.LOTO_WEB || "build/web");
const port = process.env.PORT || 8080;
const game = spawn(process.env.GODOT || "godot", ["--headless", "--path", ".", "--", "--server"], {
  env: { ...process.env, PORT: "8071", LOTO_BIND: "127.0.0.1" },
  stdio: "inherit",
});
const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
};
const server = createServer(async (req, res) => {
  const name = req.url.split("?")[0].slice(1) || "index.html";
  if (!["GET", "HEAD"].includes(req.method) || !/^index(?:\.[a-z0-9_-]+)+$/i.test(name)) {
    res.writeHead(404).end();
    return;
  }
  const file = resolve(root, name);
  try {
    const { size } = await stat(file);
    res.writeHead(200, {
      "Content-Type": mime[extname(file)] || "application/octet-stream",
      "Content-Length": size,
      "Referrer-Policy": "no-referrer",
    });
    if (req.method === "HEAD") res.end();
    else createReadStream(file).on("error", () => res.destroy()).pipe(res);
  } catch {
    res.writeHead(404).end();
  }
});

server.on("upgrade", (req, downstream, first) => {
  if (req.url !== "/ws" || req.headers.upgrade?.toLowerCase() !== "websocket") {
    downstream.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    return;
  }
  const upstreamRequest = request({
    hostname: "127.0.0.1",
    port: 8071,
    path: "/",
    headers: req.headers,
  });
  upstreamRequest.on("upgrade", (response, upstream, buffered) => {
    const headers = [];
    for (let index = 0; index < response.rawHeaders.length; index += 2) {
      headers.push(`${response.rawHeaders[index]}: ${response.rawHeaders[index + 1]}`);
    }
    downstream.write(`HTTP/1.1 101 Switching Protocols\r\n${headers.join("\r\n")}\r\n\r\n`);
    if (buffered.length) downstream.write(buffered);
    if (first.length) upstream.write(first);
    downstream.on("close", () => upstream.destroy());
    upstream.on("close", () => downstream.destroy());
    upstream.on("error", () => downstream.destroy());
    downstream.pipe(upstream).pipe(downstream);
  });
  downstream.on("error", () => upstreamRequest.destroy());
  upstreamRequest.on("response", () => downstream.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
  upstreamRequest.on("error", () => downstream.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
  upstreamRequest.end();
});

game.once("exit", (code) => process.exit(code ?? 1));
game.once("error", (error) => {
  console.error(error.message);
  process.exit(1);
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close();
    game.kill(signal);
  });
}
server.listen(port, "0.0.0.0");
