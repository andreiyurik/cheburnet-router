// vitest.config.js — юниты только из src/ (tests/e2e — playwright, у него свой раннер;
// маски *.spec.js у них пересекаются, без include vitest пытался бы гнать e2e-спеки).
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/*.test.js'],
  },
});
