// cdp-relay v3: 127.0.0.1:<listenPort> -> <targetHost>:<targetPort> TCP pipe
// 2026-09-14 重写（原版随 gateway 容器层丢失）。纯 node 原生，无依赖。
const net = require("net");
let cfg;
try { cfg = JSON.parse(process.argv[2] || "{}"); } catch (e) { console.error("bad-cfg"); process.exit(2); }
const listenPort = cfg.listenPort, targetHost = cfg.targetHost, targetPort = cfg.targetPort;
if (!listenPort || !targetHost || !targetPort) { console.error("missing-cfg"); process.exit(2); }

const server = net.createServer((client) => {
  const upstream = net.connect(targetPort, targetHost);
  client.pipe(upstream); upstream.pipe(client);
  const kill = () => { try { client.destroy(); } catch (e) {} try { upstream.destroy(); } catch (e) {} };
  client.on("error", kill); upstream.on("error", kill);
  client.on("close", kill); upstream.on("close", kill);
});
server.on("error", (e) => { console.error("relay-err", e.message); process.exit(1); });
server.listen(listenPort, "127.0.0.1", () => {
  console.log("relay-up", listenPort, "->", targetHost + ":" + targetPort);
});
