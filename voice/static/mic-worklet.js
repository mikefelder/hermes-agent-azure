// Forwards raw mic frames (Float32, context sample rate) to the main thread.
class MicCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.active = true;
    this.port.onmessage = (e) => { if (e.data === 'stop') this.active = false; };
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch && ch.length) this.port.postMessage(ch.slice(0));
    return this.active;
  }
}

registerProcessor('mic-capture', MicCapture);
