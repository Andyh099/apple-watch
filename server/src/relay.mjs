import { WebSocket } from 'ws';
import { createHash } from 'node:crypto';
import { BYTES_PER_SECOND, UPSTREAM_URL, startEvent, audioInput, decodeAudio, captionEvent } from './protocol.mjs';

// Match the Watch's two-second pending + in-flight cap after a brief stall.
// Only the burst allowance changes; refill stays at real-time PCM throughput.
const INPUT_BURST_BYTES = BYTES_PER_SECOND * 2;

// The client may only stream PCM and end a session. It cannot send provider
// commands, prompts, endpoint URLs, arbitrary models, or tool instructions.
export function bridge(client, config, connectUpstream = (url, options) => new WebSocket(url, options)) {
  let upstream;
  let ready = false;
  let closing = false;
  let finished = false;
  let shutdownTimer;
  let byteBudget = INPUT_BURST_BYTES;
  let budgetAt = Date.now();
  const timers = [];
  const send = (event) => {
    if (client.readyState === WebSocket.OPEN) client.send(JSON.stringify(event));
  };
  const cleanup = () => {
    if (finished) return;
    finished = true;
    for (const timer of timers) clearTimeout(timer);
    clearTimeout(shutdownTimer);
    if (upstream && upstream.readyState !== WebSocket.CLOSED) upstream.terminate();
  };
  const fail = (code, message) => {
    if (finished) return;
    send({ type: 'error', code, message });
    cleanup();
    client.close(1011, code);
  };
  const timer = (callback, ms) => { const t = setTimeout(callback, ms); timers.push(t); return t; };
  const finishInput = () => {
    if (closing || finished) return;
    closing = true;
    if (!ready) { cleanup(); client.close(1000, 'stopped'); return; }
    upstream.send(JSON.stringify({ type: 'session.close' }));
    shutdownTimer = setTimeout(() => fail('close_timeout', '会话未能完整结束，请重试。'), 10_000);
  };

  client.on('error', cleanup);
  client.on('close', cleanup);
  client.on('message', (data, binary) => {
    if (finished) return;
    if (!binary) {
      let message;
      try { message = JSON.parse(data.toString()); } catch { return fail('bad_command', '无效的会话指令。'); }
      if (message.type === 'stop') return finishInput();
      return fail('bad_command', '此连接只接受音频和停止指令。');
    }
    if (closing) return;
    if (!ready) return fail('not_ready', '音频连接尚未就绪。');
    const now = Date.now();
    byteBudget = Math.min(INPUT_BURST_BYTES, byteBudget + (now - budgetAt) * BYTES_PER_SECOND / 1000);
    budgetAt = now;
    byteBudget -= data.length;
    if (byteBudget < 0) return fail('audio_rate', '音频发送过快，请重新连接。');
    if (upstream.bufferedAmount > BYTES_PER_SECOND * 2) return fail('network_slow', '网络延迟过高，已停止录音。');
    try { upstream.send(JSON.stringify(audioInput(data))); }
    catch { fail('bad_audio', '音频格式无效。'); }
  });

  try {
    upstream = connectUpstream(UPSTREAM_URL, {
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        'OpenAI-Safety-Identifier': createHash('sha256').update(config.deviceToken).digest('hex'),
      },
      maxPayload: 1_048_576,
      handshakeTimeout: 10_000,
    });
  } catch { fail('upstream_unavailable', '翻译服务暂不可用。'); return; }

  const connectionTimer = timer(() => fail('connect_timeout', '翻译服务连接超时。'), 15_000);
  timer(() => {
    send({ type: 'notice', message: '原型单次会话时限已到，正在结束。' });
    finishInput();
  }, config.maxSeconds * 1000);

  upstream.on('open', () => {
    if (!finished) upstream.send(JSON.stringify(startEvent(config.model)));
  });
  upstream.on('error', () => fail('upstream_unavailable', '无法连接翻译服务；请检查服务端配置与模型权限。'));
  upstream.on('close', () => {
    if (!finished) fail('upstream_disconnected', '翻译连接已断开，录音已停止。');
  });
  upstream.on('message', (data) => {
    if (finished) return;
    let event;
    try { event = JSON.parse(data.toString()); }
    catch { return fail('bad_upstream_event', '翻译服务返回了无效数据。'); }
    try {
      switch (event.type) {
        case 'session.started':
          clearTimeout(connectionTimer);
          ready = true;
          send({ type: 'ready', sampleRate: 24_000, channels: 1, format: 'pcm16', mode: 'experimental-bidirectional' });
          break;
        case 'session.output_audio.delta':
          if (!ready) return fail('bad_upstream_event', '翻译服务事件顺序异常。');
          if (client.bufferedAmount > BYTES_PER_SECOND * 2) return fail('playback_slow', '播放积压过多，已停止会话。');
          if (client.readyState === WebSocket.OPEN) client.send(decodeAudio(event), { binary: true });
          break;
        case 'session.input_transcript.delta':
        case 'session.output_transcript.delta':
          send(captionEvent(event));
          break;
        case 'session.delegation.created':
          // No tools exist. Fail closed rather than let an interpreter turn into an assistant.
          fail('interpreter_drift', '模型偏离了纯翻译模式，已停止会话。');
          break;
        case 'error':
          // Do not relay raw provider messages, which can contain configuration details.
          fail('provider_error', '翻译服务拒绝了请求；请检查模型访问权限、额度和配置。');
          break;
        case 'session.closed':
          send({ type: 'closed' });
          cleanup();
          client.close(1000, 'finished');
          break;
      }
    } catch { fail('bad_upstream_event', '翻译服务返回了无法处理的数据。'); }
  });
}
