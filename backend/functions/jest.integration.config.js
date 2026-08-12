/**
 * Integration test config — runs handlers against the Firestore emulator (real
 * Admin SDK, no mocks). Separate from the unit config so `npm test` stays fast
 * and offline. Launched via `npm run test:integration`, which starts the
 * emulator with `firebase emulators:exec`.
 *
 * @type {import('ts-jest').JestConfigWithTsJest}
 */
module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  roots: ["<rootDir>/src"],
  testMatch: ["**/__integration__/**/*.integration.test.ts"],
  transform: {
    "^.+\\.ts$": ["ts-jest", { tsconfig: "tsconfig.test.json" }],
  },
  setupFiles: ["<rootDir>/src/__integration__/setup.ts"],
  testTimeout: 20000,
  clearMocks: true,
};
