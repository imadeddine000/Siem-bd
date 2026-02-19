const express = require("express");
const path = require("path");
const os = require("os");
const sqlite3 = require("sqlite3").verbose();
const expressLayouts = require("express-ejs-layouts");
const fs = require("fs");

const app = express();
const PORT = 3000;

// ----------------------
// SQLite DB
// ----------------------
const db = new sqlite3.Database("./agents.db", (err) => {
  if (err) console.error(err.message);
  else console.log("✅ Connected to SQLite database");
});

// Create agents table if not exists
db.run(`
  CREATE TABLE IF NOT EXISTS agents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_ip TEXT UNIQUE,
    hostname TEXT,
    os TEXT,
    version TEXT,
    arch TEXT,
    registeredAt TEXT,
    lastHeartbeat TEXT
  )
`);

// ----------------------
// Express setup
// ----------------------
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, "public")));
app.use(expressLayouts);

app.set("view engine", "ejs");
app.set("views", path.join(__dirname, "views"));
app.set("layout", "layouts/main");

// ----------------------
// Helpers
// ----------------------
function getPrivateIP() {
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (net.family === "IPv4" && !net.internal) return net.address;
    }
  }
  return "UNKNOWN";
}

const HOST_IP = getPrivateIP();

// ----------------------
// Routes
// ----------------------

// Dashboard
app.get("/", (req, res) => {
  db.all("SELECT * FROM agents", [], (err, agents) => {
    if (err) console.error(err);
    res.render("dashboard", { hostIp: HOST_IP, agents, title: "Dashboard" });
  });
});

// Serve setup.sh dynamically
app.get("/setup.sh", (req, res) => {
  res.setHeader("Content-Type", "text/plain");
  const script = fs.readFileSync("./scripts/setup.sh", "utf8");
  res.send(script.replace("__COLLECTOR_IP__", HOST_IP));
});

// Agent registration
app.post("/agent-register", (req, res) => {
  const { agent_ip, hostname, os, version, arch } = req.body;
  const now = new Date().toISOString();

  db.run(
    `INSERT INTO agents(agent_ip, hostname, os, version, arch, registeredAt, lastHeartbeat)
     VALUES(?,?,?,?,?,?,?)
     ON CONFLICT(agent_ip) DO UPDATE SET lastHeartbeat=excluded.lastHeartbeat`,
    [agent_ip, hostname, os, version, arch, now, now],
    function (err) {
      if (err) console.error(err.message);
      else console.log(`✅ Agent registered/heartbeat: ${hostname} (${agent_ip})`);
      res.json({ status: "ok" });
    }
  );
});

// Agent heartbeat endpoint
app.post("/agent-heartbeat", (req, res) => {
  const { agent_ip } = req.body;
  const now = new Date().toISOString();
  console.log('hearbit received')
  db.run(
    `UPDATE agents SET lastHeartbeat = ? WHERE agent_ip = ?`,
    [now, agent_ip],
    function (err) {
      if (err) console.error(err.message);
      res.json({ status: "ok" });
    }
  );
	console.log("hearbit saved in db")
});

// ----------------------
// Start server
// ----------------------
app.listen(PORT, () => {
  console.log(`✅ Collector running on http://${HOST_IP}:${PORT}`);
});

