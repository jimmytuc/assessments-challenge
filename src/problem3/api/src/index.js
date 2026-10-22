const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
  max: 10,
  connectionTimeoutMillis: 5000,
  idleTimeoutMillis: 30000,
});

pool.on("error", (err) => {
  console.error("idle database client error:", err.message);
});

const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });

app.get("/api/users", async (req, res) => {
  const db = await pool.connect();
  try {
    const result = await db.query("SELECT NOW()");
    await redis.set("last_call", Date.now());
    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ ok: false, error: err.message });
  } finally {
    db.release();
  }
});

app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

const server = app.listen(3000, () => console.log("API running on 3000"));

process.on("SIGTERM", () => {
  console.log("SIGTERM received, shutting down");
  server.close(() => {
    redis.disconnect();
    pool.end().then(() => process.exit(0));
  });
});
