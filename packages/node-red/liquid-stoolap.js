"use strict";

module.exports = function registerLiquidStoolap(RED) {
  function LiquidStoolapConfigNode(config) {
    RED.nodes.createNode(this, config);
    this.name = config.name;
    this.baseUrl = (config.baseUrl || "http://127.0.0.1:8321").replace(/\/+$/, "");
    this.authMode = config.authMode || "token";
    this.timeoutMs = Number(config.timeoutMs || 30000);
    this.verifyTls = config.verifyTls !== false;
    this.token = null;
  }

  RED.nodes.registerType("liquid-stoolap-config", LiquidStoolapConfigNode, {
    credentials: {
      token: { type: "password" },
      username: { type: "text" },
      password: { type: "password" }
    }
  });

  function LiquidStoolapSqlNode(config) {
    RED.nodes.createNode(this, config);
    const node = this;
    node.server = RED.nodes.getNode(config.server);
    node.sql = config.sql || "";
    node.timeoutMs = Number(config.timeoutMs || 0);

    node.on("input", async function onInput(msg, send, done) {
      send = send || function legacySend(outputs) { node.send(outputs); };
      try {
        if (!node.server) {
          throw makeNodeError("missing_config", "Liquid Stoolap config node is required");
        }

        const sql = node.sql || msg.topic;
        if (!sql || typeof sql !== "string") {
          throw makeNodeError("invalid_request", "SQL must be configured or provided in msg.topic");
        }

        const payload = msg.payload === undefined || msg.payload === null ? {} : msg.payload;
        if (typeof payload !== "object" || Array.isArray(payload)) {
          throw makeNodeError("invalid_request", "msg.payload must be an object of SQL parameters");
        }

        const body = { sql, params: payload };
        const timeoutMs = Number(
          node.timeoutMs ||
          (msg.liquidStoolap && msg.liquidStoolap.timeoutMs) ||
          node.server.timeoutMs ||
          30000
        );
        if (timeoutMs > 0) {
          body.timeout_ms = timeoutMs;
        }

        const response = await callSql(node.server, body, timeoutMs);
        msg.payload = response;
        send([msg, null]);
        if (done) {
          done();
        }
      } catch (err) {
        const structured = normalizeError(err);
        msg.error = structured;
        send([null, msg]);
        node.error(structured.message, msg);
        if (done) {
          done(err);
        }
      }
    });
  }

  RED.nodes.registerType("liquid-stoolap-sql", LiquidStoolapSqlNode);
};

async function callSql(server, body, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs || 30000);
  try {
    const headers = { "Content-Type": "application/json" };
    const authorization = await getAuthorization(server, timeoutMs);
    if (authorization) {
      headers.Authorization = authorization;
    }

    const response = await fetch(`${server.baseUrl}/sql`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = data.error || {};
      const err = makeNodeError(error.code || "http_error", error.message || response.statusText);
      err.category = error.category;
      err.statusCode = response.status;
      err.retryable = Boolean(error.retryable);
      err.details = error.details;
      throw err;
    }
    return data;
  } finally {
    clearTimeout(timer);
  }
}

async function getAuthorization(server, timeoutMs) {
  if (!server.credentials) {
    return "";
  }

  if (server.credentials.token) {
    return `Bearer ${server.credentials.token}`;
  }

  const username = server.credentials.username;
  const password = server.credentials.password;
  if (!username || !password) {
    return "";
  }

  if (!server.token) {
    server.token = await issueToken(server, username, password, timeoutMs);
  }
  return `Bearer ${server.token}`;
}

async function issueToken(server, username, password, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs || 30000);
  try {
    const response = await fetch(`${server.baseUrl}/auth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
      signal: controller.signal
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = data.error || {};
      const err = makeNodeError(error.code || "auth_error", error.message || response.statusText);
      err.category = error.category || "auth";
      err.statusCode = response.status;
      err.retryable = Boolean(error.retryable);
      err.details = error.details;
      throw err;
    }
    if (!data.token || !data.token.access_token) {
      throw makeNodeError("auth_error", "token response did not include access_token");
    }
    return data.token.access_token;
  } finally {
    clearTimeout(timer);
  }
}

function makeNodeError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function normalizeError(err) {
  return {
    code: err.code || "internal_error",
    category: err.category || "node",
    message: err.message || String(err),
    statusCode: err.statusCode,
    retryable: Boolean(err.retryable),
    details: err.details
  };
}
