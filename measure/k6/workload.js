// SRQ3 D3 load profile (M-WP-01..04): constant arrival rate against the
// reference application's primary endpoint, POST /api/cases on the
// submission service. The rate is fixed (default 10 req/s, protocol §3 D3)
// so that when the system slows, latency/error rate degrade visibly while
// the offered load stays constant. The request is anonymous by design
// (Phase-1 API), so no token acquisition sits in the measured path; every
// accepted case still exercises the full pipeline (REST -> outbox ->
// Artemis -> management inbox) asynchronously.
//
// Env: BASE_URL (required), HOST_HEADER (k3s ingress routing), RATE,
//      DURATION, SUMMARY_PATH (where handleSummary writes the JSON).
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL;
const HOST = __ENV.HOST_HEADER || '';
const RATE = Number(__ENV.RATE || 10);
const DURATION = __ENV.DURATION || '60s';

export const options = {
  scenarios: {
    submit: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 30,
      maxVUs: 100,
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

const params = {
  headers: {
    'Content-Type': 'application/json',
    ...(HOST ? { Host: HOST } : {}),
  },
  timeout: '10s',
};

const body = JSON.stringify({
  message: 'load test: synthetic anonymous report (measurement harness)',
});

export default function () {
  const res = http.post(`${BASE}/api/cases`, body, params);
  check(res, { 'status is 201': (r) => r.status === 201 });
}

export function handleSummary(data) {
  const dur = data.metrics.http_req_duration.values;
  const out = {
    rate_target_rps: RATE,
    duration: DURATION,
    count: data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0,
    throughput_rps: data.metrics.http_reqs ? data.metrics.http_reqs.values.rate : 0,
    p50_ms: dur.med,
    p95_ms: dur['p(95)'],
    p99_ms: dur['p(99)'],
    avg_ms: dur.avg,
    max_ms: dur.max,
    error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate : 0,
    dropped_iterations: data.metrics.dropped_iterations
      ? data.metrics.dropped_iterations.values.count
      : 0,
  };
  const path = __ENV.SUMMARY_PATH || 'k6-summary.json';
  return { [path]: JSON.stringify(out, null, 2) + '\n' };
}
