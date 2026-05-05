const http = require("http");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");
const robot = require("robotjs");
const { exec } = require('child_process');
const os = require("os");
const PORT = 3000;

function getLocalIP() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === "IPv4" && !iface.internal) return iface.address;
    }
  }
  return "localhost";
}

const server = http.createServer((req, res) => {
  const filePath = path.join(__dirname, "public", "index.html");
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end("Not found"); }
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(data);
  });
});

const wss = new WebSocket.Server({ server });

wss.on("connection", (ws) => {
  console.log("📱 iPhone connected!");

  let isDragging = false;

  ws.on("message", (msg) => {
    try {
      const data = JSON.parse(msg);

      // --- MOUSE CLICKS ---
      if (data.type === "click") { robot.mouseClick(); return; }
      if (data.type === "double_click") { robot.mouseClick("left", true); return; } // THE NEW DOUBLE CLICK FIX!
      if (data.type === "rightclick") { robot.mouseClick("right"); return; }
      if (data.type === "scroll") { robot.scrollMouse(0, data.dir === "up" ? -3 : 3); return; }

      // --- DRAG COMMANDS ---
      if (data.type === "drag_start") { 
        isDragging = true; 
        robot.mouseToggle("down"); 
        return; 
      }
      if (data.type === "drag_end") { 
        isDragging = false; 
        robot.mouseToggle("up"); 
        return; 
      }

      // --- 3-FINGER MAC GESTURES (APPLESCRIPT BYPASS) ---
      if (data.type === "swipe") {
        console.log("👉 Firing native Mac command: " + data.dir);

        if (data.dir === "up") exec('open -a "Mission Control"'); 
        else if (data.dir === "down") exec(`osascript -e 'tell application "System Events" to key code 125 using control down'`);
        else if (data.dir === "left") exec(`osascript -e 'tell application "System Events" to key code 124 using control down'`);
        else if (data.dir === "right") exec(`osascript -e 'tell application "System Events" to key code 123 using control down'`);
        return; 
      }

      // --- TOUCH TRACKING LOGIC ---
      if (data.type === "touch_move") {
        const mouse = robot.getMousePos();
        const screen = robot.getScreenSize();
        
        let newX = Math.max(0, Math.min(screen.width - 1, mouse.x + data.dx));
        let newY = Math.max(0, Math.min(screen.height - 1, mouse.y + data.dy));
        
        if (isDragging) {
          robot.dragMouse(newX, newY); 
        } else {
          robot.moveMouse(newX, newY); 
        }
      }
    } catch (e) {
      console.log("Error parsing message:", e);
    }
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log("✅ Server running!");
  console.log(`👉 Open this on your iPhone: http://${getLocalIP()}:${PORT}`);
});