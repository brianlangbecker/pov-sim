import {
  faro,
  initializeFaro,
  getWebInstrumentations,
  ReactIntegration,
  createReactRouterV6Options,
} from '@grafana/faro-react';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';
import {
  createRoutesFromChildren,
  matchRoutes,
  Routes,
  useLocation,
  useNavigationType,
} from 'react-router-dom';

initializeFaro({
  url: 'https://faro-collector-prod-us-central-7.grafana.net/collect/a7ab2622451e62a4c702bda7afdc9106',
  app: {
    name: 'povsim-frontend',
    version: '0.1.0',
    environment: process.env.NODE_ENV,
  },
  instrumentations: [
    ...getWebInstrumentations(),
    new TracingInstrumentation({
      instrumentationOptions: {
        propagateTraceHeaderCorsUrls: [
          /\/\/(airlines|flights)\.povsim\.svc\.cluster\.local/,
          /\/\/localhost:(8080|5001)/,
        ],
      },
    }),
    new ReactIntegration({
      router: createReactRouterV6Options({
        createRoutesFromChildren,
        matchRoutes,
        Routes,
        useLocation,
        useNavigationType,
      }),
    }),
  ],
  experimental: {
    trackNavigation: true,
  },
  ignoreErrors: [
    /^ResizeObserver loop limit exceeded$/,
    /^ResizeObserver loop completed with undelivered notifications$/,
    /^Script error\.$/,
    /chrome-extension:\/\//,
    /moz-extension:\/\//,
  ],
});

// Stub user — this POV app has no auth. Replace with a real `setUser`
// call (e.g. after a login callback) when wiring auth, and call
// `faro.api?.resetUser()` on logout.
faro.api?.setUser({
  id: 'demo-user',
  username: 'demo',
  attributes: {
    env: 'orbstack',
  },
});
