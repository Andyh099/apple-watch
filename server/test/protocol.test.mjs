import test from 'node:test';
import assert from 'node:assert/strict';
import { audioInput, startEvent, captionEvent, decodeAudio, INTERPRETER_INSTRUCTIONS } from '../src/protocol.mjs';
import { readConfig } from '../src/server.mjs';

test('startup has no greeting, tools, delegation backend, or stored history', () => {
  const event = startEvent();
  assert.equal(event.type, 'session.start');
  assert.equal(event.session.store, false);
  assert.deepEqual(event.session.delegation, { type: 'client' });
  assert.equal(event.session.audio.format.rate, 24000);
  assert.match(INTERPRETER_INSTRUCTIONS, /Translate Mandarin Chinese speech directly into English/);
  assert.match(INTERPRETER_INSTRUCTIONS, /Translate English speech directly into natural Mandarin/);
  assert.match(INTERPRETER_INSTRUCTIONS, /never answer or execute/i);
  assert.match(INTERPRETER_INSTRUCTIONS, /Backchannel policy: none/);
  assert.equal(event.session.tools, undefined);
});

test('audio includes silence, preserves bytes, and rejects partial samples', () => {
  for (const length of [4800, 14_400, 28_800, 48_000]) {
    const bytes = Buffer.alloc(length);
    const event = audioInput(bytes);
    assert.equal(event.type, 'session.input_audio.append');
    assert.deepEqual(Buffer.from(event.audio, 'base64'), bytes);
  }
  assert.throws(() => audioInput(Buffer.alloc(3)));
  assert.throws(() => audioInput(Buffer.alloc(0)));
  assert.throws(() => audioInput(Buffer.alloc(48002)));
});

test('variable length output is decoded fully, never as a fixed frame', () => {
  for (const length of [2, 1600, 4800, 14002]) {
    const bytes = Buffer.alloc(length, 17);
    assert.deepEqual(decodeAudio({ delta: bytes.toString('base64') }), bytes);
  }
  for (const delta of ['!', '', 'AQ==']) assert.throws(() => decodeAudio({ delta }));
});

test('caption fragments retain whitespace and timestamps exactly', () => {
  assert.deepEqual(captionEvent({ type: 'session.output_transcript.delta', delta: ' no', event_id: 'one', start_ms: 0, end_ms: 50 }), {
    type: 'caption', channel: 'translation', delta: ' no', eventID: 'one', startMs: 0, endMs: 50,
  });
});

test('configuration fails closed without credentials or sensible limits', () => {
  assert.throws(() => readConfig({}));
  assert.throws(() => readConfig({ OPENAI_API_KEY: 'dummy', DEVICE_TOKEN: 'short' }));
  const env = { OPENAI_API_KEY: 'dummy', DEVICE_TOKEN: 'x'.repeat(32) };
  assert.equal(readConfig(env).host, '127.0.0.1');
  for (const suffix of ['\0', '\t', '\x7f']) assert.throws(() => readConfig({ ...env, DEVICE_TOKEN: env.DEVICE_TOKEN + suffix }));
  assert.throws(() => readConfig({ ...env, SESSION_MAX_SECONDS: '0' }));
  assert.throws(() => readConfig({ ...env, MAX_SESSIONS: 'NaN' }));
});
