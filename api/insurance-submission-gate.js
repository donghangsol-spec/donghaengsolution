const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store, max-age=0',
  'X-Content-Type-Options': 'nosniff',
};

export default function handler(req, res) {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).setHeader(jsonHeaders).json({ error: 'method_not_allowed' });
  }

  const sandboxMode = process.env.INSURANCE_SANDBOX_MODE === 'true';
  const submissionEnabled = process.env.INSURANCE_SUBMISSION_ENABLED === 'true';
  const brokerConfigured = Boolean(
    process.env.TRUSTED_BROKER_URL &&
    process.env.TRUSTED_BROKER_SHARED_SECRET
  );

  const sandboxReady = sandboxMode && submissionEnabled && brokerConfigured;
  const checks = {
    sandbox_mode: sandboxMode,
    server_submission_switch: submissionEnabled,
    trusted_broker_configured: brokerConfigured,
    resident_id_storage: 'disabled',
    live_institution_submission: false,
  };

  return res.status(200).setHeader(jsonHeaders).json({
    status: sandboxReady ? 'SANDBOX_READY' : 'BLOCKED',
    checks,
    message: sandboxReady
      ? '샌드박스 보안연계 시험만 가능합니다. 실제 기관 제출은 차단되어 있습니다.'
      : '보안연계 조건이 충족되지 않아 제출이 차단되어 있습니다.',
  });
}
