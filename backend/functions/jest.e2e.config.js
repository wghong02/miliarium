/**
 * Live end-to-end test config. Unlike `jest.integration.config.js` (which runs
 * against the local emulators), this suite hits the REAL deployed `api` function
 * and signs in real test accounts. It is NOT launched by the emulator; run it
 * directly with `npm run test:e2e`.
 *
 * Credentials come from `src/__integration__/credentials.e2e.json` (gitignored).
 * When that file is missing or still contains placeholders, the suite skips
 * itself rather than failing, so it's safe to run in any environment.
 *
 * @type {import('ts-jest').JestConfigWithTsJest}
 */
module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  roots: ["<rootDir>/src"],
  testMatch: ["**/__integration__/**/*.e2e.test.ts"],
  transform: {
    "^.+\\.ts$": ["ts-jest", { tsconfig: "tsconfig.test.json" }],
  },
  testTimeout: 30000,
  clearMocks: true,
};
