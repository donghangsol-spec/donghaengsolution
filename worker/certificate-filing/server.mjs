import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { CredentialSessionManager } from "./credential-session.mjs";

const host = process.env.WORKER_HOST ?? "127.0.0.1";
const port = Number.parseInt(process.env.WORKER_PORT ?? "47821", 10);
const controlToken = process.env.WORKER_CONTROL_TOKEN ?? "";
const maxBodyBytes = 256 * 1024;

if (host !== "127.0.0.1" && host !== "::1") {
  throw new Error("worker must bind to a loopback address");
}
if (!Number.isInteger(port) || port < 1024 || port > 65535) {
  throw new Error("WORKER_PORT must be between 1024 and 65535");
}
if (Buffer.byteLength(controlToken) < 32) {
  throw new Error("WORKER_CONTROL_TOKEN must contain at least 32 bytes");
}

const sessions = new CredentialSessionManager();

function authorized(request) {
  const supplied = request.headers.authorization?.replace(/^Bearer /, "") ?? "";
  const expected = Buffer.from(controlToken);
  const actual = Buffer.from(supplied);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function respond(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  response.end(JSON.stringify(body));
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new Error("request body too large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      return respond(response, 200, { status: "ok" });
    }
    if (!authorized(request)) return respond(response, 401, { error: "unauthorized" });

    if (request.method === "GET" && request.url === "/v1/public-key") {
      return respond(response, 200, sessions.publicKey());
    }
    if (request.method === "POST" && request.url === "/v1/credential-sessions") {
      const body = await readJson(request);
      return respond(response, 201, sessions.accept(body.jobId, body.envelope));
    }
    const match = request.url?.match(/^\/v1\/credential-sessions\/([0-9a-f-]+)$/i);
    if (request.method === "DELETE" && match) {
      const destroyed = sessions.destroy(match[1]);
      return respond(response, destroyed ? 200 : 404, { destroyed });
    }
    return respond(response, 404, { error: "not found" });
  } catch (error) {
    return respond(response, 400, { error: error.message });
  }
});

const cleanupTimer = setInterval(() => sessions.cleanup(), 30_000);
cleanupTimer.unref();

function shutdown() {
  clearInterval(cleanupTimer);
  server.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
server.listen(port, host, () => {
  console.log(`certificate worker control API listening on http://${host}:${port}`);
});
