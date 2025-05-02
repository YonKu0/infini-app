from app import app, init_db

# Ensure the database and table are initialized before the app starts
init_db()