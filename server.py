"""
GradeVault — Flask Backend
Run: python server.py
Requires: pip install flask flask-cors
Data stored in: data.db (SQLite, auto-created)
"""

import sqlite3
import secrets
import hashlib
import json
import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, send_from_directory, abort
from flask_cors import CORS

app = Flask(__name__, static_folder=".")
CORS(app, supports_credentials=True)

DB_PATH = "data.db"
TOKEN_EXPIRY_HOURS = 72

# ── Default empty semester structure ─────────────────────────
SEMS = ["y1s1","y1s2","y2s1","y2s2","y3s1","y3s2","y4s1","y4s2","y5s1","y5s2"]

def empty_semesters():
    return {s: [] for s in SEMS}


# ── Database setup ────────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL COLLATE NOCASE,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                token TEXT PRIMARY KEY,
                user_id INTEGER NOT NULL,
                expires_at TEXT NOT NULL,
                FOREIGN KEY(user_id) REFERENCES users(id)
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS gpa_data (
                user_id INTEGER PRIMARY KEY,
                semesters TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(user_id) REFERENCES users(id)
            )
        """)
        db.commit()

init_db()


# ── Auth helpers ──────────────────────────────────────────────
def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()

def make_token() -> str:
    return secrets.token_hex(32)

def get_user_from_token(token: str):
    if not token:
        return None
    with get_db() as db:
        row = db.execute("""
            SELECT u.id, u.username
            FROM sessions s JOIN users u ON s.user_id = u.id
            WHERE s.token = ? AND s.expires_at > ?
        """, (token, datetime.utcnow().isoformat())).fetchone()
    return dict(row) if row else None

def require_auth():
    token = request.headers.get("X-Auth-Token") or request.cookies.get("token")
    user = get_user_from_token(token)
    if not user:
        abort(401, description="Unauthorized")
    return user


# ── Routes: Auth ──────────────────────────────────────────────
@app.route("/api/register", methods=["POST"])
def register():
    body = request.get_json(silent=True) or {}
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""

    if not username or len(username) < 2:
        return jsonify(error="Username must be at least 2 characters"), 400
    if len(username) > 32:
        return jsonify(error="Username too long (max 32 chars)"), 400
    if not password or len(password) < 4:
        return jsonify(error="Password must be at least 4 characters"), 400

    pw_hash = hash_password(password)
    try:
        with get_db() as db:
            cur = db.execute(
                "INSERT INTO users (username, password_hash, created_at) VALUES (?,?,?)",
                (username, pw_hash, datetime.utcnow().isoformat())
            )
            user_id = cur.lastrowid
            # Initialise empty GPA data
            db.execute(
                "INSERT INTO gpa_data (user_id, semesters, updated_at) VALUES (?,?,?)",
                (user_id, json.dumps(empty_semesters()), datetime.utcnow().isoformat())
            )
            db.commit()
    except sqlite3.IntegrityError:
        return jsonify(error="Username already taken"), 409

    token = _create_session(user_id)
    return jsonify(token=token, username=username), 201


@app.route("/api/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""

    if not username or not password:
        return jsonify(error="Username and password required"), 400

    pw_hash = hash_password(password)
    with get_db() as db:
        row = db.execute(
            "SELECT id, username FROM users WHERE username = ? AND password_hash = ?",
            (username, pw_hash)
        ).fetchone()

    if not row:
        return jsonify(error="Invalid username or password"), 401

    token = _create_session(row["id"])
    return jsonify(token=token, username=row["username"]), 200


@app.route("/api/logout", methods=["POST"])
def logout():
    token = request.headers.get("X-Auth-Token") or request.cookies.get("token")
    if token:
        with get_db() as db:
            db.execute("DELETE FROM sessions WHERE token = ?", (token,))
            db.commit()
    return jsonify(ok=True)


def _create_session(user_id: int) -> str:
    token = make_token()
    expires = (datetime.utcnow() + timedelta(hours=TOKEN_EXPIRY_HOURS)).isoformat()
    with get_db() as db:
        db.execute(
            "INSERT INTO sessions (token, user_id, expires_at) VALUES (?,?,?)",
            (token, user_id, expires)
        )
        db.commit()
    return token


# ── Routes: GPA Data ──────────────────────────────────────────
@app.route("/api/data", methods=["GET"])
def get_data():
    user = require_auth()
    with get_db() as db:
        row = db.execute(
            "SELECT semesters FROM gpa_data WHERE user_id = ?", (user["id"],)
        ).fetchone()

    if not row:
        semesters = empty_semesters()
    else:
        semesters = json.loads(row["semesters"])
        # Ensure all semesters exist (in case schema expanded)
        for s in SEMS:
            if s not in semesters:
                semesters[s] = []

    return jsonify(username=user["username"], semesters=semesters)


@app.route("/api/data", methods=["PUT"])
def save_data():
    user = require_auth()
    body = request.get_json(silent=True) or {}
    semesters = body.get("semesters")
    if not isinstance(semesters, dict):
        return jsonify(error="Invalid data"), 400

    # Sanitise: only keep known semesters
    clean = {s: semesters.get(s, []) for s in SEMS}

    with get_db() as db:
        db.execute("""
            INSERT INTO gpa_data (user_id, semesters, updated_at)
            VALUES (?,?,?)
            ON CONFLICT(user_id) DO UPDATE SET
                semesters = excluded.semesters,
                updated_at = excluded.updated_at
        """, (user["id"], json.dumps(clean), datetime.utcnow().isoformat()))
        db.commit()

    return jsonify(ok=True)


# ── Serve frontend ────────────────────────────────────────────
@app.route("/")
def index():
    return send_from_directory(".", "index.html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"GradeVault running → http://localhost:{port}")
    app.run(debug=True, port=port)
