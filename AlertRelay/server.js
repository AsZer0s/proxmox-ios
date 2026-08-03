import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';

const configPath = process.env.CONFIG_PATH || './config.json';
const deviceStorePath = process.env.DEVICE_STORE_PATH || './devices.json';
const port = Number(process.env.PORT || 8787);
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const devices = loadJSON(deviceStorePath, {});
const activeEvents = new Map();
const lastSent = new Map();
let apnsToken = null;
let apnsTokenCreatedAt = 0;

function loadJSON(path, fallback) {
  try { return JSON.parse(fs.readFileSync(path, 'utf8')); } catch { return fallback; }
}

function persistDevices() {
  const temporary = `${deviceStorePath}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(devices, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, deviceStorePath);
}

function json(response, status, value) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}

function authorized(request) {
  const expected = Buffer.from(`Bearer ${config.enrollmentToken || ''}`);
  const actual = Buffer.from(request.headers.authorization || '');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

const server = http.createServer(async (request, response) => {
  if (request.url === '/healthz' && request.method === 'GET') {
    return json(response, 200, { ok: true, clusters: config.clusters?.length || 0, devices: Object.keys(devices).length });
  }
  if (!authorized(request)) return json(response, 401, { error: 'unauthorized' });
  if (request.url === '/v1/devices' && request.method === 'POST') {
    try {
      const body = await readBody(request);
      if (!/^[a-f0-9]{64,}$/.test(body.deviceToken || '')) return json(response, 400, { error: 'invalid device token' });
      devices[body.deviceToken] = {
        environment: body.environment === 'sandbox' ? 'sandbox' : 'production',
        clusterIDs: Array.isArray(body.clusterIDs) ? body.clusterIDs : [],
        rules: Array.isArray(body.rules) ? body.rules : [],
        updatedAt: new Date().toISOString(),
      };
      persistDevices();
      return json(response, 200, { ok: true });
    } catch (error) { return json(response, 400, { error: error.message }); }
  }
  const match = request.url?.match(/^\/v1\/devices\/([a-f0-9]+)$/);
  if (match && request.method === 'DELETE') {
    delete devices[match[1]];
    persistDevices();
    return json(response, 200, { ok: true });
  }
  return json(response, 404, { error: 'not found' });
});

function readBody(request) {
  return new Promise((resolve, reject) => {
    let value = '';
    request.on('data', chunk => {
      value += chunk;
      if (value.length > 256_000) request.destroy();
    });
    request.on('end', () => {
      try { resolve(JSON.parse(value)); } catch { reject(new Error('invalid JSON')); }
    });
    request.on('error', reject);
  });
}

async function pveGet(cluster, path) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  try {
    const response = await fetch(`${cluster.baseUrl}${path}`, {
      headers: { Authorization: `PVEAPIToken=${cluster.tokenId}=${cluster.tokenSecret}` },
      signal: controller.signal,
      dispatcher: undefined,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
    return (await response.json()).data;
  } finally { clearTimeout(timer); }
}

function event(kind, cluster, source, title, body, value = null) {
  return { key: `${cluster.id}:${kind}:${source}`, kind, clusterId: cluster.id, clusterName: cluster.name, source, title, body, value };
}

async function inspectCluster(cluster) {
  const [nodes, resources] = await Promise.all([pveGet(cluster, '/nodes'), pveGet(cluster, '/cluster/resources')]);
  const result = [];
  for (const node of nodes) {
    if (node.status !== 'online') result.push(event('nodeOffline', cluster, node.node, 'Node Offline', `${cluster.name}: ${node.node} is offline.`));
    if (Number(node.cpu) >= 0.5) result.push(event('cpu', cluster, node.node, 'High CPU Usage', `${cluster.name}: ${node.node} CPU is ${(Number(node.cpu) * 100).toFixed(2)}%.`, Number(node.cpu)));
    if (Number(node.maxmem) > 0) {
      const fraction = Number(node.mem) / Number(node.maxmem);
      if (fraction >= 0.5) result.push(event('memory', cluster, node.node, 'High Memory Usage', `${cluster.name}: ${node.node} memory is ${(fraction * 100).toFixed(2)}%.`, fraction));
    }
  }
  for (const item of resources.filter(item => item.type === 'storage' && Number(item.maxdisk) > 0)) {
    const fraction = Number(item.disk) / Number(item.maxdisk);
    if (fraction >= 0.5) result.push(event('storage', cluster, item.id, 'Storage Nearly Full', `${cluster.name}: ${item.storage || item.id} is ${(fraction * 100).toFixed(2)}% full.`, fraction));
  }
  for (const node of nodes.filter(item => item.status === 'online')) {
    try {
      const tasks = await pveGet(cluster, `/nodes/${encodeURIComponent(node.node)}/tasks?errors=1&limit=25&typefilter=vzdump`);
      const cutoff = Date.now() / 1000 - Math.max(120, Number(config.pollSeconds || 60) * 2);
      for (const task of tasks.filter(item => Number(item.endtime || item.starttime) >= cutoff)) {
        result.push(event('backupFailure', cluster, task.upid, 'Backup Failed', `${cluster.name}: backup ${task.id || ''} failed (${task.status || 'error'}).`));
      }
    } catch (error) { console.error(`task polling failed for ${cluster.name}/${node.node}:`, error.message); }
  }
  return result;
}

function matchingRule(device, item) {
  const rules = device.rules?.filter(rule => rule.kind === item.kind && rule.enabled) || [];
  return rules.find(rule => {
    if (rule.serverIDs?.length && !rule.serverIDs.includes(item.clusterId)) return false;
    if (item.value != null && rule.threshold != null && item.value < Number(rule.threshold)) return false;
    const pattern = String(rule.resourcePattern || '*').replace(/[.+^${}()|[\]\\]/g, '\\$&').replaceAll('*', '.*');
    return new RegExp(`^${pattern}$`, 'i').test(item.source);
  });
}

function base64url(value) { return Buffer.from(value).toString('base64url'); }

function providerToken() {
  if (apnsToken && Date.now() - apnsTokenCreatedAt < 50 * 60 * 1000) return apnsToken;
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: config.apns.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.apns.teamId, iat: Math.floor(Date.now() / 1000) }));
  const signingInput = `${header}.${claims}`;
  const key = fs.readFileSync(config.apns.privateKeyPath);
  const signature = crypto.sign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  apnsTokenCreatedAt = Date.now();
  return apnsToken = `${signingInput}.${signature}`;
}

async function sendPush(token, device, item) {
  const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const client = http2.connect(`https://${host}`);
  const payload = JSON.stringify({
    aps: { alert: { title: item.title, body: item.body }, sound: 'default', 'thread-id': item.clusterId },
    clusterId: item.clusterId, kind: item.kind, source: item.source,
  });
  return new Promise((resolve, reject) => {
    client.on('error', reject);
    const request = client.request({
      ':method': 'POST', ':path': `/3/device/${token}`,
      authorization: `bearer ${providerToken()}`,
      'apns-topic': config.apns.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'content-type': 'application/json',
    });
    let body = '';
    let status = 0;
    request.on('response', headers => { status = Number(headers[':status']); });
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => {
      client.close();
      if (status === 200) resolve(); else reject(new Error(`APNs ${status}: ${body}`));
    });
    request.end(payload);
  });
}

async function poll() {
  const currentKeys = new Set();
  for (const cluster of config.clusters || []) {
    try {
      const events = await inspectCluster(cluster);
      for (const item of events) {
        currentKeys.add(item.key);
        if (activeEvents.has(item.key)) continue;
        activeEvents.set(item.key, Date.now());
        for (const [token, device] of Object.entries(devices)) {
          const rule = device.clusterIDs?.includes(cluster.id) && matchingRule(device, item);
          if (!rule) continue;
          const sentKey = `${token}:${item.key}`;
          const cooldown = Math.max(1, Number(rule.cooldownMinutes || 5)) * 60_000;
          if (Date.now() - (lastSent.get(sentKey) || 0) < cooldown) continue;
          lastSent.set(sentKey, Date.now());
          sendPush(token, device, item).catch(error => console.error(`APNs ${token.slice(0, 8)}:`, error.message));
        }
      }
    } catch (error) { console.error(`poll failed for ${cluster.name}:`, error.message); }
  }
  for (const key of activeEvents.keys()) if (!currentKeys.has(key)) activeEvents.delete(key);
}

server.listen(port, () => console.log(`Proxmox alert relay listening on :${port}`));
poll();
setInterval(poll, Math.max(30, Number(config.pollSeconds || 60)) * 1000).unref();
