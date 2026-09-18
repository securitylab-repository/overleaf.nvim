#!/usr/bin/env node
'use strict';

const readline = require('readline');
const auth = require('./auth');
const SocketManager = require('./socket');
const { getOverleafCookie, listProfiles } = require('./chrome-cookie');

// Redirect console.log to stderr (stdout is the RPC channel)
const origLog = console.log;
console.log = (...args) => console.error('[bridge]', ...args);

const BASE_URL = process.env.OVERLEAF_URL || 'https://www.overleaf.com';

let requestId = 0;
let socketManager = null;
let pendingRequests = 0;
let stdinClosed = false;

const REDIRECT_CODES = new Set([301, 302, 303, 307, 308]);

/**
 * Build the absolute URL for a compile output file (PDF, log, SyncTeX
 * table, ...). When the compile response carries a clsiServerId and
 * pdfDownloadDomain, the file is served from a dedicated per-build
 * CLSI/CDN host and needs those as query params — the plain
 * `${BASE_URL}${fileUrl}` path 404s in that case. Falls back to the web
 * frontend host otherwise (e.g. self-hosted Overleaf without a CDN).
 */
function buildOutputUrl(fileUrl, compileResult) {
  const { clsiServerId, compileGroup, pdfDownloadDomain } = compileResult || {};
  if (pdfDownloadDomain && clsiServerId) {
    const domain = pdfDownloadDomain.replace(/\/+$/, '');
    const path = fileUrl.replace(/^\/+/, '');
    const qp = new URLSearchParams({
      compileGroup: compileGroup || 'standard',
      clsiserverid: clsiServerId,
      enable_pdf_caching: 'true',
    });
    return `${domain}/${path}?${qp.toString()}`;
  }
  return `${BASE_URL}${fileUrl}`;
}

/**
 * GET a URL (following redirects) and write the response body to destPath.
 * Rejects on a non-2xx/206 final status so a redirect/auth failure never
 * silently produces an empty file. `cookie` is optional — the CLSI/CDN
 * host from buildOutputUrl() is cross-origin and authenticates via its
 * signed query params, not the web frontend session cookie.
 *
 * The pdfDownloadDomain CDN (enable_pdf_caching=true) doesn't always serve
 * the file as one 200 response: while the object is still being composed
 * server-side it answers a plain GET with a 206 carrying only the bytes
 * written so far, and expects the same URL to be re-fetched for the next
 * chunk until a final 200 arrives. Overleaf's own web client (pdf.js
 * custom transport) and other clients (e.g. Overleaf Workshop's
 * _downloadAbsolute) handle this by looping and concatenating every
 * 206/200 body in order. Treating a lone 206 as the whole file (the old
 * behavior here) silently produced a truncated PDF that failed to render.
 */
function downloadToFile(url, cookie, destPath, maxRedirects = 5) {
  const fs = require('fs');
  const MAX_CHUNKS = 200; // safety cap against a CDN that never settles on 200

  return new Promise((resolve, reject) => {
    const chunks = [];

    function get(currentUrl, redirectsLeft, chunksLeft) {
      const parsed = new URL(currentUrl);
      const httpModule = parsed.protocol === 'http:' ? require('http') : require('https');
      httpModule
        .get(
          {
            hostname: parsed.hostname,
            port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
            path: parsed.pathname + parsed.search,
            headers: cookie ? { 'Cookie': cookie } : {},
          },
          (res) => {
            if (REDIRECT_CODES.has(res.statusCode) && res.headers.location) {
              res.resume(); // discard the (usually empty) redirect body
              if (redirectsLeft <= 0) {
                reject(new Error(`Too many redirects fetching ${url}`));
                return;
              }
              const nextUrl = new URL(res.headers.location, currentUrl).toString();
              get(nextUrl, redirectsLeft - 1, chunksLeft);
              return;
            }

            if (res.statusCode !== 200 && res.statusCode !== 206) {
              res.resume();
              reject(new Error(`Download failed with status ${res.statusCode}: ${currentUrl}`));
              return;
            }

            const body = [];
            res.on('data', (d) => body.push(d));
            res.on('error', reject);
            res.on('end', () => {
              chunks.push(Buffer.concat(body));

              if (res.statusCode === 200) {
                fs.writeFile(destPath, Buffer.concat(chunks), (err) => {
                  if (err) reject(err);
                  else resolve();
                });
                return;
              }

              // 206: more chunks are still being composed server-side.
              if (chunksLeft <= 0) {
                reject(new Error(`Gave up after ${MAX_CHUNKS} partial (206) responses: ${url}`));
                return;
              }
              get(currentUrl, redirectsLeft, chunksLeft - 1);
            });
          }
        )
        .on('error', reject);
    }

    get(url, maxRedirects, MAX_CHUNKS);
  });
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function sendResult(id, result) {
  send({ id, result });
}

function sendError(id, code, message) {
  send({ id, error: { code, message } });
}

function sendEvent(event, data) {
  send({ event, data });
}

const handlers = {
  async ping(params) {
    return { status: 'ok' };
  },

  async listChromeProfiles(params) {
    const profiles = listProfiles();
    return { profiles };
  },

  async getCookie(params) {
    const cookie = await getOverleafCookie(params.profile);
    return { cookie };
  },

  async auth(params) {
    const { cookie } = params;
    if (!cookie) throw { code: 'MISSING_PARAM', message: 'cookie is required' };
    return await auth.fetchProjectPage(cookie);
  },

  async connect(params) {
    let { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }

    // Fetch GCLB cookie for load balancer stickiness (skip for local/test servers)
    if (!process.env.OVERLEAF_URL) {
      cookie = await auth.updateCookies(cookie);
      console.log('Updated cookies for socket connection');
    }

    if (socketManager) {
      socketManager.disconnect();
    }

    socketManager = new SocketManager(cookie, projectId, sendEvent);
    const result = await socketManager.connect();
    // Report the GCLB-stickied cookie back so subsequent HTTP requests
    // (compile, downloadUrl, ...) hit the same backend as the socket —
    // otherwise they can 404 against a build that only exists on the
    // node the socket is stuck to.
    return { ...result, cookie };
  },

  async joinDoc(params) {
    const { docId } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.joinDoc(docId);
  },

  async leaveDoc(params) {
    const { docId } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.leaveDoc(docId);
  },

  async applyOtUpdate(params) {
    const { docId, op, v, content } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId || op === undefined || v === undefined) {
      throw { code: 'MISSING_PARAM', message: 'docId, op, and v are required' };
    }
    return await socketManager.applyOtUpdate(docId, op, v, content);
  },

  async compile(params) {
    const { cookie, csrfToken, projectId, editorId, rootDocId } = params;
    if (!cookie || !csrfToken || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, and projectId are required' };
    }

    const compileBody = { check: 'silent', draft: false, incrementalCompilesEnabled: true, stopOnFirstError: false };
    // Matches Overleaf's own web client: the server associates this id with
    // the resulting build, and /sync/code (SyncTeX forward search) later
    // needs the same id to find it — see bridge.js's syncCode handler.
    if (editorId) compileBody.editorId = editorId;
    // The web client sends this explicitly too, rather than relying on the
    // server's own auto-detection fallback.
    if (rootDocId) compileBody.rootDoc_id = rootDocId;

    const compileRes = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/compile`,
      cookie, csrfToken,
      compileBody
    );

    if (compileRes.status !== 200) {
      throw { code: 'COMPILE_ERROR', message: `Compile request failed with status ${compileRes.status}` };
    }

    const parsed = JSON.parse(compileRes.body);

    // Download log if available. Output files are served from a per-build
    // CLSI/CDN host when present — see buildOutputUrl() below.
    const logFile = (parsed.outputFiles || []).find(f => f.path === 'output.log');
    let log = '';
    if (logFile) {
      const logUrl = buildOutputUrl(logFile.url, parsed);
      const logRes = await auth.httpGet(logUrl, cookie);
      log = logRes.body;
    }

    return {
      status: parsed.status,
      outputFiles: parsed.outputFiles || [],
      log,
      clsiServerId: parsed.clsiServerId,
      compileGroup: parsed.compileGroup,
      pdfDownloadDomain: parsed.pdfDownloadDomain,
    };
  },

  async downloadUrl(params) {
    const { cookie, url, fileName, outputDir } = params;
    if (!url) {
      throw { code: 'MISSING_PARAM', message: 'url is required' };
    }

    const dir = outputDir || require('os').tmpdir();
    const fs = require('fs');
    fs.mkdirSync(dir, { recursive: true });
    // Use fileName verbatim (no prefix) so callers can control the exact basename.
    const tmpPath = require('path').join(dir, fileName || 'overleaf_download');

    await downloadToFile(url, cookie, tmpPath);

    return { path: tmpPath };
  },

  async downloadFile(params) {
    const { cookie, projectId, fileId, fileName, outputDir } = params;
    if (!cookie || !projectId || !fileId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, and fileId are required' };
    }

    const url = `${BASE_URL}/project/${projectId}/file/${fileId}`;
    const dir = outputDir || require('os').tmpdir();

    // Download binary file
    const fs = require('fs');
    fs.mkdirSync(dir, { recursive: true });
    const tmpPath = require('path').join(dir, 'overleaf_' + (fileName || fileId));
    await downloadToFile(url, cookie, tmpPath);

    return { path: tmpPath };
  },

  // SyncTeX forward search. Overleaf resolves this server-side rather than
  // exposing the compile's raw .synctex.gz for direct download (confirmed:
  // that download consistently 404s/503s even though output.pdf and
  // output.log from the same build succeed) — this is what its own web
  // client calls internally.
  async syncCode(params) {
    const { cookie, csrfToken, projectId, file, line, column, buildId, editorId, clsiServerId } = params;
    if (!cookie || !projectId || !file || line === undefined || !buildId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, file, line, and buildId are required' };
    }
    const qsParams = {
      file,
      line: String(line),
      column: String(column || 0),
    };
    // Same per-build CLSI routing the output file downloads need (see
    // buildOutputUrl) — without it the request can reach a backend that
    // doesn't have this build's sync data and silently returns no match.
    // Confirmed present in the request Overleaf's own web UI sends.
    if (clsiServerId) qsParams.clsiserverid = clsiServerId;
    qsParams.editorId = editorId || '';
    qsParams.buildId = buildId;
    const qs = new URLSearchParams(qsParams);
    const url = `${BASE_URL}/project/${projectId}/sync/code?${qs.toString()}`;
    const res = await auth.httpGet(url, cookie, csrfToken);
    if (res.status !== 200) {
      throw { code: 'SYNC_FAILED', message: `Forward search request failed: ${res.status} ${res.body || ''}`.trim() };
    }
    let parsed;
    try {
      parsed = JSON.parse(res.body);
    } catch (e) {
      throw { code: 'PARSE_ERROR', message: `Failed to parse sync/code response: ${e.message}` };
    }
    return { pdf: parsed.pdf || [], requestUrl: url, rawBody: res.body };
  },

  async createDoc(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/doc`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create doc failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async createFolder(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/folder`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create folder failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async renameEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType, newName } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType || !newName) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, entityType, and newName are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/${entityType}/${entityId}/rename`,
      cookie, csrfToken,
      { name: newName }
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'RENAME_FAILED', message: `Rename failed: ${res.status} ${res.body}` };
    }
    return {};
  },

  async deleteEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, and entityType are required' };
    }
    const res = await auth.httpDelete(
      `${BASE_URL}/project/${projectId}/${entityType}/${entityId}`,
      cookie, csrfToken
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'DELETE_FAILED', message: `Delete failed: ${res.status}` };
    }
    return {};
  },

  async uploadFile(params) {
    const { cookie, csrfToken, projectId, filePath, fileName, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !filePath) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and filePath are required' };
    }
    const fs = require('fs');
    if (!fs.existsSync(filePath)) {
      throw { code: 'FILE_NOT_FOUND', message: `File not found: ${filePath}` };
    }
    const folderId = parentFolderId || 'rootFolder';
    const url = `${BASE_URL}/project/${projectId}/upload?folder_id=${folderId}`;
    const res = await auth.httpPostMultipart(url, cookie, csrfToken, filePath, fileName);
    if (res.status !== 200) {
      throw { code: 'UPLOAD_FAILED', message: `Upload failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async getHistory(params) {
    const { cookie, projectId, minCount } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `${BASE_URL}/project/${projectId}/updates?min_count=${minCount || 15}`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'HISTORY_FAILED', message: `History request failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async getThreads(params) {
    const { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `${BASE_URL}/project/${projectId}/threads`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'THREADS_FAILED', message: `Get threads failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async addComment(params) {
    const { cookie, csrfToken, projectId, threadId, content } = params;
    if (!cookie || !csrfToken || !projectId || !threadId || !content) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, threadId, and content are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/thread/${threadId}/messages`,
      cookie, csrfToken,
      { content }
    );
    if (res.status !== 200 && res.status !== 201 && res.status !== 204) {
      throw { code: 'COMMENT_FAILED', message: `Add comment failed: ${res.status}` };
    }
    try { return JSON.parse(res.body); } catch (e) { return {}; }
  },

  async resolveThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}/resolve`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}/resolve`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'RESOLVE_FAILED', message: `Resolve thread failed: ${res.status}` };
    }
    return {};
  },

  async reopenThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}/reopen`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}/reopen`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'REOPEN_FAILED', message: `Reopen thread failed: ${res.status}` };
    }
    return {};
  },

  async deleteThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}`;
    const res = await auth.httpDelete(url, cookie, csrfToken);
    if (res.status !== 200 && res.status !== 204) {
      throw { code: 'DELETE_FAILED', message: `Delete thread failed: ${res.status}` };
    }
    return {};
  },

  async disconnect() {
    if (socketManager) {
      socketManager.disconnect();
      socketManager = null;
    }
    return {};
  },
};

function maybeExit() {
  if (stdinClosed && pendingRequests === 0 && !socketManager) {
    process.exit(0);
  }
}

async function handleMessage(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    console.log('Failed to parse message:', line);
    return;
  }

  const { id, method, params } = msg;
  if (!method || id === undefined) {
    console.log('Invalid message format:', line);
    return;
  }

  const handler = handlers[method];
  if (!handler) {
    sendError(id, 'UNKNOWN_METHOD', `Unknown method: ${method}`);
    return;
  }

  pendingRequests++;
  try {
    const result = await handler(params || {});
    sendResult(id, result);
  } catch (err) {
    const code = err.code || 'INTERNAL_ERROR';
    const message = err.message || String(err);
    sendError(id, code, message);
  } finally {
    pendingRequests--;
    maybeExit();
  }
}

// stdin line reader
const rl = readline.createInterface({
  input: process.stdin,
  terminal: false,
});

rl.on('line', (line) => {
  if (line.trim()) {
    handleMessage(line.trim());
  }
});

rl.on('close', () => {
  console.log('stdin closed');
  stdinClosed = true;
  if (socketManager) {
    socketManager.disconnect();
    socketManager = null;
  }
  maybeExit();
  // Force exit after 5s if pending requests don't complete
  setTimeout(() => process.exit(0), 5000).unref();
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received');
  if (socketManager) {
    socketManager.disconnect();
  }
  process.exit(0);
});

process.on('uncaughtException', (err) => {
  console.log('Uncaught exception:', err.message);
  sendEvent('error', { message: err.message });
});

console.log('Bridge started');
