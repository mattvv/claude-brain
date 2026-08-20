const express = require("express");
const { Pool } = require("pg");
const rateLimit = require("./middleware/rateLimit");

const app = express();
const pool = new Pool({ max: 10, connectionTimeoutMillis: 2000 });

app.use(express.json());
app.use(rateLimit({ windowMs: 60000, max: 120 }));

app.get("/api/items", async (req, res) => {
  const { rows } = await pool.query("SELECT id, name FROM items LIMIT 100");
  res.json(rows);
});

app.post("/api/items", async (req, res) => {
  const { name } = req.body;
  const { rows } = await pool.query(
    "INSERT INTO items (name) VALUES ($1) RETURNING id", [name]);
  res.status(201).json(rows[0]);
});

app.listen(process.env.PORT || 3000);
module.exports = app;
