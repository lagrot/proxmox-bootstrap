// Compatibility entry point for the superseded one-camera smoke test.
process.env.PROOF_ORIGIN ||= 'http://127.0.0.1:8765';
require('./full-viewer.cjs');
