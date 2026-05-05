Markdown
# 📱 iPhone Magic Trackpad

A zero-latency, fully custom Wi-Fi trackpad that turns an iPhone into a multi-touch mouse for macOS. 

This isn't just a basic web wrapper. It's a custom-engineered, 60fps hardware bridge built from scratch using Node.js and WebSockets, specifically designed to bypass macOS sandboxing and iOS Safari constraints to achieve hardware-level responsiveness.

## 🚀 The Engineering (How it Works)
Building a real-time mouse over standard web protocols requires bleeding-edge optimization. Here are the core hurdles solved in this project:

* **Defeating the macOS Sandbox:** Bypassed strict Apple security restrictions using native AppleScript terminal commands to inject mouse events directly into the OS.
* **iOS Safari Hijacking:** Disabled native iOS web behaviors (pinch-to-zoom, text selection, magnifying glass) to take 100% raw control of the iPhone's capacitive glass.
* **Zero-Latency Game Loop:** Stripped `robotjs` of its artificial 10ms delays (`robot.setMouseDelay(0)`) and built a custom 60fps coordinate tracking loop for ultra-smooth rendering.
* **Client-Side Timing:** Shifted complex gesture recognition (like double-tap-to-drag and haptic feedback triggers) directly to the iPhone to prevent network latency from ruining the user experience.

## 🛠️ Tech Stack
* **Backend Engine:** Node.js, Express
* **Real-Time Bridge:** WebSockets
* **System Control:** `robotjs` (C++ bindings for OS mouse/keyboard control)
* **Frontend:** Vanilla JavaScript, HTML5 Canvas/Touch APIs

## ⚙️ Quick Start (Run it Yourself)

**1. Clone the repo & install dependencies:**
```bash
git clone [https://github.com/SANDESHREDDY7/iphone-magic-trackpad.git](https://github.com/SANDESHREDDY7/iphone-magic-trackpad.git)
cd iphone-magic-trackpad
npm install
2. Boot the Engine:

Bash
npm start
3. Connect the Device:
Ensure your iPhone and Mac are on the same Wi-Fi network (for ultra-low latency, broadcast a hotspot directly from your Mac to your phone).
Open Safari on your iPhone and navigate to the IP address displayed in your terminal (e.g., http://192.168.x.x:3000).

🔥 Features
[x] Flawless 1:1 X/Y coordinate tracking

[x] Single-tap clicking

[x] Double-tap & hold for seamless Drag-and-Drop

[x] Haptic feedback engine

[x] 60fps zero-delay rendering

Built by Sandesh Reddy.



