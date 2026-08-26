// OmarchWeb — JS helpers: parsing script output into view models.

// Parse `services.sh status` output: "name kind state substate" per line.
function parseServiceStatus(raw, known) {
  // known: [{ key, name, icon, kind }...]
  var lines = String(raw).split("\n")
  var state = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split(/\s+/)
    if (parts.length < 3) continue
    var svc = parts[0]
    var kind = parts[1]
    var active = parts[2]
    var sub = parts.length > 3 ? parts[3] : ""
    state[svc] = { key: svc, kind: kind, state: active, sub: sub }
  }
  var out = []
  for (var j = 0; j < known.length; j++) {
    var k = known[j]
    var s = state[k.key]
    if (s) {
      out.push({
        key: k.key,
        name: k.name,
        icon: k.icon,
        installed: s.kind !== "none",
        running: s.state === "active",
        state: s.state,
        sub: s.sub,
        url: k.url || ""
      })
    } else {
      out.push({
        key: k.key, name: k.name, icon: k.icon,
        installed: false, running: false, state: "unknown", sub: "",
        url: k.url || ""
      })
    }
  }
  return out
}

// Parse `db.sh list` output:
//   STATUS <engine> <ok|down|missing|denied|no-role|error>
//   <engine>|<name>
function parseDbList(raw) {
  var lines = String(raw).split("\n")
  var databases = []
  var users = []
  var access = { mariadb: "", postgresql: "" }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (line.indexOf("STATUS ") === 0) {
      var st = line.split(/\s+/)
      if (st.length >= 3) access[st[1]] = st[2]
      continue
    }
    if (line.indexOf("USER ") === 0) {
      var u = line.substring(5).split("|")
      if (u.length >= 2)
        users.push({ engine: u[0], name: u[1], auth: u[2] || "password" })
      continue
    }
    var p = line.split("|")
    if (p.length >= 2)
      databases.push({ engine: p[0], name: p[1] })
    else
      databases.push({ engine: "mariadb", name: line })
  }
  return { databases: databases, users: users, access: access }
}

function parseDatabases(raw) {
  return parseDbList(raw).databases
}

// Parse `vhost.sh list` output: "name|type|host|root" per line.
function parseVhosts(raw) {
  var lines = String(raw).split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var p = line.split("|")
    if (p.length < 2) continue
    out.push({ name: p[0], type: p[1], host: p[2] || "", root: p[3] || "" })
  }
  return out
}

// Strip ANSI color codes.
function clean(text) {
  return String(text).replace(/\u001b\[[0-9;]*m/g, "")
}
