"use strict";

const assert = require("node:assert/strict");
const register = require("../liquid-stoolap.js");

const registered = {};
const sentMessages = [];
let serverCredentials = { token: "token" };
const RED = {
  nodes: {
    createNode(node) {
      node.handlers = {};
      node.on = (event, handler) => {
        node.handlers[event] = handler;
      };
      node.send = (outputs) => {
        sentMessages.push(outputs);
      };
      node.error = (message, msg) => {
        node.lastError = { message, msg };
      };
    },
    registerType(name, ctor, opts) {
      registered[name] = { ctor, opts };
    },
    getNode() {
      return {
        baseUrl: "http://example.invalid",
        timeoutMs: 100,
        credentials: serverCredentials
      };
    }
  }
};

register(RED);

assert.ok(registered["liquid-stoolap-config"]);
assert.ok(registered["liquid-stoolap-sql"]);
assert.equal(registered["liquid-stoolap-sql"].ctor.name, "LiquidStoolapSqlNode");
assert.equal(registered["liquid-stoolap-config"].opts.credentials.token.type, "password");

async function run() {
  let capturedRequest;
  global.fetch = async (url, options) => {
    capturedRequest = { url, options };
    return {
      ok: true,
      status: 200,
      json: async () => ({
        ok: true,
        request_id: "r",
        duration_ms: 1,
        result: {
          kind: "result_set",
          columns: ["answer"],
          types: ["INTEGER"],
          rows: [{ values: [42] }],
          row_count: 1
        }
      })
    };
  };

  const SqlNode = registered["liquid-stoolap-sql"].ctor;
  const node = new SqlNode({ server: "server-1", sql: "", timeoutMs: 250 });
  let doneCalled = false;
  await node.handlers.input(
    { topic: "SELECT :answer", payload: { answer: 42 } },
    (outputs) => sentMessages.push(outputs),
    () => {
      doneCalled = true;
    }
  );

  assert.equal(capturedRequest.url, "http://example.invalid/sql");
  assert.equal(capturedRequest.options.method, "POST");
  assert.equal(capturedRequest.options.headers.Authorization, "Bearer token");
  assert.deepEqual(JSON.parse(capturedRequest.options.body), {
    sql: "SELECT :answer",
    params: { answer: 42 },
    timeout_ms: 250
  });
  assert.equal(doneCalled, true);
  assert.equal(sentMessages.at(-1)[0].payload.result.rows[0].values[0], 42);
  assert.equal(sentMessages.at(-1)[1], null);

  global.fetch = async () => ({
    ok: false,
    status: 422,
    statusText: "Unprocessable Content",
    json: async () => ({
      error: {
        code: "sql_error",
        category: "sql",
        message: "bad SQL",
        retryable: false,
        details: { line: 1 }
      }
    })
  });

  const failing = new SqlNode({ server: "server-1", sql: "SELECT * FROM missing", timeoutMs: 250 });
  await failing.handlers.input(
    { payload: {} },
    (outputs) => sentMessages.push(outputs),
    () => {}
  );

  const errorOutput = sentMessages.at(-1);
  assert.equal(errorOutput[0], null);
  assert.equal(errorOutput[1].error.code, "sql_error");
  assert.equal(errorOutput[1].error.statusCode, 422);
  assert.equal(failing.lastError.message, "bad SQL");

  serverCredentials = { username: "admin", password: "secret" };
  const urls = [];
  global.fetch = async (url, options) => {
    urls.push({ url, options });
    if (url.endsWith("/auth/token")) {
      assert.deepEqual(JSON.parse(options.body), { username: "admin", password: "secret" });
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          request_id: "auth",
          token: { access_token: "issued-token", token_type: "Bearer", expires_in: 3600 }
        })
      };
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({
        ok: true,
        request_id: "sql",
        duration_ms: 1,
        result: { kind: "command", affected_rows: 1, last_insert_id: null }
      })
    };
  };

  const loginNode = new SqlNode({ server: "server-1", sql: "INSERT INTO t VALUES (:v)", timeoutMs: 250 });
  await loginNode.handlers.input({ payload: { v: 1 } }, (outputs) => sentMessages.push(outputs), () => {});
  assert.equal(urls[0].url, "http://example.invalid/auth/token");
  assert.equal(urls[1].url, "http://example.invalid/sql");
  assert.equal(urls[1].options.headers.Authorization, "Bearer issued-token");
}

run()
  .then(() => {
    console.log("node-red runtime smoke ok");
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
