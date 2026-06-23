// k6 browser-based loadgen for the React `frontend` service.
//
// Unlike the curl-based airlines/flights loadgens (which never load the
// React bundle), this drives a real headless Chromium via the k6/browser
// module so the frontend's JavaScript actually executes — which means
// the Faro Web SDK initializes and emits RUM events, and each page
// makes the cross-origin XHR calls to airlines/flights that produce
// stitched frontend → airlines → flights traces in Tempo.
//
// Configured via env vars (set by `frontend-loadgen.sh` or directly):
//   TARGET   = local | orbstack    (default: local)
//   DURATION = e.g. 60s, 5m        (default: 60s)
//   VUS      = number of parallel browsers (default: 2)

import { browser } from 'k6/browser';
import { sleep } from 'k6';

const TARGET = __ENV.TARGET || 'local';
const DURATION = __ENV.DURATION || '60s';
const VUS = parseInt(__ENV.VUS || '2', 10);

const BASE_URLS = {
  local: 'http://localhost:3000',
  orbstack: 'http://frontend.povsim.svc.cluster.local:3000',
};

const BASE_URL = BASE_URLS[TARGET];

if (!BASE_URL) {
  throw new Error(
    `Unknown TARGET="${TARGET}". Use 'local' or 'orbstack'.`
  );
}

export const options = {
  scenarios: {
    ui: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      options: {
        browser: {
          type: 'chromium',
        },
      },
    },
  },
};

export default async function () {
  const page = await browser.newPage();

  try {
    // Start at home — triggers initial Faro session, page-load web vitals,
    // and a Home XHR if any.
    await page.goto(`${BASE_URL}/`, { waitUntil: 'networkidle' });
    await page.locator('a[href="/airlines"]').waitFor();
    sleep(1);

    // Navigate via React Router <Link>s so FaroRoutes fires route_change
    // events (not just URL changes). The Airlines / Flights pages only
    // fire their axios calls when the "Get …" button is clicked, so
    // click that too on each visit — that produces the cross-origin
    // XHR span and the stitched frontend → backend trace.
    await page.locator('a[href="/airlines"]').click();
    await page.locator('button.app-btn').click();
    await page.waitForLoadState('networkidle');
    sleep(1);

    await page.locator('a[href="/flights"]').click();
    await page.locator('button.app-btn').click();
    await page.waitForLoadState('networkidle');
    sleep(1);

    await page.locator('a[href="/"]').click();
    await page.waitForLoadState('networkidle');
    sleep(1);
  } finally {
    await page.close();
  }
}
