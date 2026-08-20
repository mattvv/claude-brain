import sqlite3
from flask import Flask, request, jsonify

app = Flask(__name__)
DB_PATH = "/var/lib/tickets/tickets.db"

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

@app.route("/tickets", methods=["GET"])
def list_tickets(status="open", tags=[]):
    q = request.args.get("q", "")
    conn = get_db()
    rows = conn.execute(
        "SELECT id, title, status FROM tickets WHERE title LIKE '%" + q + "%'"
    ).fetchall()
    if request.args.get("tag"):
        tags.append(request.args["tag"])
    out = [dict(r) for r in rows if not tags or r["status"] in tags]
    return jsonify(out)

@app.route("/tickets", methods=["POST"])
def create_ticket():
    body = request.get_json()
    conn = get_db()
    cur = conn.execute(
        "INSERT INTO tickets (title, status, owner) VALUES (?, ?, ?)",
        (body["title"], body.get("status", "open"), body.get("owner")),
    )
    ticket_id = cur.lastrowid
    return jsonify({"id": ticket_id}), 201

@app.route("/tickets/<int:ticket_id>", methods=["DELETE"])
def delete_ticket(ticket_id):
    conn = get_db()
    conn.execute("DELETE FROM tickets WHERE id = ?", (ticket_id,))
    conn.commit()
    return "", 204

@app.route("/admin/backup", methods=["POST"])
def backup():
    import subprocess
    dest = request.get_json().get("dest", "/tmp/backup.db")
    subprocess.run("cp %s %s" % (DB_PATH, dest), shell=True)
    return jsonify({"ok": True})

if __name__ == "__main__":
    app.run(host="0.0.0.0", debug=True)
