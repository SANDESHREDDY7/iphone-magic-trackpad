const http = require("http");
const fs = require("fs");
const path = require("path");
const dgram = require("dgram");
const crypto = require("crypto");
const WebSocket = require("ws");
const robot = require("robotjs");
const QRCode = require("qrcode");
const { exec } = require('child_process');
const os = require("os");

const PORT = 3000;
const DISCOVERY_PORT = 3001;

const isMac = os.platform() === "darwin";
const isWin = os.platform() === "win32";

// --- SECURITY & PIN CONFIGURATION ---
const AUTH_FILE = path.join(os.homedir(), ".magictrackpad_auth.json");
let authConfig = {
  pin: "1234",
  requirePin: false,
  trustedTokens: [],
};

try {
  if (fs.existsSync(AUTH_FILE)) {
    const raw = fs.readFileSync(AUTH_FILE, "utf8");
    authConfig = { ...authConfig, ...JSON.parse(raw) };
  } else {
    // Generate an initial memorable 4-digit PIN
    authConfig.pin = Math.floor(1000 + Math.random() * 9000).toString();
    saveAuthConfig();
  }
} catch (e) {
  console.log("Error loading auth config, using defaults:", e.message);
}

function saveAuthConfig() {
  try {
    fs.writeFileSync(AUTH_FILE, JSON.stringify(authConfig, null, 2), "utf8");
  } catch (e) {
    console.log("Could not persist auth config:", e.message);
  }
}

function getLocalIP() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === "IPv4" && !iface.internal) return iface.address;
    }
  }
  return "localhost";
}

// Active clients tracking for dashboard
const activeClients = new Map();

// --- HTTP SERVER & DASHBOARD ---
const server = http.createServer(async (req, res) => {
  const localIp = getLocalIP();
  const phoneUrl = `http://${localIp}:${PORT}`;

  // 1. API: Discovery & Info
  if (req.url === "/api/info") {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    });
    return res.end(JSON.stringify({
      status: "ok",
      name: os.hostname(),
      os: isMac ? "mac" : (isWin ? "windows" : os.platform()),
      ip: localIp,
      port: PORT,
      requirePin: authConfig.requirePin,
    }));
  }

  // 2. API: QR Code Image Data
  if (req.url === "/api/qr") {
    try {
      const qrDataUrl = await QRCode.toDataURL(phoneUrl, { margin: 2, width: 260 });
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      });
      return res.end(JSON.stringify({ qr: qrDataUrl, url: phoneUrl }));
    } catch (e) {
      res.writeHead(500);
      return res.end("QR generation failed");
    }
  }

  // 3. API: Toggle PIN requirement or change PIN
  if (req.url === "/api/settings" && req.method === "POST") {
    let body = "";
    req.on("data", chunk => { body += chunk; });
    req.on("end", () => {
      try {
        const payload = JSON.parse(body);
        if (typeof payload.requirePin === "boolean") {
          authConfig.requirePin = payload.requirePin;
        }
        if (payload.pin && payload.pin.length === 4) {
          authConfig.pin = payload.pin;
        }
        saveAuthConfig();
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ status: "updated", authConfig }));
      } catch (e) {
        res.writeHead(400);
        return res.end("Invalid settings JSON");
      }
    });
    return;
  }

  // 4. Desktop Web Companion Dashboard
  if (req.url === "/dashboard") {
    try {
      const qrDataUrl = await QRCode.toDataURL(phoneUrl, { margin: 2, width: 240 });
      const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Magic Trackpad Desktop Control Center</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: #0c0d14; color: #fff; padding: 32px; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
    .card { background: rgba(25, 27, 38, 0.95); border: 1px solid rgba(255,255,255,0.1); border-radius: 24px; padding: 32px; max-width: 500px; width: 100%; box-shadow: 0 20px 50px rgba(0,0,0,0.6); text-align: center; }
    .badge { display: inline-flex; align-items: center; gap: 8px; background: rgba(48,209,88,0.15); color: #30d158; border: 1px solid rgba(48,209,88,0.3); padding: 6px 14px; border-radius: 20px; font-size: 13px; font-weight: 600; margin-bottom: 20px; }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #30d158; box-shadow: 0 0 8px #30d158; }
    h1 { font-size: 24px; font-weight: 700; margin-bottom: 6px; }
    p.sub { color: #888; font-size: 14px; margin-bottom: 24px; }
    .qr-container { background: #fff; padding: 14px; border-radius: 20px; display: inline-block; box-shadow: 0 10px 30px rgba(0,0,0,0.3); margin-bottom: 20px; }
    .qr-container img { display: block; border-radius: 12px; }
    .pin-box { background: rgba(10,132,255,0.1); border: 1px solid rgba(10,132,255,0.3); border-radius: 16px; padding: 14px; margin-bottom: 24px; display: flex; align-items: center; justify-content: space-between; }
    .pin-label { font-size: 13px; color: #aaa; text-align: left; }
    .pin-value { font-size: 28px; font-weight: 800; letter-spacing: 4px; color: #0a84ff; }
    .url-chip { background: rgba(255,255,255,0.06); padding: 10px 16px; border-radius: 12px; font-family: monospace; font-size: 14px; color: #fff; word-break: break-all; margin-bottom: 20px; }
    .toggle-row { display: flex; align-items: center; justify-content: space-between; background: rgba(255,255,255,0.04); padding: 14px 18px; border-radius: 14px; font-size: 14px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge"><span class="dot"></span> Server Active on ${isMac ? 'macOS' : (isWin ? 'Windows' : os.platform())}</div>
    <h1>Magic Trackpad Remote</h1>
    <p class="sub">Scan with your iPhone or Android camera to connect instantly</p>
    <div class="qr-container">
      <img src="${qrDataUrl}" width="220" height="220" alt="QR Code" />
    </div>
    <div class="url-chip">${phoneUrl}</div>
    <div class="pin-box">
      <div class="pin-label">Pairing Security PIN<br><span style="font-size: 11px; color:#666;">Enter this in your phone if prompted</span></div>
      <div class="pin-value">${authConfig.pin}</div>
    </div>
    <div class="toggle-row">
      <span>Require Security PIN</span>
      <strong style="color: ${authConfig.requirePin ? '#30d158' : '#888'};">${authConfig.requirePin ? 'ENABLED' : 'DISABLED'}</strong>
    </div>
  </div>
</body>
</html>`;
      res.writeHead(200, { "Content-Type": "text/html" });
      return res.end(html);
    } catch (e) {
      res.writeHead(500);
      return res.end("Error loading dashboard");
    }
  }

  // 5. Default: Mobile Web Trackpad UI
  const filePath = path.join(__dirname, "public", "index.html");
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end("Not found"); }
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(data);
  });
});

// --- UDP DISCOVERY BEACON (PORT 3001) ---
const udpSocket = dgram.createSocket({ type: "udp4", reuseAddr: true });

udpSocket.on("error", (err) => {
  console.log("UDP Discovery error:", err.message);
});

udpSocket.on("message", (msg, rinfo) => {
  try {
    const text = msg.toString().trim();
    if (text.includes("MAGIC_TRACKPAD_DISCOVER")) {
      const response = JSON.stringify({
        magic: "MAGIC_TRACKPAD_SERVER",
        hostname: os.hostname(),
        os: isMac ? "mac" : (isWin ? "windows" : os.platform()),
        ip: getLocalIP(),
        port: PORT,
        requirePin: authConfig.requirePin,
      });
      udpSocket.send(response, rinfo.port, rinfo.address);
    }
  } catch (_) {}
});

udpSocket.bind(DISCOVERY_PORT, () => {
  try {
    udpSocket.setBroadcast(true);
  } catch (_) {}
});

// Periodic broadcast every 3 seconds to announce server on local Wi-Fi
setInterval(() => {
  try {
    const announcement = JSON.stringify({
      magic: "MAGIC_TRACKPAD_SERVER",
      hostname: os.hostname(),
      os: isMac ? "mac" : (isWin ? "windows" : os.platform()),
      ip: getLocalIP(),
      port: PORT,
      requirePin: authConfig.requirePin,
    });
    udpSocket.send(announcement, DISCOVERY_PORT, "255.255.255.255");
  } catch (_) {}
}, 3000);

// --- WEBSOCKET REAL-TIME SERVER ---
const wss = new WebSocket.Server({ server });

wss.on("connection", (ws, req) => {
  const clientId = crypto.randomUUID();
  const clientIp = req.socket.remoteAddress;

  console.log(`\n📱 New device connected from ${clientIp}!`);

  // Client connection state
  const clientState = {
    id: clientId,
    ip: clientIp,
    authenticated: !authConfig.requirePin,
    connectedAt: Date.now(),
    isDragging: false,
  };
  activeClients.set(ws, clientState);

  // Send initial handshake with system info and auth status
  ws.send(JSON.stringify({
    type: "handshake",
    os: isMac ? "mac" : (isWin ? "windows" : os.platform()),
    hostname: os.hostname(),
    authenticated: clientState.authenticated,
    requirePin: authConfig.requirePin,
  }));

  ws.on("message", (msg) => {
    try {
      const data = JSON.parse(msg);

      // --- HEARTBEAT PING / PONG ---
      if (data.type === "ping") {
        ws.send(JSON.stringify({ type: "pong", time: Date.now() }));
        return;
      }

      // --- AUTHENTICATION & PIN CHECK ---
      if (data.type === "auth") {
        // Token check (auto-reconnect for previously paired devices)
        if (data.token && authConfig.trustedTokens.includes(data.token)) {
          clientState.authenticated = true;
          ws.send(JSON.stringify({
            type: "auth_success",
            token: data.token,
            message: "Connected securely",
          }));
          return;
        }

        // PIN check
        if (data.pin && data.pin.toString() === authConfig.pin.toString()) {
          const newToken = crypto.randomUUID();
          authConfig.trustedTokens.push(newToken);
          if (authConfig.trustedTokens.length > 20) authConfig.trustedTokens.shift();
          saveAuthConfig();

          clientState.authenticated = true;
          ws.send(JSON.stringify({
            type: "auth_success",
            token: newToken,
            message: "PIN verified and paired",
          }));
          console.log(`🔒 Device (${clientIp}) authenticated with PIN!`);
          return;
        }

        ws.send(JSON.stringify({
          type: "auth_failed",
          message: "Incorrect PIN. Check desktop screen.",
        }));
        return;
      }

      // If PIN is required and client is not yet authenticated, reject control commands
      if (authConfig.requirePin && !clientState.authenticated) {
        ws.send(JSON.stringify({
          type: "auth_required",
          message: "Please enter the 4-digit PIN shown on your computer screen",
        }));
        return;
      }

      // --- MOUSE CLICKS ---
      if (data.type === "click") { robot.mouseClick(); return; }
      if (data.type === "double_click") { robot.mouseClick("left", true); return; }
      if (data.type === "rightclick") { robot.mouseClick("right"); return; }
      if (data.type === "scroll") {
        const scrollDelta = data.dir === "up" ? -3 : 3;
        robot.scrollMouse(0, scrollDelta);
        return;
      }

      // --- DRAG COMMANDS ---
      if (data.type === "drag_start") { 
        clientState.isDragging = true; 
        robot.mouseToggle("down"); 
        return; 
      }
      if (data.type === "drag_end") { 
        clientState.isDragging = false; 
        robot.mouseToggle("up"); 
        return; 
      }

      // --- 3-FINGER SWIPE GESTURES (MAC & WINDOWS) ---
      if (data.type === "swipe") {
        if (isMac) {
          if (data.dir === "up") exec('open -a "Mission Control"'); 
          else if (data.dir === "down") exec(`osascript -e 'tell application "System Events" to key code 125 using control down'`);
          else if (data.dir === "left") exec(`osascript -e 'tell application "System Events" to key code 124 using control down'`);
          else if (data.dir === "right") exec(`osascript -e 'tell application "System Events" to key code 123 using control down'`);
        } else if (isWin) {
          if (data.dir === "up") robot.keyTap("tab", "command");
          else if (data.dir === "down") robot.keyTap("d", "command");
          else if (data.dir === "left") robot.keyTap("left", ["control", "command"]);
          else if (data.dir === "right") robot.keyTap("right", ["control", "command"]);
        }
        return; 
      }

      // --- KEYBOARD & MEDIA CONTROLS ---
      if (data.type === "type_text" && typeof data.text === "string") {
        robot.typeString(data.text);
        return;
      }
      if (data.type === "key_tap" && data.key) {
        if (data.modifiers && Array.isArray(data.modifiers)) {
          robot.keyTap(data.key, data.modifiers);
        } else {
          robot.keyTap(data.key);
        }
        return;
      }

      // --- TOUCH TRACKING (MOUSE CURSOR) ---
      if (data.type === "touch_move") {
        const mouse = robot.getMousePos();
        const screen = robot.getScreenSize();
        
        let newX = Math.max(0, Math.min(screen.width - 1, mouse.x + data.dx));
        let newY = Math.max(0, Math.min(screen.height - 1, mouse.y + data.dy));
        
        if (clientState.isDragging) {
          robot.dragMouse(newX, newY); 
        } else {
          robot.moveMouse(newX, newY); 
        }
      }
    } catch (e) {
      console.log("Error processing message:", e);
    }
  });

  ws.on("close", () => {
    activeClients.delete(ws);
  });
});

// --- SERVER STARTUP ---
server.listen(PORT, '0.0.0.0', async () => {
  const localIp = getLocalIP();
  const phoneUrl = `http://${localIp}:${PORT}`;
  const dashboardUrl = `http://localhost:${PORT}/dashboard`;

  console.log("\n=========================================================");
  console.log(` ✨ Magic Trackpad Pro Server Active on ${isMac ? 'macOS' : (isWin ? 'Windows' : os.platform())}!`);
  console.log(` 🔒 Security Pairing PIN: [ ${authConfig.pin} ]`);
  console.log(` 🖥️  Desktop Dashboard:    ${dashboardUrl}`);
  console.log(` 📱 Phone Remote URL:     ${phoneUrl}`);
  console.log("=========================================================\n");

  try {
    const terminalQr = await QRCode.toString(phoneUrl, { type: "terminal", small: true });
    console.log("📱 Scan this QR code with your phone camera to connect:\n");
    console.log(terminalQr);
  } catch (_) {}
});
