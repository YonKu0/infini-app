import os
import uuid
import time
import logging
import sqlite3
from datetime import datetime
from flask import Flask, request, jsonify
from prometheus_client import Counter, Histogram, generate_latest, REGISTRY

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP Requests', ['method', 'endpoint', 'status'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'HTTP request latency', ['endpoint'])

def get_db_connection():
    db_path = os.environ['DB_PATH']
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db_connection()
    conn.execute('''
    CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        price REAL NOT NULL,
        created_at TEXT NOT NULL
    )
    ''')
    conn.commit()
    conn.close()
    logger.info("Database initialized")

@app.before_request
def before_request():
    request.start_time = time.time()

@app.after_request
def after_request(response):
    request_latency = time.time() - request.start_time
    REQUEST_COUNT.labels(request.method, request.path, response.status_code).inc()
    REQUEST_LATENCY.labels(request.path).observe(request_latency)
    return response

@app.errorhandler(400)
def bad_request(error):
    return jsonify({
        'error': 'Bad request',
        'message': str(error.description) if error.description else None
    }), 400

@app.errorhandler(404)
def not_found(error):
    return jsonify({
        'error': 'Not found',
        'message': str(error.description) if error.description else None
    }), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({
        'error': 'Internal server error',
        'message': str(error.description) if error.description else None
    }), 500

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "healthy", "timestamp": datetime.now().isoformat()})

@app.route('/metrics', methods=['GET'])
def metrics():
    return generate_latest(REGISTRY), 200, {'Content-Type': 'text/plain'}

@app.route('/api/items', methods=['GET'])
def get_items():
    conn = get_db_connection()
    items = conn.execute('SELECT * FROM items').fetchall()
    conn.close()
    return jsonify([dict(item) for item in items])

@app.route('/api/items', methods=['POST'])
def create_item():
    if not request.is_json:
        return jsonify({"error": "Request must be JSON"}), 400
    data = request.get_json()
    if not all(k in data for k in ('name', 'quantity', 'price')):
        return jsonify({"error": "Missing required fields"}), 400
    item_id = str(uuid.uuid4())
    created_at = datetime.now().isoformat()
    conn = get_db_connection()
    conn.execute(
        'INSERT INTO items (id, name, quantity, price, created_at) VALUES (?, ?, ?, ?, ?)',
        (item_id, data['name'], data['quantity'], data['price'], created_at)
    )
    conn.commit()
    conn.close()
    logger.info(f"Created new item with ID: {item_id}")
    return jsonify({"id": item_id, "created_at": created_at}), 201

@app.route('/api/items/<item_id>', methods=['GET'])
def get_item(item_id):
    conn = get_db_connection()
    item = conn.execute('SELECT * FROM items WHERE id = ?', (item_id,)).fetchone()
    conn.close()
    if item is None:
        return jsonify({"error": "Item not found"}), 404
    return jsonify(dict(item))

@app.route('/api/items/<item_id>', methods=['DELETE'])
def delete_item(item_id):
    conn = get_db_connection()
    item = conn.execute('SELECT id FROM items WHERE id = ?', (item_id,)).fetchone()
    if item is None:
        conn.close()
        return jsonify({"error": "Item not found"}), 404
    conn.execute('DELETE FROM items WHERE id = ?', (item_id,))
    conn.commit()
    conn.close()
    logger.info(f"Deleted item with ID: {item_id}")
    return '', 204

if __name__ == '__main__':
    host = os.environ['HOST']
    port = int(os.environ['PORT'])
    debug = os.environ['DEBUG'].lower() == 'true'
    init_db()
    app.run(host=host, port=port, debug=debug)