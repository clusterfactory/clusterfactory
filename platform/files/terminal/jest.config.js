/** @type {import('jest').Config} */
module.exports = {
  testTimeout: 15000,
  projects: [
    {
      displayName: 'unit',
      testMatch: ['**/test/ui.unit.test.js'],
      testEnvironment: 'jest-environment-jsdom',
    },
    {
      displayName: 'integration',
      testMatch: ['**/test/server.integration.test.js'],
      testEnvironment: 'node',
    },
  ],
};
