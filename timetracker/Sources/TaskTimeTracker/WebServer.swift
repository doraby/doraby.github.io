import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal HTTP server bound to 127.0.0.1 only.
/// Serves the HTML dashboard and a small JSON API so the browser UI
/// can read/write task data and view screenshots — all local, no network.
final class WebServer {
    private let store: Store
    private var serverFD: Int32 = -1
    private var running = false
    private(set) var actualPort: UInt16 = 0

    init(store: Store) {
        self.store = store
    }

    @discardableResult
    func start(preferredPort: UInt16 = 8384) -> Bool {
        for p in stride(from: preferredPort, through: preferredPort + 10, by: 1) {
            if tryBind(port: UInt16(p)) {
                actualPort = UInt16(p)
                running = true
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.acceptLoop()
                }
                return true
            }
        }
        return false
    }

    func stop() {
        running = false
        if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
    }

    // MARK: - Socket setup

    private func tryBind(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                          socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian   // 127.0.0.1
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); return false }

        Darwin.listen(fd, 8)
        serverFD = fd
        return true
    }

    private func acceptLoop() {
        while running {
            let client = Darwin.accept(serverFD, nil, nil)
            guard client >= 0 else { if !running { break }; continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    // MARK: - Request handling

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }

        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return }

        let raw = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        let resp = route(raw)
        resp.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < ptr.count {
                let w = Darwin.write(fd, base.advanced(by: sent), ptr.count - sent)
                if w <= 0 { break }
                sent += w
            }
        }
    }

    private func route(_ raw: String) -> Data {
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return resp(400, text: "Bad Request") }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return resp(400, text: "Bad Request") }

        let method = String(parts[0])
        let (path, query) = splitPathQuery(String(parts[1]))
        let params = parseQuery(query)

        switch method {
        case "GET":
            if path == "/" { return resp(200, html: dashboardHTML) }
            if path == "/api/entries" { return getEntries(params) }
            if path == "/api/screenshots" { return getScreenshots(params) }
            if path == "/api/categories" { return getCategories() }
            if path.hasPrefix("/shot/") {
                return serveScreenshot(String(path.dropFirst(6)))
            }
            return resp(404, text: "Not Found")

        case "PUT":
            if path == "/api/categories" {
                return putCategory(extractBody(raw))
            }
            if path == "/api/groups" {
                return putGroup(params, extractBody(raw))
            }
            let prefix = "/api/entries/"
            guard path.hasPrefix(prefix) else { return resp(404, text: "Not Found") }
            return putEntry(String(path.dropFirst(prefix.count)), params, extractBody(raw))

        case "DELETE":
            if path == "/api/groups" {
                return deleteGroup(extractBody(raw))
            }
            let prefix = "/api/entries/"
            guard path.hasPrefix(prefix) else { return resp(404, text: "Not Found") }
            return deleteEntry(String(path.dropFirst(prefix.count)), params)

        case "OPTIONS":
            return resp(200, text: "OK")

        default:
            return resp(405, text: "Method Not Allowed")
        }
    }

    // MARK: - API handlers

    private func getEntries(_ p: [String: String]) -> Data {
        guard let dk = p["date"] else { return resp(400, text: "Missing date") }
        let entries = store.entriesFor(dateKey: dk)
        let iso = ISO8601DateFormatter()

        func chunkJSON(_ e: TaskEntry) -> [String: Any] {
            ["id": e.id.uuidString, "appName": e.appName,
             "windowTitle": e.windowTitle, "url": e.url, "domain": e.domain,
             "start": iso.string(from: e.start),
             "end": iso.string(from: e.end),
             "duration": e.duration]
        }

        let dayShots = store.screenshotsFor(dateKey: dk)

        // Same-titled blocks (e.g. from a rules.json match, or matching
        // "App — window") are combined into one task with its blocks kept
        // as expandable "chunks" — this is what merges scattered Chrome /
        // Terminal / Xcode blocks for the same activity into a single row.
        let groups = groupTasks(entries).map { g -> [String: Any] in
            let shots = screenshotsForGroup(g, in: dayShots).map { s -> [String: Any] in
                ["url": "/shot/\(dk)/\(s.url.lastPathComponent)",
                 "timestamp": iso.string(from: s.timestamp)]
            }
            return ["title": g.title, "details": g.details,
             "start": iso.string(from: g.start), "end": iso.string(from: g.end),
             "duration": g.duration, "dominantApp": g.dominantApp,
             "appsUsed": g.appsUsed,
             "chunks": g.chunks.map(chunkJSON),
             "screenshots": shots]
        }

        var totals: [String: TimeInterval] = [:]
        for e in entries { totals[e.displayAppName, default: 0] += e.duration }
        let appTotals = totals.map { ["app": $0.key, "total": $0.value] as [String: Any] }
            .sorted { ($0["total"] as! TimeInterval) > ($1["total"] as! TimeInterval) }

        var catTotals: [String: TimeInterval] = [:]
        for e in entries {
            let cat = store.categoryFor(domain: e.domain)
            if !cat.isEmpty { catTotals[cat, default: 0] += e.duration }
        }
        let categoryTotals = catTotals.map { ["category": $0.key, "total": $0.value] as [String: Any] }
            .sorted { ($0["total"] as! TimeInterval) > ($1["total"] as! TimeInterval) }

        let json: [String: Any] = [
            "groups": groups,
            "appTotals": appTotals,
            "categoryTotals": categoryTotals,
            "dayTotal": entries.reduce(0.0) { $0 + $1.duration },
            "taskCount": groups.count
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            return resp(500, text: "JSON error")
        }
        return resp(200, json: data)
    }

    private func getScreenshots(_ p: [String: String]) -> Data {
        guard let dk = p["date"] else { return resp(400, text: "Missing date") }
        let dir = Store.screenshotsDirectory.appendingPathComponent(dk, isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else {
            return resp(200, json: try! JSONSerialization.data(withJSONObject: [Any]()))
        }

        let items: [[String: String]] = files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { ["filename": $0.lastPathComponent, "url": "/shot/\(dk)/\($0.lastPathComponent)"] }
            .sorted { ($0["filename"] ?? "") < ($1["filename"] ?? "") }

        guard let data = try? JSONSerialization.data(withJSONObject: items) else {
            return resp(500, text: "JSON error")
        }
        return resp(200, json: data)
    }

    private func putEntry(_ idStr: String, _ p: [String: String], _ body: String) -> Data {
        guard let dk = p["date"],
              let uuid = UUID(uuidString: idStr),
              let bd = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any] else {
            return resp(400, text: "Invalid request")
        }
        let title = obj["title"] as? String ?? ""
        let details = obj["details"] as? String ?? ""
        return store.updateEntryFor(dateKey: dk, id: uuid, title: title, details: details)
            ? resp(200, text: "OK") : resp(404, text: "Not found")
    }

    private func deleteEntry(_ idStr: String, _ p: [String: String]) -> Data {
        guard let dk = p["date"], let uuid = UUID(uuidString: idStr) else {
            return resp(400, text: "Invalid request")
        }
        return store.deleteEntryFor(dateKey: dk, id: uuid)
            ? resp(200, text: "OK") : resp(404, text: "Not found")
    }

    private func putGroup(_ p: [String: String], _ body: String) -> Data {
        guard let dk = p["date"],
              let bd = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any],
              let idStrs = obj["ids"] as? [String],
              let newTitle = obj["title"] as? String, !newTitle.isEmpty else {
            return resp(400, text: "Invalid request")
        }
        let ids = idStrs.compactMap { UUID(uuidString: $0) }
        let details = obj["details"] as? String ?? ""
        return store.renameGroupFor(dateKey: dk, ids: ids, newTitle: newTitle, details: details)
            ? resp(200, text: "OK") : resp(404, text: "Not found")
    }

    private func deleteGroup(_ body: String) -> Data {
        guard let bd = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any],
              let dk = obj["date"] as? String,
              let idStrs = obj["ids"] as? [String] else {
            return resp(400, text: "Invalid request")
        }
        let ids = idStrs.compactMap { UUID(uuidString: $0) }
        return store.deleteGroupFor(dateKey: dk, ids: ids)
            ? resp(200, text: "OK") : resp(404, text: "Not found")
    }

    private func getCategories() -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "categories": store.categories,
            "available": Store.availableCategories
        ]) else { return resp(500, text: "JSON error") }
        return resp(200, json: data)
    }

    private func putCategory(_ body: String) -> Data {
        guard let bd = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any],
              let domain = obj["domain"] as? String else {
            return resp(400, text: "Invalid request")
        }
        let category = obj["category"] as? String ?? ""
        store.setCategory(domain: domain, category: category)
        return resp(200, text: "OK")
    }

    private func serveScreenshot(_ path: String) -> Data {
        let clean = path.filter { $0.isLetter || $0.isNumber || "-./".contains($0) }
        guard !clean.contains("..") else { return resp(403, text: "Forbidden") }
        let url = Store.screenshotsDirectory.appendingPathComponent(clean)
        guard let data = try? Data(contentsOf: url) else { return resp(404, text: "Not found") }
        return resp(200, binary: data, type: "image/jpeg")
    }

    // MARK: - HTTP response builders

    private func resp(_ code: Int, text: String) -> Data {
        build(code: code, type: "text/plain; charset=utf-8", body: text.data(using: .utf8) ?? Data())
    }
    private func resp(_ code: Int, html: String) -> Data {
        build(code: code, type: "text/html; charset=utf-8", body: html.data(using: .utf8) ?? Data())
    }
    private func resp(_ code: Int, json: Data) -> Data {
        build(code: code, type: "application/json", body: json)
    }
    private func resp(_ code: Int, binary: Data, type: String) -> Data {
        build(code: code, type: type, body: binary)
    }

    private func build(code: Int, type: String, body: Data) -> Data {
        let status: String
        switch code {
        case 200: status = "OK"
        case 400: status = "Bad Request"
        case 403: status = "Forbidden"
        case 404: status = "Not Found"
        case 405: status = "Method Not Allowed"
        default:  status = "Error"
        }
        let header = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = header.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }

    // MARK: - Parse helpers

    private func splitPathQuery(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: "?") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private func parseQuery(_ q: String) -> [String: String] {
        guard !q.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return out
    }

    private func extractBody(_ raw: String) -> String {
        guard let r = raw.range(of: "\r\n\r\n") else { return "" }
        return String(raw[r.upperBound...])
    }
}

// MARK: - Dashboard HTML

private let dashboardHTML = ##"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Task Time Tracker</title>
<style>
:root {
    --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --sec: #86868b;
    --accent: #0071e3; --border: #d2d2d7; --hover: #f0f0f2;
    --radius: 10px; --shadow: 0 1px 3px rgba(0,0,0,.08);
}
@media(prefers-color-scheme:dark){:root{
    --bg:#1c1c1e;--card:#2c2c2e;--text:#f5f5f7;--sec:#98989d;
    --accent:#0a84ff;--border:#3a3a3c;--hover:#3a3a3c;
    --shadow:0 1px 3px rgba(0,0,0,.3);
}}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;
     background:var(--bg);color:var(--text);line-height:1.5}
.wrap{max-width:900px;margin:0 auto;padding:20px}

/* ---- header ---- */
.hdr{display:flex;align-items:center;gap:12px;padding:16px 0;
     border-bottom:1px solid var(--border);margin-bottom:20px}
.hdr h1{font-size:20px;font-weight:600}
.hdr .sp{flex:1}
.hdr .tot{font-size:15px;color:var(--sec);font-variant-numeric:tabular-nums}
.nb{background:none;border:none;cursor:pointer;font-size:18px;
    color:var(--text);padding:4px 8px;border-radius:6px}
.nb:hover{background:var(--hover)}
input[type=date]{font-size:14px;padding:4px 8px;border:1px solid var(--border);
    border-radius:6px;background:var(--card);color:var(--text)}

/* ---- tabs ---- */
.tabs{display:flex;gap:0;border-bottom:1px solid var(--border);margin-bottom:20px}
.tab{padding:10px 20px;cursor:pointer;border:none;background:none;font-size:14px;
     font-weight:500;color:var(--sec);border-bottom:2px solid transparent;transition:.2s}
.tab:hover{color:var(--text)}
.tab.on{color:var(--accent);border-bottom-color:var(--accent)}
.tc{display:none}.tc.on{display:block}

/* ---- tasks ---- */
.card{background:var(--card);border-radius:var(--radius);padding:14px 16px;
      margin-bottom:10px;box-shadow:var(--shadow);display:flex;gap:12px}
.card .ac{width:4px;border-radius:2px;flex-shrink:0}
.card .bd{flex:1;min-width:0}
.card .hd{display:flex;align-items:center;gap:8px;margin-bottom:4px}
.card .ti{flex:1;font-size:15px;font-weight:500;border:none;background:none;
           color:var(--text);outline:none;padding:2px 0;font-family:inherit;width:100%}
.card .ti:focus{border-bottom:1px solid var(--accent)}
.card .dur{font-size:13px;color:var(--sec);font-variant-numeric:tabular-nums;
           background:var(--bg);padding:2px 8px;border-radius:4px;white-space:nowrap}
.card .del{background:none;border:none;cursor:pointer;color:var(--sec);
           font-size:16px;padding:2px 6px;border-radius:4px;line-height:1}
.card .del:hover{background:#ff3b3020;color:#ff3b30}
.card .de{font-size:14px;color:var(--sec);border:none;background:none;width:100%;
          outline:none;padding:2px 0;font-family:inherit}
.card .de:focus{border-bottom:1px solid var(--accent)}
.card .meta{font-size:12px;color:var(--sec);margin-top:4px}

/* ---- screenshots ---- */
.sg{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:16px}
.sc{cursor:pointer;text-align:center}
.sc img{width:100%;height:130px;object-fit:cover;border-radius:8px;
        box-shadow:var(--shadow);transition:transform .2s}
.sc img:hover{transform:scale(1.03)}
.sc .t{font-size:12px;color:var(--sec);margin-top:6px}

/* lightbox */
.lb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.85);
    z-index:100;justify-content:center;align-items:center;padding:40px}
.lb.on{display:flex}
.lb img{max-width:100%;max-height:100%;object-fit:contain;border-radius:8px}
.lb .x{position:absolute;top:16px;right:16px;background:rgba(255,255,255,.2);
       border:none;color:#fff;font-size:24px;width:40px;height:40px;
       border-radius:20px;cursor:pointer}

/* ---- stats ---- */
.sr{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:24px}
.scard{background:var(--card);border-radius:var(--radius);padding:16px;
       text-align:center;box-shadow:var(--shadow)}
.sv{font-size:24px;font-weight:700;font-variant-numeric:tabular-nums;color:var(--accent)}
.sl{font-size:13px;color:var(--sec);margin-top:2px}
.st{font-size:16px;font-weight:600;margin-bottom:12px}
.br{display:flex;align-items:center;gap:8px;margin-bottom:6px;height:28px}
.br .dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.br .lbl{width:130px;font-size:14px;overflow:hidden;text-overflow:ellipsis;
         white-space:nowrap;flex-shrink:0}
.br .trk{flex:1;height:20px;background:var(--bg);border-radius:3px;overflow:hidden}
.br .fill{height:100%;border-radius:3px;min-width:4px;transition:width .3s}
.br .val{width:80px;font-size:14px;font-variant-numeric:tabular-nums;
         color:var(--sec);text-align:right;flex-shrink:0}
.tl-track{height:28px;background:var(--bg);border-radius:4px;position:relative;
          overflow:hidden;margin-bottom:4px}
.tl-block{position:absolute;top:2px;bottom:2px;border-radius:3px;min-width:2px}
.tl-hrs{display:flex;justify-content:space-between;font-size:11px;color:var(--sec)}
.empty{text-align:center;padding:60px 20px;color:var(--sec)}
.empty .ico{font-size:36px;margin-bottom:8px}
.cat-badge{font-size:11px;padding:1px 7px;border-radius:9px;color:#fff;
           font-weight:500;white-space:nowrap}
.cat-sel{font-size:12px;padding:1px 4px;border:1px solid var(--border);
         border-radius:4px;background:var(--card);color:var(--text);cursor:pointer}
.chunk-toggle{background:none;border:none;cursor:pointer;color:var(--accent);
       font-size:12px;padding:2px 0;font-family:inherit}
.chunks{display:none;margin-top:8px;padding-top:8px;border-top:1px solid var(--border)}
.chunks.on{display:block}
.chunk{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--sec);
       padding:3px 0}
.chunk .dot{width:6px;height:6px;border-radius:50%;flex-shrink:0}
.chunk .lbl{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chunk .dur{font-variant-numeric:tabular-nums;flex-shrink:0}
.chunk .cx{background:none;border:none;cursor:pointer;color:var(--sec);
       font-size:13px;padding:0 4px;flex-shrink:0}
.chunk .cx:hover{color:#ff3b30}
.shots{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}
.shots img{width:64px;height:44px;object-fit:cover;border-radius:5px;cursor:pointer;
       box-shadow:var(--shadow);transition:transform .15s}
.shots img:hover{transform:scale(1.06)}
</style>
</head>
<body>
<div class="wrap">
  <div class="hdr">
    <button class="nb" onclick="shiftDay(-1)">&lsaquo;</button>
    <input type="date" id="dp" onchange="loadDay(this.value)">
    <button class="nb" onclick="shiftDay(1)">&rsaquo;</button>
    <h1 id="dl"></h1>
    <div class="sp"></div>
    <div class="tot" id="tot"></div>
  </div>
  <div class="tabs">
    <button class="tab on" data-t="tasks">Tasks</button>
    <button class="tab" data-t="shots">Screenshots</button>
    <button class="tab" data-t="stats">Statistics</button>
  </div>
  <div class="tc on" id="tc-tasks"></div>
  <div class="tc" id="tc-shots"></div>
  <div class="tc" id="tc-stats"></div>
</div>
<div class="lb" id="lb" onclick="closeLB()">
  <button class="x" onclick="closeLB()">&times;</button>
  <img id="lbi" src="">
</div>
<script>
let cur=new Date(),data={groups:[],appTotals:[],categoryTotals:[],dayTotal:0},shots=[];
const P=['#007AFF','#34C759','#FF9500','#AF52DE','#FF2D55','#5AC8FA',
         '#5856D6','#00C7BE','#32ADE6','#A2845E','#FF3B30','#FFD60A'];
function colr(n){let h=0;for(let i=0;i<n.length;i++)h=(h+n.charCodeAt(i))*31;return P[Math.abs(h)%P.length]}
function fmt(s){s=Math.floor(s);const h=Math.floor(s/3600),m=Math.floor(s%3600/60);
  if(h>0)return h+'h '+String(m).padStart(2,'0')+'m';
  if(m>0)return m+'m '+String(s%60).padStart(2,'0')+'s';return s+'s'}
function dk(d){return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')}
function dlbl(d){return d.toLocaleDateString(undefined,{weekday:'long',year:'numeric',month:'long',day:'numeric'})}
function esc(s){return(s||'').replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}

// tabs
document.querySelector('.tabs').addEventListener('click',e=>{
  const b=e.target.closest('.tab');if(!b)return;
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('on'));
  document.querySelectorAll('.tc').forEach(t=>t.classList.remove('on'));
  b.classList.add('on');
  document.getElementById('tc-'+b.dataset.t).classList.add('on');
});

function shiftDay(n){cur.setDate(cur.getDate()+n);loadDay(dk(cur))}

function loadDay(key){
  if(key){const p=key.split('-');cur=new Date(+p[0],+p[1]-1,+p[2])}
  document.getElementById('dp').value=dk(cur);
  document.getElementById('dl').textContent=dlbl(cur);
  fetch('/api/entries?date='+dk(cur)).then(r=>r.json()).then(d=>{data=d;renderTasks();renderStats()});
  fetch('/api/screenshots?date='+dk(cur)).then(r=>r.json()).then(d=>{shots=d;renderShots()});
}

// All chunks across all groups, for stats that look at raw blocks.
function allChunks(){return(data.groups||[]).flatMap(g=>g.chunks)}

// ---- tasks ----
// Each row is a task (grouped by title \u2014 several Chrome/Terminal/Xcode
// blocks for the same activity become one row) with its blocks listed
// underneath as expandable chunks.
function renderTasks(){
  const el=document.getElementById('tc-tasks');
  document.getElementById('tot').textContent='Total: '+fmt(data.dayTotal);
  if(!data.groups||!data.groups.length){
    el.innerHTML='<div class="empty"><div class="ico">&#128203;</div>No activity recorded for this day</div>';return}
  const s=[...data.groups].sort((a,b)=>new Date(b.end)-new Date(a.end));
  el.innerHTML=s.map((g,gi)=>{
    const c=colr(g.dominantApp),
          st=new Date(g.start).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}),
          et=new Date(g.end).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}),
          n=g.chunks.length,
          chunkRows=g.chunks.map(ch=>{
            const label=ch.domain||ch.windowTitle||ch.appName,
                  cst=new Date(ch.start).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}),
                  cet=new Date(ch.end).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
            return `<div class="chunk"><div class="dot" style="background:${colr(ch.appName)}"></div>
              <div class="lbl">${esc(ch.appName)}${label&&label!==ch.appName?' \u2014 '+esc(label):''} \u00b7 ${cst}\u2013${cet}</div>
              <div class="dur">${fmt(ch.duration)}</div>
              <button class="cx" onclick="delChunk('${ch.id}')" title="Remove this block">&times;</button></div>`
          }).join('');
    const shots=g.screenshots||[],
          shotStrip=shots.length?`<div class="shots">${shots.map(s=>
            `<img src="${s.url}" loading="lazy" onclick="openLB('${s.url}')" title="${new Date(s.timestamp).toLocaleTimeString([],{hour:'numeric',minute:'2-digit',second:'2-digit'})}">`
          ).join('')}</div>`:'';
    return `<div class="card"><div class="ac" style="background:${c}"></div><div class="bd">
      <div class="hd">
        <input class="ti" value="${esc(g.title)}" onchange="saveGroup(${gi},this.value,null)" onkeydown="if(event.key==='Enter')this.blur()">
        <span class="dur">${fmt(g.duration)}</span>
        <button class="del" onclick="delGroup(${gi})" title="Delete task">&times;</button>
      </div>
      <input class="de" value="${esc(g.details)}" placeholder="Add description\u2026" onchange="saveGroup(${gi},null,this.value)" onkeydown="if(event.key==='Enter')this.blur()">
      <div class="meta">${esc((g.appsUsed||[]).join(', '))} \u00b7 ${n} block${n===1?'':'s'} \u00b7 ${st} \u2013 ${et}
        ${n>1?`<button class="chunk-toggle" onclick="this.closest('.bd').querySelector('.chunks').classList.toggle('on')">show blocks</button>`:''}
        ${shots.length?`<span>\u00b7 &#128247; ${shots.length}</span>`:''}</div>
      ${n>1?`<div class="chunks">${chunkRows}</div>`:''}
      ${shotStrip}
    </div></div>`}).join('');
}

function saveGroup(gi,newTitle,newDetails){
  const g=data.groups[gi];if(!g)return;
  const title=newTitle!==null?newTitle.trim():g.title;
  if(!title){loadDay();return}   // refuse a blank title — just reload to reset the field
  fetch('/api/groups?date='+dk(cur),{method:'PUT',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({ids:g.chunks.map(c=>c.id),
      title:title,
      details:newDetails!==null?newDetails:g.details})
  }).then(()=>loadDay());
}
function delGroup(gi){const g=data.groups[gi];if(!g)return;
  if(!confirm('Delete this task and all its blocks?'))return;
  fetch('/api/groups',{method:'DELETE',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({date:dk(cur),ids:g.chunks.map(c=>c.id)})}).then(()=>loadDay())}
function delChunk(id){
  fetch('/api/entries/'+id+'?date='+dk(cur),{method:'DELETE'}).then(()=>loadDay())}

// ---- screenshots ----
function renderShots(){
  const el=document.getElementById('tc-shots');
  if(!shots||!shots.length){
    el.innerHTML='<div class="empty"><div class="ico">&#128247;</div>No screenshots for this day<br><small style="color:var(--sec)">Enable screenshots from the menu bar icon</small></div>';return}
  el.innerHTML='<div class="sg">'+shots.map(s=>{
    const n=s.filename.replace('.jpg','');
    let ts=n,ti=ts.indexOf('T');
    if(ti>0){const tp=ts.substring(ti+1).split('-');
      if(tp.length>=3)ts=ts.substring(0,ti+1)+tp[0]+':'+tp[1]+':'+tp.slice(2).join('-')}
    const d=new Date(ts),tl=isNaN(d)?n:d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit',second:'2-digit'});
    return `<div class="sc" onclick="openLB('${s.url}')"><img src="${s.url}" loading="lazy" alt="${tl}"><div class="t">${tl}</div></div>`
  }).join('')+'</div>';
}
function openLB(u){document.getElementById('lbi').src=u;document.getElementById('lb').classList.add('on')}
function closeLB(){document.getElementById('lb').classList.remove('on');document.getElementById('lbi').src=''}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeLB()});

// ---- statistics ----
function renderStats(){
  const el=document.getElementById('tc-stats');
  const chunks=allChunks();
  if(!chunks.length){
    el.innerHTML='<div class="empty"><div class="ico">&#128202;</div>No data for this day</div>';return}
  const ua=new Set(chunks.map(e=>e.appName)).size;
  const taskCount=(data.groups||[]).length;
  let h=`<div class="sr">
    <div class="scard"><div class="sv">${fmt(data.dayTotal)}</div><div class="sl">Tracked</div></div>
    <div class="scard"><div class="sv">${taskCount}</div><div class="sl">${taskCount===1?'Task':'Tasks'}</div></div>
    <div class="scard"><div class="sv">${ua}</div><div class="sl">Apps Used</div></div>
  </div>`;

  h+='<div class="st">Time per Application</div>';
  if(data.appTotals)data.appTotals.forEach(a=>{
    const pct=data.dayTotal>0?(a.total/data.dayTotal*100):0,c=colr(a.app);
    h+=`<div class="br"><div class="dot" style="background:${c}"></div>
      <div class="lbl">${esc(a.app)}</div>
      <div class="trk"><div class="fill" style="width:${pct}%;background:${c}"></div></div>
      <div class="val">${fmt(a.total)}</div></div>`});

  h+='<div class="st" style="margin-top:24px">Activity Timeline</div>';
  const sorted=[...chunks].sort((a,b)=>new Date(a.start)-new Date(b.start));
  if(sorted.length){
    const ear=new Date(sorted[0].start),lat=new Date(sorted[sorted.length-1].end);
    const sH=new Date(ear);sH.setMinutes(0,0,0);
    const eH=new Date(lat);eH.setMinutes(0,0,0);eH.setHours(eH.getHours()+1);
    const ms=eH-sH;
    if(ms>0){
      let bl='';sorted.forEach(e=>{
        const es=new Date(e.start),ee=new Date(e.end),
              l=(es-sH)/ms*100,w=Math.max(.3,(ee-es)/ms*100),c=colr(e.appName);
        bl+=`<div class="tl-block" style="left:${l}%;width:${w}%;background:${c}" title="${esc(e.appName)}\n${fmt(e.duration)}"></div>`});
      h+=`<div class="tl-track">${bl}</div>`;
      const hrs=[];let c=new Date(sH);
      while(c<=eH){hrs.push(new Date(c));c.setHours(c.getHours()+1)}
      let step=1;if(hrs.length>12)step=Math.ceil(hrs.length/8);
      const lb=hrs.filter((_,i)=>i%step===0||i===hrs.length-1);
      h+='<div class="tl-hrs">'+lb.map(d=>`<span>${d.toLocaleTimeString([],{hour:'numeric'}).toLowerCase()}</span>`).join('')+'</div>'
    }
  }
  el.innerHTML=h;
}

loadDay(dk(cur));
</script>
</body>
</html>
"""##
