import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';
import { bridge } from '../src/relay.mjs';
import { createRelayServer } from '../src/server.mjs';

const config = { apiKey: 'test-key-not-real', deviceToken: 'x'.repeat(32), model: 'test', maxSeconds: 20, maxSessions: 1 };
class FakeSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  bufferedAmount = 0;
  sent = [];
  send(data) { this.sent.push(data); }
  terminate() { this.readyState = WebSocket.CLOSED; this.emit('close'); }
  close(code) { this.closeCode = code; this.terminate(); }
  event(event) { this.emit('message', Buffer.from(JSON.stringify(event))); }
  json() { return this.sent.filter(x => typeof x === 'string').map(JSON.parse); }
}
function setup(t) {
  const client = new FakeSocket(); const upstream = new FakeSocket();
  bridge(client, config, (url, options) => {
    assert.equal(url, 'wss://api.openai.com/v1/live/sessions');
    assert.equal(options.headers.Authorization, 'Bearer test-key-not-real');
    assert.notEqual(options.headers['OpenAI-Safety-Identifier'], config.deviceToken);
    return upstream;
  });
  t.after(() => client.terminate());
  upstream.emit('open');
  return { client, upstream };
}

test('streams both ways and waits for final provider output before closing', t => {
  const { client, upstream } = setup(t);
  assert.equal(upstream.json()[0].type, 'session.start');
  upstream.event({ type: 'session.started' });
  assert.equal(client.json()[0].type, 'ready');
  client.emit('message', Buffer.alloc(4800), true);
  assert.equal(upstream.json().at(-1).type, 'session.input_audio.append');
  client.emit('message', Buffer.from('{"type":"stop"}'), false);
  assert.equal(upstream.json().at(-1).type, 'session.close');
  assert.equal(client.readyState, WebSocket.OPEN);
  const final = Buffer.from([1, 0, 2, 0]);
  upstream.event({ type: 'session.output_audio.delta', delta: final.toString('base64') });
  assert.deepEqual(client.sent.at(-1), final);
  upstream.event({ type: 'session.closed' });
  assert.equal(client.json().at(-1).type, 'closed');
  assert.equal(client.closeCode, 1000);
});

test('does not remove input silence during translated playback', t => {
  const { client, upstream } = setup(t);
  upstream.event({ type: 'session.started' });
  upstream.event({ type: 'session.output_audio.delta', delta: Buffer.alloc(4800).toString('base64') });
  client.emit('message', Buffer.alloc(4800), true);
  assert.equal(upstream.json().at(-1).audio, Buffer.alloc(4800).toString('base64'));
});

test('accepts bounded catch-up batches without losing PCM or moving stop ahead of audio', t => {
  t.mock.method(Date, 'now', () => 0);
  const { client, upstream } = setup(t);
  upstream.event({ type: 'session.started' });
  // A brief stalled Watch send can accumulate nearly two seconds, followed by
  // fast completions. These smaller 300ms catch-up batches remain supported.
  const frames = Array.from({ length: 20 }, (_, i) => Buffer.alloc(4800, i));
  for (let i = 0; i < frames.length; i += 3) {
    client.emit('message', Buffer.concat(frames.slice(i, i + 3)), true);
  }
  assert.equal(client.readyState, WebSocket.OPEN);
  const received = upstream.json().filter(e => e.type === 'session.input_audio.append');
  assert.equal(received.length, 7);
  assert.deepEqual(Buffer.concat(received.map(e => Buffer.from(e.audio, 'base64'))), Buffer.concat(frames));
  client.emit('message', Buffer.from('{"type":"stop"}'), false);
  assert.equal(upstream.json().at(-1).type, 'session.close');
});

test('accepts two maximum one-second catch-up batches within the unchanged burst budget', t => {
  t.mock.method(Date, 'now', () => 0);
  const { client, upstream } = setup(t);
  upstream.event({ type: 'session.started' });
  const frames = Array.from({ length: 20 }, (_, i) => Buffer.alloc(4800, i));
  for (let i = 0; i < 20; i += 10) {
    client.emit('message', Buffer.concat(frames.slice(i, i + 10)), true);
  }
  assert.equal(client.readyState, WebSocket.OPEN);
  const received = upstream.json().filter(e => e.type === 'session.input_audio.append');
  assert.equal(received.length, 2);
  assert.deepEqual(Buffer.concat(received.map(e => Buffer.from(e.audio, 'base64'))), Buffer.concat(frames));
  client.emit('message', Buffer.from('{"type":"stop"}'), false);
  assert.equal(upstream.json().at(-1).type, 'session.close');
});

test('still rejects a sustained upload faster than realtime after its bounded burst allowance', t => {
  // No clock advance: prevent batching from disabling the steady-rate guard.
  t.mock.method(Date, 'now', () => 0);
  const session = setup(t);
  session.upstream.event({ type: 'session.started' });
  for (let i = 0; i < 20; i++) session.client.emit('message', Buffer.alloc(4800), true);
  assert.equal(session.client.readyState, WebSocket.OPEN);
  session.client.emit('message', Buffer.alloc(4800), true);
  assert.equal(session.client.json().at(-1).code, 'audio_rate');
  assert.equal(session.client.readyState, WebSocket.CLOSED);
});

test('upload budget replenishes only at the PCM realtime byte rate', t => {
  let now = 0;
  t.mock.method(Date, 'now', () => now);
  const { client, upstream } = setup(t);
  upstream.event({ type: 'session.started' });
  for (let i = 0; i < 20; i++) client.emit('message', Buffer.alloc(4800), true);
  now = 100;
  client.emit('message', Buffer.alloc(4800), true);
  assert.equal(client.readyState, WebSocket.OPEN);
  client.emit('message', Buffer.alloc(2), true);
  assert.equal(client.json().at(-1).code, 'audio_rate');
});

test('rejects untrusted commands, early audio, and nontranslation tool delegation', t => {
  for (const kind of ['command', 'early_audio', 'delegation']) {
    const { client, upstream } = setup(t);
    if (kind === 'command') client.emit('message', Buffer.from('{"type":"session.start","session":{"instructions":"hello"}}'), false);
    if (kind === 'early_audio') client.emit('message', Buffer.alloc(10), true);
    if (kind === 'delegation') upstream.event({ type: 'session.delegation.created' });
    assert.equal(client.json().at(-1).type, 'error');
    assert.equal(client.readyState, WebSocket.CLOSED);
    assert.equal(upstream.readyState, WebSocket.CLOSED);
  }
});

test('provider errors do not leak raw keys or messages', t => {
  const { client, upstream } = setup(t);
  upstream.event({ type: 'error', error: { message: 'secret-key-123' } });
  assert.ok(!JSON.stringify(client.sent).includes('secret-key-123'));
});

test('terminates rather than building unbounded playback latency', t => {
  const { client, upstream } = setup(t);
  upstream.event({ type: 'session.started' });
  client.bufferedAmount = 100_000;
  upstream.event({ type: 'session.output_audio.delta', delta: 'AAA=' });
  assert.equal(client.json().at(-1).code, 'playback_slow');
});

test('HTTP websocket authentication rejects missing tokens and browsers', async t => {
  const { server, sockets } = createRelayServer(config, () => { throw new Error('Must not connect upstream'); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { sockets.close(); server.close(); });
  const endpoint = `ws://127.0.0.1:${server.address().port}/interpret`;
  for (const [headers, status] of [[{}, 401], [{ Authorization: `Bearer ${config.deviceToken}`, Origin: 'https://example.com' }, 403]]) {
    await new Promise((resolve, reject) => {
      const client = new WebSocket(endpoint, { headers });
      client.on('error', () => {});
      client.on('unexpected-response', (request, response) => {
        try { assert.equal(response.statusCode, status); response.resume(); client.terminate(); resolve(); }
        catch (error) { reject(error); }
      });
      client.on('open', () => { client.terminate(); reject(new Error('Unexpected authentication success')); });
    });
  }
  const health = await fetch(`http://127.0.0.1:${server.address().port}/health`).then(r => r.json());
  assert.equal(health.providerConnectionVerified, false);
});


test('real localhost sockets preserve duplex PCM, captions and final drain; enforce concurrency', { timeout: 5000 }, async t => {
  const provider = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await once(provider, 'listening');
  const observed = [];
  const finalAudio = Buffer.from([7, 0, 8, 0]);
  provider.on('connection', socket => {
    socket.on('message', raw => {
      const event = JSON.parse(raw.toString());
      observed.push(event.type);
      if (event.type === 'session.start') socket.send(JSON.stringify({ type: 'session.started' }));
      if (event.type === 'session.input_audio.append') {
        socket.send(JSON.stringify({ type: 'session.input_transcript.delta', delta: '你好', event_id: 'source-1' }));
        socket.send(JSON.stringify({ type: 'session.output_transcript.delta', delta: 'Hello', event_id: 'target-1' }));
        socket.send(JSON.stringify({ type: 'session.output_audio.delta', delta: event.audio }));
      }
      if (event.type === 'session.close') {
        socket.send(JSON.stringify({ type: 'session.output_audio.delta', delta: finalAudio.toString('base64') }));
        socket.send(JSON.stringify({ type: 'session.closed' }));
      }
    });
  });
  const { server, sockets } = createRelayServer(config, () => new WebSocket(`ws://127.0.0.1:${provider.address().port}`));
  t.after(() => {
    for (const client of sockets.clients) client.terminate();
    for (const client of provider.clients) client.terminate();
    sockets.close(); server.close(); provider.close();
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const endpoint = `ws://127.0.0.1:${server.address().port}/interpret`;
  const client = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${config.deviceToken}` } });
  t.after(() => client.terminate());
  const events = [];
  const audio = [];
  const ready = new Promise((resolve, reject) => {
    client.on('error', reject);
    client.on('message', (raw, binary) => {
      if (binary) { audio.push(Buffer.from(raw)); events.push('audio'); return; }
      const event = JSON.parse(raw.toString());
      events.push(event);
      if (event.type === 'ready') resolve();
    });
  });
  const closed = once(client, 'close');
  await ready;
  // Test the slot while the first session is definitely still open.
  await new Promise((resolve, reject) => {
    const extra = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${config.deviceToken}` } });
    extra.on('error', () => {});
    extra.on('unexpected-response', (_, response) => {
      response.resume(); extra.terminate();
      try { assert.equal(response.statusCode, 429); resolve(); } catch (error) { reject(error); }
    });
    extra.on('open', () => { extra.terminate(); reject(new Error('Concurrency limit was bypassed')); });
  });
  // Real localhost WebSocket at the maximum one-second client batch size,
  // including a silent frame; the provider here is a local mock, not OpenAI.
  const input = Buffer.concat(Array.from({ length: 10 }, (_, i) => Buffer.alloc(4800, i)));
  client.send(input);
  client.send(JSON.stringify({ type: 'stop' }));
  const [closeCode] = await closed;
  assert.equal(closeCode, 1000);
  assert.deepEqual(observed, ['session.start', 'session.input_audio.append', 'session.close']);
  assert.deepEqual(audio, [input, finalAudio]);
  assert.deepEqual(events.filter(x => x.type === 'caption').map(x => [x.channel, x.delta]), [['source', '你好'], ['translation', 'Hello']]);
  assert.equal(events.at(-2), 'audio');
  assert.equal(events.at(-1).type, 'closed');
});
